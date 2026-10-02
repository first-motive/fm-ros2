#!/usr/bin/env bash
# bump-pins.sh — move the tag-pinned manifest entries in fm-ros2.repos onto the
# newest complete stable release of the sibling each one pins.
#
# docker/ and comms/ are pinned to a release tag rather than tracking main: the
# transport must not move under a running fleet, and a router and a bridge on
# different versions do not interoperate. The consequence is that a release on
# either sibling changes nothing for the fleet until the pin here moves with it.
#
# That move is a deployment decision, not a version bump, so this script only
# prepares it. The vendor-pin-bump workflow opens the result as a pull request and
# a human merges it — a rig must never converge on a new transport because a
# schedule fired.
#
#   ./scripts/dev/bump-pins.sh            # plan: report drift, change nothing
#   ./scripts/dev/bump-pins.sh --apply    # rewrite the drifting version: lines
#
# Exit: 0 = no drift (or applied), 10 = drift found in plan mode, 1 = error.
# The workflow reads 10 as "there is something to open a pull request for".
#
# TWO THINGS THIS SCRIPT MUST NEVER DO, and both have bitten it once:
#
#   1. Treat a branch-tracking entry as a pin. Half this manifest tracks main
#      (`version: main`). Those are deliberate choices, not stale pins. Only a
#      complete stable tag (vX.Y.Z) is comparable, and anything else is left
#      exactly as it is.
#   2. Bleed fields between entries. Manifest keys include slashes
#      (`src/fm_robot:`), so a key pattern that excludes `/` silently merges
#      every package entry into the preceding one — which is how a rewrite once
#      took the comms pin from v0.2.4 down to v0.1.7 and retagged four
#      main-tracking repos. The key pattern below allows `/` for this reason, and
#      every value is re-read and checked after the write.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MANIFEST="$ROOT/fm-ros2.repos"

# A manifest key: two spaces of indent, then anything a repo path can contain.
KEY_RE='^  [A-Za-z0-9_./-]+:[[:space:]]*$'
# A comparable pin: a complete stable release tag, nothing else.
PIN_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'

usage() {
  cat <<'EOF'
bump-pins.sh — plan or apply the tag-pin bump in fm-ros2.repos

Usage: ./scripts/dev/bump-pins.sh [--apply] [-h]

  (no flags)  plan: print each pin that has a newer upstream release
  --apply     rewrite the version: lines of the drifting pins
  -h, --help  this help

Only complete stable tags (vX.Y.Z) are compared. A suffixed tag such as
v0.2.0-zenoh.3 carries a transport, not a release, and is reported and left
alone. Entries tracking a branch (`version: main`) are not pins and are never
touched.
EOF
}

err() { printf 'ERROR %s\n' "$*" >&2; }

# ver_gt A B — true when A is a newer vX.Y.Z than B. Numeric compare per field,
# because BSD sort(1) has no -V and this must run on macOS and the runners alike.
ver_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    sub(/^v/, "", a); sub(/^v/, "", b)
    n = split(a, A, "."); m = split(b, B, ".")
    lim = (n > m ? n : m)
    for (i = 1; i <= lim; i++) {
      x = A[i] + 0; y = B[i] + 0
      if (x > y) exit 0
      if (x < y) exit 1
    }
    exit 1
  }'
}

# newest_stable_tag URL — the newest vX.Y.Z the sibling publishes, or empty.
# git's own version-aware ref sort does the ordering: --sort=-v:refname, then the
# first entry that is a complete stable tag.
newest_stable_tag() {
  local url="$1"
  # `|| true` inside the group: an unreachable or unknown remote makes git exit
  # 128, and pipefail would turn that into an abort under set -e. An unreachable
  # sibling is a warning the caller prints, never a reason to stop mid-manifest.
  { git ls-remote --tags --refs --sort=-v:refname "$url" 'v[0-9]*' 2>/dev/null || true; } \
    | awk -v pin_re="$PIN_RE" '{ sub("refs/tags/", "", $2); if ($2 ~ pin_re) { print $2; exit } }'
}

# collect_pins — "key<TAB>url<TAB>version" for every entry that pins a release tag.
collect_pins() {
  awk -v key_re="$KEY_RE" -v pin_re="$PIN_RE" '
    $0 ~ key_re {
      if (key != "" && url != "" && ver ~ pin_re) printf "%s\t%s\t%s\n", key, url, ver
      key = $1; sub(":$", "", key); url = ""; ver = ""; next
    }
    /^    url:[[:space:]]*/     { url = $2; next }
    /^    version:[[:space:]]*/ { ver = $2; next }
    END { if (key != "" && url != "" && ver ~ pin_re) printf "%s\t%s\t%s\n", key, url, ver }
  ' "$MANIFEST"
}

# report_non_pins — an entry pinned to a tag that is not a complete stable release
# is a real pin this script cannot compare. Say so rather than ignore it.
report_non_pins() {
  awk -v key_re="$KEY_RE" -v pin_re="$PIN_RE" '
    $0 ~ key_re {
      if (key != "" && ver != "" && ver !~ pin_re) printf "%s\t%s\n", key, ver
      key = $1; sub(":$", "", key); ver = ""; next
    }
    /^    version:[[:space:]]*/ { ver = $2; next }
    END { if (key != "" && ver != "" && ver !~ pin_re) printf "%s\t%s\n", key, ver }
  ' "$MANIFEST" | while IFS=$'\t' read -r k v; do
    case "$v" in
      # Branch tracking is the normal case here and is not a pin.
      main|master|HEAD|dev|develop|trunk) continue ;;
      # Anything else version-shaped is a pin with a suffix or a commit.
      *) printf 'WARNING %s — pinned to %s, which is not a complete stable tag; left alone\n' "$k" "$v" >&2 ;;
    esac
  done
}

# rewrite_pin KEY VERSION — replace version: inside that entry block only, then
# re-read the file and prove the intended line is the one that changed.
rewrite_pin() {
  local key="$1" newver="$2" tmp now
  tmp="$(mktemp)"
  awk -v target="$key" -v newver="$newver" -v key_re="$KEY_RE" '
    $0 ~ key_re {
      k = $1; sub(":$", "", k); infield = (k == target)
    }
    infield && /^    version:/ { sub(/version:.*/, "version: " newver) }
    { print }
  ' "$MANIFEST" >"$tmp"

  # Verify before installing: the target entry must now hold the new value.
  now="$(awk -v target="$key" -v key_re="$KEY_RE" '
    $0 ~ key_re { k = $1; sub(":$", "", k); infield = (k == target) }
    infield && /^    version:/ { sub(/^[[:space:]]*version:[[:space:]]*/, ""); print; exit }
  ' "$tmp")"
  if [ "$now" != "$newver" ]; then
    rm -f "$tmp"
    err "rewrite of $key did not land (found '${now:-nothing}'); manifest untouched"
    return 1
  fi
  mv "$tmp" "$MANIFEST"
}

main() {
  local apply=0
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    --apply) apply=1 ;;
    "") ;;
    *) err "unknown argument: $1"; usage >&2; return 1 ;;
  esac

  [ -f "$MANIFEST" ] || { err "no manifest at $MANIFEST"; return 1; }

  local drift=0 key url version upstream
  while IFS=$'\t' read -r key url version; do
    [ -n "${key:-}" ] || continue
    upstream="$(newest_stable_tag "$url")"
    if [ -z "$upstream" ]; then
      printf 'WARNING %s — no complete stable tag upstream at %s\n' "$key" "$url" >&2
      continue
    fi
    [ "$upstream" = "$version" ] && continue

    # A pin ahead of upstream is a hand-made state, not drift: say so, do not
    # walk it backward.
    if ver_gt "$version" "$upstream"; then
      printf 'WARNING %s — pin %s is ahead of upstream %s; left alone\n' "$key" "$version" "$upstream" >&2
      continue
    fi

    if [ "$apply" -eq 1 ]; then
      rewrite_pin "$key" "$upstream" || return 1
      printf 'BUMPED %s %s -> %s\n' "$key" "$version" "$upstream"
    else
      printf 'DRIFT  %s %s -> %s\n' "$key" "$version" "$upstream"
      drift=1
    fi
  done < <(collect_pins)

  report_non_pins

  if [ "$apply" -eq 0 ] && [ "$drift" -eq 1 ]; then
    return 10
  fi
  return 0
}

main "$@"

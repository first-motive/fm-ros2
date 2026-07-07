#!/usr/bin/env bash
# Converge this fm_ros2 workspace checkout to latest. Pulls the fm_ros2 repo
# itself (fast-forward only), then re-imports the package + external manifests so
# src/ and external/ catch up to their pinned refs. A dirty repo is never
# stashed or reset — the pull is skipped when this tree is dirty, and vcs import
# leaves any already-checked-out repo with local changes untouched. Dirty repos
# are surfaced at the end so you know what was left alone.
#
#   ./scripts/update.sh              # pull + re-import packages + externals
#   ./scripts/update.sh --dry-run    # print the plan, change nothing
#   ./scripts/update.sh --help       # usage
#
# Setup-side only, like install.sh — it does not build or launch. Run ./run.sh
# afterwards to rebuild against the refreshed tree.
set -euo pipefail

# Silence the child-process noise the imports spew: git's detached-HEAD advice
# (repeated once per imported repo) and vcstool's pkg_resources deprecation
# warning. Scoped to this process env and inherited by vcs -> git/python children
# — no global git-config mutation. Mirrors install.sh.
export GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=advice.detachedHead GIT_CONFIG_VALUE_0=false
export PYTHONWARNINGS='ignore:pkg_resources is deprecated:UserWarning'

# Resolve the repo root (scripts/ sits one level under it) and work from there so
# the root-relative manifest paths resolve the same way install.sh imports them.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Shared narration helpers (item, spin). lib.sh sits at the repo root; fall back
# to plain inline copies if it is missing so the script still runs standalone.
if [[ -f "$ROOT/lib.sh" ]]; then
  # shellcheck source=/dev/null
  . "$ROOT/lib.sh"
else
  item() { echo "$1"; }
  spin() { shift; "$@"; }
fi

usage() {
  cat <<'EOF'
update.sh — converge this fm_ros2 checkout to latest (pull + re-import)

Pulls the fm_ros2 repo (fast-forward only), then re-imports the package and
external manifests so src/ and external/ catch up. Never stashes or resets: a
dirty fm_ros2 tree skips the pull, and vcs import leaves dirty sub-repos alone.
Dirty repos are reported at the end.

Setup only. To rebuild against the refreshed tree, run ./run.sh afterwards.

Usage: ./scripts/update.sh [options]

Options:
  --dry-run    print what would happen, change nothing
  -h, --help   show this help
EOF
}

# vcs (vcstool) drives the imports and the dirty-repo scan. Preflight it with the
# same install hint install.sh's ensure_vcs uses, but do not auto-install here —
# update runs inside an existing checkout where the env is already provisioned.
ensure_vcs() {
  command -v vcs >/dev/null 2>&1 && return
  echo "error: vcstool not found on PATH." >&2
  echo "       Install it with: uv tool install vcstool --with 'setuptools<81'" >&2
  echo "       (or re-run ./install.sh, which provisions it)." >&2
  exit 1
}

# Collect sub-repos with a dirty working tree under the given base dir. Best
# effort: vcs status varies by version, so degrade to nothing on any failure
# rather than aborting the update. Prints one repo path per dirty tree.
dirty_repos() {  # base
  local base="$1"
  [[ -d "$base" ]] || return 0
  # --porcelain across each imported repo; a non-empty line for a repo means it
  # is dirty. `vcs custom` shells `git status --porcelain` per repo and prefixes
  # each block with the repo path in a "=== path ===" banner — track the current
  # banner and emit it once when the repo shows any status output.
  vcs custom "$base" --git --args status --porcelain 2>/dev/null | awk '
    /^===/ { repo=$2; next }
    NF && repo { print repo; repo="" }
  '
}

main() {
  local dry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      -h|--help) usage; return 0 ;;
      *)
        echo "error: unknown argument '$1'" >&2
        usage >&2
        return 1
        ;;
    esac
  done

  # CI self-test hook: prove the script parses and the plan resolves, then stop
  # before any git/vcs mutation so the offline path can smoke it. Mirrors
  # install.sh's FM_SELFTEST guard.
  if [[ -n "${FM_SELFTEST:-}" ]]; then
    echo "selftest ok: update.sh parsed (root=$ROOT, dry_run=$dry)"
    echo "plan:"
    echo "  1. pull fm_ros2 (--ff-only; skipped if this tree is dirty)"
    echo "  2. vcs import < fm-ros2.repos            (packages)"
    echo "  3. vcs import src < private-overlay.repos (learning overlay, if present)"
    echo "  4. ./scripts/install/import-externals.sh  (externals)"
    echo "  5. report dirty sub-repos left untouched"
    return 0
  fi

  ensure_vcs

  if [[ "$dry" == 1 ]]; then
    item "[dry-run] would pull fm_ros2 (--ff-only) unless this tree is dirty"
    item "[dry-run] would vcs import < fm-ros2.repos"
    if [[ -f private-overlay.repos ]]; then
      item "[dry-run] would vcs import src < private-overlay.repos"
    else
      item "[dry-run] private-overlay.repos absent — would skip the learning overlay"
    fi
    item "[dry-run] would run ./scripts/install/import-externals.sh"
    item "[dry-run] would report dirty sub-repos left untouched"
    return 0
  fi

  # Pull the fm_ros2 repo itself. A dirty tree gets no pull — never stash or reset
  # the user's work. --ff-only refuses on divergence or local commits, so a clean
  # tree that cannot fast-forward is warned about, not clobbered.
  item "updating fm_ros2 ..."
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    item "fm_ros2 tree is dirty — skipping the pull, keeping your changes"
  else
    git pull --ff-only \
      || item "could not fast-forward fm_ros2 (local commits or divergence) — keeping your tree"
  fi

  # Re-import the package repos. Manifest paths are root-relative, so import from
  # the root (no `src` arg), matching install.sh. A failure here is almost always
  # missing org access to the private repos — say so plainly, then exit non-zero.
  local n; n=$(grep -c 'version:' fm-ros2.repos)
  item "re-importing $n repos (container infra + packages) ..."
  if ! spin "re-importing $n repos" vcs import < fm-ros2.repos; then
    echo "error: failed to import the package repos." >&2
    echo "       The fm-* package repos are private — this needs git access to the" >&2
    echo "       first-motive org (SSH key or a credential helper). Check your auth" >&2
    echo "       and retry." >&2
    return 1
  fi

  # Optional private learning overlay — absent for members without access, so
  # skip quietly when the manifest is not present.
  if [[ -f private-overlay.repos ]]; then
    item "re-importing the learning overlay into src/ ..."
    if ! spin "re-importing learning overlay" vcs import src < private-overlay.repos; then
      echo "error: failed to import the learning overlay (private-overlay.repos)." >&2
      echo "       This needs access to the private learning repos. Check your auth." >&2
      return 1
    fi
  else
    item "no private-overlay.repos — skipping the learning overlay"
  fi

  # Re-import externals — delegate to the externals importer, do not duplicate it.
  item "re-importing externals ..."
  ./scripts/install/import-externals.sh

  # Report dirty sub-repos left untouched. vcs import does not overwrite local
  # changes in an existing repo, so a dirty checkout was silently skipped — surface
  # it so the user knows it did not advance. Best effort across src/ and external/.
  local dirty; dirty="$(dirty_repos src; dirty_repos external)"
  if [[ -n "$dirty" ]]; then
    item "the following repos are dirty and were left untouched (not updated):"
    while IFS= read -r repo; do
      [[ -n "$repo" ]] && item "  $repo"
    done <<< "$dirty"
  else
    item "no dirty sub-repos — src/ and external/ are clean"
  fi

  item "update complete — rebuild with ./run.sh from your terminal"
}

main "$@"

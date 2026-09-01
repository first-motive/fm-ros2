#!/usr/bin/env bash
# cut-release.sh — tag every repo in this workspace for the appliance release
# channel, in one pass.
#
# Appliances ride release tags, never main: setup-<role>.sh pins each repo to its
# newest v* tag at install, and scripts/service/appliance-update.sh converges to a
# newer one every ~15 minutes. A repo with no tag has no target on that channel,
# so the updater reports it untagged and leaves it where the clone landed — which
# means merged work in that repo never reaches a rig, however many times the timer
# fires. Tagging the workspace repo alone is not enough; the release is the whole
# set or it is nothing.
#
#   ./scripts/dev/cut-release.sh                  # print the plan, change nothing
#   ./scripts/dev/cut-release.sh --only-untagged  # plan the seeding pass only
#   ./scripts/dev/cut-release.sh --minor --apply  # cut and push v0.<n+1>.0
#
# Cadence and the rest of the flow: docs/RELEASE.md.
#
# Two decisions worth knowing before reading further:
#
# Repos are discovered, not listed. The set is every git checkout the manifests
# put in this workspace — the root, docker/, comms/, and each src/<repo> — so a
# repo added to a manifest is released without editing this script, and the
# private repos among them are never named in this public tree. external/ is
# excluded on purpose: those are vendored upstreams pinned by commit, not ours to
# tag.
#
# Tags are cut on the remote's default-branch tip, not on local HEAD. A
# maintainer's workspace holds whatever they were last working on — a detached
# release tag from an appliance test, a feature branch, uncommitted work — and
# none of that is what the fleet should receive. Fetching first also means the
# version each repo bumps from is the newest tag that exists anywhere, not the
# newest one this checkout happens to know about.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib.sh"          # item(), latest_release_tag()
cd "$ROOT"

usage() {
  cat <<'EOF'
cut-release.sh — tag every repo in this workspace for the appliance release channel

Prints a plan by default and changes nothing; --apply creates and pushes the
tags. Each repo bumps from its own newest v* tag, so repos on different versions
stay on different versions — this is a release train, not a shared version
number. An untagged repo is seeded at v0.1.0.

Usage: ./scripts/dev/cut-release.sh [options]

Options:
  --apply           create and push the tags (default: print the plan only)
  --minor           bump the minor version instead of the patch version
  --only-untagged   restrict the run to repos with no v* tag yet
  -h, --help        show this help
EOF
}

# The repos this workspace assembles, one path per line. Ordered root-first so the
# plan reads the way the workspace does.
_workspace_repos() {
  local dir
  for dir in "$ROOT" "$ROOT"/docker "$ROOT"/comms "$ROOT"/src/*/; do
    [ -d "${dir%/}/.git" ] || continue
    printf '%s\n' "${dir%/}"
  done
}

# The remote's default branch, asked of the remote rather than assumed. A repo
# whose default is not main would otherwise be released from a branch nobody
# merges into.
_default_branch() {  # dir
  git -C "$1" remote show origin 2>/dev/null \
    | awk '/HEAD branch:/ { print $NF; exit }'
}

# Next version for a repo, from its own newest tag. An untagged repo is seeded
# rather than bumped: v0.1.0 is where every other repo here started, so the fleet
# reads one version scheme.
_next_version() {  # current-tag  part
  local current="$1" part="$2" major minor patch
  if [ -z "$current" ]; then
    echo "v0.1.0"
    return
  fi
  IFS=. read -r major minor patch <<EOF
${current#v}
EOF
  # A tag with a suffix (v0.1.0-rc1) or a missing component (v0.1) leaves a
  # non-numeric or empty field; reduce each to the number it starts with rather
  # than emitting a version that will not sort.
  major="${major%%[!0-9]*}"; major="${major:-0}"
  minor="${minor%%[!0-9]*}"; minor="${minor:-0}"
  patch="${patch%%[!0-9]*}"; patch="${patch:-0}"
  if [ "$part" = minor ]; then
    echo "v${major}.$((minor + 1)).0"
  else
    echo "v${major}.${minor}.$((patch + 1))"
  fi
}

main() {
  local apply=0 part=patch only_untagged=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1; shift ;;
      --minor) part=minor; shift ;;
      --only-untagged) only_untagged=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) echo "error: unknown argument '$1'" >&2; usage >&2; return 1 ;;
    esac
  done

  # A release is the whole set, so the set has to be real before anything is
  # tagged. This script discovers repos from directories — src/*, docker/,
  # comms/ — which a bare clone of the orchestrator simply does not have. Run
  # there, it scanned one repo and printed "nothing to release", the same
  # sentence a genuinely current workspace prints. Acting on that ships the
  # orchestrator's own tag and leaves every package repo untagged: the fleet
  # keeps running old package code while every check reports healthy.
  local scanned
  scanned="$(_workspace_repos | wc -l | tr -d ' ')"
  item "scanned $scanned repos under $ROOT"
  if [ "$scanned" -le 1 ]; then
    echo "error: $ROOT is a bare clone, not an assembled workspace." >&2
    echo "       Found $scanned repo; a release needs src/, docker/ and comms/." >&2
    echo "       Assemble it first (vcs import < fm-ros2.repos) or run this from" >&2
    echo "       the assembled workspace, then re-run." >&2
    return 2
  fi

  local dir name branch current next tip tagged planned=0
  while IFS= read -r dir; do
    name="$(basename "$dir")"

    # Tag tips and the default branch both come from the remote, so fetch before
    # reading either. A fetch that fails is almost always missing access to a
    # private repo; skip that repo loudly rather than releasing a partial set in
    # silence.
    if ! git -C "$dir" fetch -q --force origin '+refs/tags/*:refs/tags/*' 2>/dev/null; then
      item "SKIP $name — could not fetch tags (check org access)"
      continue
    fi
    branch="$(_default_branch "$dir")"
    if [ -z "$branch" ]; then
      item "SKIP $name — could not read the remote's default branch"
      continue
    fi
    git -C "$dir" fetch -q origin "$branch" 2>/dev/null || true
    tip="$(git -C "$dir" rev-parse "origin/$branch" 2>/dev/null)" || {
      item "SKIP $name — no origin/$branch to release from"
      continue
    }

    current="$(latest_release_tag "$dir")"
    if [ "$only_untagged" = 1 ] && [ -n "$current" ]; then
      continue
    fi

    # Already released: the newest tag is the branch tip. Re-cutting would move a
    # tag the fleet may already be sitting on, which is the one thing the release
    # channel must never do.
    if [ -n "$current" ]; then
      tagged="$(git -C "$dir" rev-parse "$current^{commit}" 2>/dev/null || true)"
      if [ "$tagged" = "$tip" ]; then
        item "ok   $name — $current is already the $branch tip"
        continue
      fi
    fi

    next="$(_next_version "$current" "$part")"
    planned=$((planned + 1))
    if [ "$apply" = 0 ]; then
      item "plan $name — ${current:-no tag} -> $next at $branch ${tip:0:7}"
      continue
    fi

    item "tagging $name $next at $branch ${tip:0:7} ..."
    git -C "$dir" tag -a "$next" "$tip" -m "$next"
    git -C "$dir" push -q origin "$next"
  done <<EOF
$(_workspace_repos)
EOF

  if [ "$planned" = 0 ]; then
    item "nothing to release — every repo's newest tag is already its branch tip"
    return 0
  fi
  if [ "$apply" = 0 ]; then
    item "$planned repos would be tagged — re-run with --apply to cut them"
    return 0
  fi
  # The rigs pick this up on their own: each fm-update-<role>.timer fires about
  # every 15 minutes, so no push to a fleet is needed or wanted here.
  item "$planned repos tagged — appliances converge within one timer tick (~15 min)"
}

main "$@"

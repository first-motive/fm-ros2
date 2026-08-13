#!/usr/bin/env bash
# appliance-update.sh — converge one appliance workspace to latest, safely.
#
# The pull half of the appliance auto-update: fm-update-<role>.timer (installed
# by install-update-timer.sh) runs this every ~15 minutes. It fetches tags for
# the workspace repo and its role repos, and only when a NEWER RELEASE TAG
# exists does it check that tag out and re-run the role installer (rebuild +
# service restart). Appliances ride the release channel: cutting a v* tag rolls
# the fleet within one tick; merged-but-untagged main never moves a box. No
# push infra, no secrets beyond the git credentials already on the host.
#
#   scripts/service/appliance-update.sh recorder     # or: processor
#
# Safety posture:
#   - busy gate: never updates mid-take (recent episode writes, excluding the
#     continuous tactile-raw stream) or mid-processing (a dataset_process
#     subprocess is running); the next tick retries.
#   - clean moves only: a repo is only ever checked out onto a newer v* tag
#     when it has no tracked modifications; anything else is logged and left
#     alone, never stashed, reset, or force-pulled.
#   - flock: overlapping runs (timer + manual) collapse to one.
#   - main()-wrap: the running copy survives its own file being replaced by
#     the pull it performs (bash parses the whole function before executing).
#
# Requires passwordless sudo for the installer's apt/systemd steps — the same
# requirement the appliance roles already have for unattended installs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/lib.sh" ] && . "$ROOT/lib.sh" || item() { echo "$1"; }

# Seconds of recordings-dir quiet required before a recorder update proceeds.
_RECORDER_QUIET_MIN=2

usage() {
  cat <<'EOF'
appliance-update.sh — pull + rebuild + restart one appliance role when behind

  scripts/service/appliance-update.sh recorder|processor
  -h, --help   show this help

Fetches release tags for the workspace and role repos; exits quietly when every
repo sits on its newest v* tag. When a newer tag exists: checks it out (dirty
repos and repos with no tags are skipped with a warning) and re-runs the role
installer. Driven by fm-update-<role>.timer.
EOF
}

# True when this role must not be interrupted right now.
_busy() {  # role
  case "$1" in
    recorder)
      # A take in flight = recent episode writes under the recordings dir (bag
      # chunks + sessions.jsonl). The tactile bridge writes continuously under
      # tactile-raw even while the episode recorder is idle, so exclude that
      # sibling evidence stream or this updater can never converge.
      local recdir="${FM_RECORDER_RECORDINGS_DIR:-$HOME/recordings}"
      local active_file=""
      if [ -d "$recdir" ] && \
         active_file="$(
           find "$recdir" \
             -path "$recdir/tactile-raw" -prune -o \
             -mmin -"$_RECORDER_QUIET_MIN" -type f -print -quit 2>/dev/null
         )" && \
         [ -n "$active_file" ]; then
        item "recorder busy (recent writes in $recdir) — skipping this tick"
        return 0
      fi
      ;;
    processor)
      # The supervisor node restarts cleanly, but a dataset_process run in
      # flight would be killed and leave a half-written output dir.
      if pgrep -f "fm_data_dataset.cli" >/dev/null 2>&1; then
        item "processor busy (dataset_process running) — skipping this tick"
        return 0
      fi
      ;;
  esac
  return 1
}

# lib.sh normally provides this; keep an inline fallback so the script stays
# runnable over `ssh 'bash -s'` with no workspace file to source.
command -v latest_release_tag >/dev/null 2>&1 || \
  latest_release_tag() { git -C "$1" tag -l 'v[0-9]*' --sort=-v:refname 2>/dev/null | head -1; }

# Fetch one repo's tags; report its release-channel state:
#   current        HEAD is the newest v* tag
#   behind <tag>   a newer v* tag exists — check it out
#   untagged       no v* tag yet — the release channel has no target here
#   held           dirty or unfetchable — never moved
_repo_state() {  # dir
  local dir="$1"
  # Tag tips only, shallow when the repo is shallow (--depth 1 appliance
  # clones stay lean). --force: a re-cut tag moves.
  local -a depth=()
  [ -f "$(git -C "$dir" rev-parse --git-dir)/shallow" ] && depth=(--depth 1)
  git -C "$dir" fetch -q --force ${depth[@]+"${depth[@]}"} origin \
    '+refs/tags/*:refs/tags/*' 2>/dev/null || { echo held; return; }
  local target
  target="$(latest_release_tag "$dir")"
  [ -n "$target" ] || { echo untagged; return; }
  # Tracked modifications only: untracked artifacts living in the checkout (the
  # engine venv, logs, caches) must never wedge the updater — git itself refuses
  # a checkout that would overwrite an untracked file, which is the only unsafe
  # case. (.engine-venv/ wedged the first tick before it was gitignored, 2026-07-23.)
  if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo held
    return
  fi
  local head tagc
  head="$(git -C "$dir" rev-parse HEAD)"
  tagc="$(git -C "$dir" rev-parse "$target^{commit}" 2>/dev/null)" || { echo held; return; }
  [ "$head" = "$tagc" ] && echo current || echo "behind $target"
}

main() {
  case "${1:-}" in
    recorder|processor) ;;
    -h|--help) usage; return 0 ;;
    *) echo "error: role must be 'recorder' or 'processor'" >&2; usage >&2; return 1 ;;
  esac
  local role="$1"

  # Overlapping runs (timer tick + manual invocation) collapse to one.
  exec 9>"/tmp/fm-update-$role.lock"
  if ! flock -n 9; then
    item "another update is already running — skipping"
    return 0
  fi

  if _busy "$role"; then
    return 0
  fi

  # The workspace itself plus the role's package repos. src/fm_teleop exists
  # only on the recorder (the tracker); absent dirs are simply skipped.
  local -a repos=("$ROOT" "$ROOT/src/fm_data")
  [ "$role" = recorder ] && repos+=("$ROOT/src/fm_teleop")

  local dir state updated=0
  for dir in "${repos[@]}"; do
    [ -d "$dir/.git" ] || continue
    state="$(_repo_state "$dir")"
    case "$state" in
      behind\ *)
        item "updating $(basename "$dir") -> ${state#behind } ..."
        git -C "$dir" -c advice.detachedHead=false checkout -q "${state#behind }"
        updated=1
        ;;
      untagged)
        item "WARNING: $(basename "$dir") has no release tag yet — left alone (cut a v* tag to put it on the release channel)"
        ;;
      held)
        item "WARNING: $(basename "$dir") is dirty or unfetchable — left alone"
        ;;
    esac
  done

  if [ "$updated" = 0 ]; then
    item "up to date"
    return 0
  fi

  # Something moved: the role installer is the one converge path — idempotent
  # deps + rebuild + service restart (the same command a human runs).
  item "changes pulled — re-running the $role installer ..."
  cd "$ROOT"
  FM_INSTALL_SERVICE=1 "./scripts/install/setup-$role.sh"
  item "appliance updated ($role)"
}

main "$@"

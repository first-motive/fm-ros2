#!/usr/bin/env bash
# appliance-update.sh — converge one appliance workspace to latest, safely.
#
# The pull half of the appliance auto-update: fm-update-<role>.timer (installed
# by install-update-timer.sh) runs this every ~15 minutes. It fetches the
# workspace repo and its role repos, and only when something is actually behind
# does it fast-forward and re-run the role installer (rebuild + service
# restart). Boxes converge on merged PRs within one tick — no push infra, no
# secrets beyond the git credentials already on the host.
#
#   scripts/run/appliance-update.sh recorder     # or: processor
#
# Safety posture:
#   - busy gate: never updates mid-take (recent writes under the recordings
#     dir) or mid-processing (a dataset_process subprocess is running); the
#     next tick retries.
#   - ff-only: a dirty or diverged repo is logged and left alone, never
#     stashed, reset, or force-pulled.
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

  scripts/run/appliance-update.sh recorder|processor
  -h, --help   show this help

Fetches the workspace and role repos; exits quietly when everything is current.
When behind: fast-forwards (dirty/diverged repos are skipped with a warning)
and re-runs `./install.sh --<role> --service`. Driven by fm-update-<role>.timer.
EOF
}

# True when this role must not be interrupted right now.
_busy() {  # role
  case "$1" in
    recorder)
      # A take in flight = recent file writes under the recordings dir (bag
      # chunks + sessions.jsonl). Restarting the recorder then would kill it.
      local recdir="${FM_RECORDER_RECORDINGS_DIR:-$HOME/recordings}"
      if [ -d "$recdir" ] && \
         [ -n "$(find "$recdir" -mmin -"$_RECORDER_QUIET_MIN" -type f 2>/dev/null | head -1)" ]; then
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

# Fetch one repo; report its state: current | behind | held (dirty/diverged).
_repo_state() {  # dir
  local dir="$1"
  git -C "$dir" fetch -q origin 2>/dev/null || { echo held; return; }
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    echo held
    return
  fi
  local head upstream base
  head="$(git -C "$dir" rev-parse HEAD)"
  upstream="$(git -C "$dir" rev-parse '@{u}' 2>/dev/null)" || { echo held; return; }
  [ "$head" = "$upstream" ] && { echo current; return; }
  base="$(git -C "$dir" merge-base HEAD '@{u}')"
  # Behind only (base == HEAD) fast-forwards; ahead or diverged is held.
  [ "$base" = "$head" ] && echo behind || echo held
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
      behind)
        item "updating $(basename "$dir") ..."
        git -C "$dir" merge --ff-only '@{u}' >/dev/null
        updated=1
        ;;
      held)
        item "WARNING: $(basename "$dir") is dirty, diverged, or unfetchable — left alone"
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

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
# The push half is a person: scripts/dev/cut-release.sh cuts the tag set this
# converges to, and docs/RELEASE.md carries the cadence. A role repo left
# untagged is reported below and never moves, so a release is the whole set.
#
# Both layers converge here: fm-setup (the machine layer — drivers, container
# runtime, ROS) through its own scripts/update.sh, and this workspace through
# its role installer. Each moves only when its own release tag moved, so a
# driver bump does not restart a recorder's services and a workspace bump does
# not re-run apt.
#
#   scripts/service/appliance-update.sh recorder     # or: processor
#   scripts/service/appliance-update.sh --check processor
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
# Keep the update wrapper usable during a first converge, before the new shared
# env file exists. Once bridge.sh is present it remains authoritative.
FM_BRIDGE_ENV_FILE="${FM_BRIDGE_ENV_FILE:-/etc/fm-bridge.env}"
FM_BRIDGE_PORT="${FM_BRIDGE_PORT:-8765}"
FM_BRIDGE_OWNER="${FM_BRIDGE_OWNER:-embedded}"
# shellcheck disable=SC1091
if [ -f "$ROOT/scripts/env/bridge.sh" ]; then
  # The timer EnvironmentFile and this direct source deliberately converge on
  # the same durable endpoint. A missing file resolves to the compatibility
  # default and is created by the role installer when services are installed.
  . "$ROOT/scripts/env/bridge.sh"
fi

# Let root read the checkouts it converges.
#
# This runs as root from systemd; every checkout belongs to the appliance user.
# Git refuses a repository owned by somebody else, and the exemption it grants
# root keys off SUDO_UID — which an interactive `sudo git` sets and systemd does
# not. So the refusal appeared only when nobody was watching: by hand every
# command worked, while every timer tick read each repo as "dirty or
# unfetchable", left it alone, and printed "up to date". A rig flashed at
# v0.1.5 sat there for two days with v0.1.6 published and never moved.
#
# Written to root's global config rather than exported through GIT_CONFIG_*,
# because the scripts this one calls — fm-setup's update.sh, fm_ros2's own —
# export GIT_CONFIG_COUNT=1 for a key of their own, which replaces an inherited
# set wholesale. The env route would therefore be dropped in the children doing
# the actual fetching. Global config is still read when those variables are set,
# so this survives them. Idempotent: added once, then found on every later tick.
#
# Both of the helpers below edit root's global git config, so both run only
# under systemd. INVOCATION_ID is set for a unit's processes and unset for a
# person running this by hand — and by hand the checkouts are already theirs,
# git is content, and their config is not this script's to edit.
_unattended() { [ -n "${INVOCATION_ID:-}" ]; }

_trust_checkouts() {
  _unattended || return 0
  git config --global --get-all safe.directory 2>/dev/null | grep -qxF '*' && return 0
  git config --global --add safe.directory '*' 2>/dev/null \
    || item "WARNING: could not mark checkouts safe for root — git may refuse to read them"
}

# Let root reach the private repos this appliance rides on.
#
# First boot writes the token into the appliance user's ~/.git-credentials and
# points that user's git at it with credential.helper=store. The updater runs as
# root, which has neither the file nor the helper — so a public repo converged
# while every private one came back "dirty or unfetchable" and stayed at its
# flash-time commit, with "up to date" printed underneath. The repo was never
# dirty; the fetch could not authenticate.
#
# Root is pointed at the user's existing store rather than handed a copy. A
# second file carrying the same token is a second thing to rotate and a second
# thing to leak, and root can read a 0600 file in another user's home anyway.
#
# A rig with no token is not an error: it has no private repos to converge, and
# the public ones still ride their tags.
_reach_private_repos() {
  _unattended || return 0
  local owner home creds
  # FM_OWNER_HOME is the test seam, as FM_RECORDER_RECORDINGS_DIR is for the busy
  # gate: the lookup below wants a real account on a real rig, which CI has not
  # got. Checked before the lookup so the seam does not depend on it.
  home="${FM_OWNER_HOME:-}"
  if [ -z "$home" ]; then
    owner="$(stat -c %U "$ROOT" 2>/dev/null)" || return 0
    [ -n "$owner" ] || return 0
    home="$(getent passwd "$owner" 2>/dev/null | cut -d: -f6)"
  fi
  [ -n "$home" ] || return 0
  creds="$home/.git-credentials"
  [ -f "$creds" ] || return 0
  git config --global credential.helper "store --file=$creds" 2>/dev/null \
    || item "WARNING: could not point git at $creds — private repos will not converge"
}

# Seconds of recordings-dir quiet required before a recorder update proceeds.
_RECORDER_QUIET_MIN=2

usage() {
  cat <<'EOF'
appliance-update.sh — pull + rebuild + restart one appliance role when behind

  scripts/service/appliance-update.sh [--check] recorder|processor
  --check, --dry-run   resolve release state without checkout, build, or restart
  -h, --help           show this help

Fetches release tags for the workspace and role repos; exits quietly when every
repo sits on its newest v* tag. When a newer tag exists: checks it out (dirty
repos and repos with no tags are skipped with a warning) and re-runs the role
installer. A tag behind the current checkout is never treated as an update.
Driven by fm-update-<role>.timer.
EOF
}

# True when this role must not be interrupted right now.
_busy() {  # role
  case "$1" in
    recorder)
      # A take in flight = recent episode writes under the recordings dir (bag
      # chunks + sessions.jsonl). Two sibling evidence streams write there
      # CONTINUOUSLY even while the episode recorder sits idle — the tactile
      # bridge under tactile-raw, and the rig monitors' watchdog under
      # watchdog/ (whose jsonl kept this gate reading "busy" on every tick for
      # six days on the first Jetson, 2026-08-19) — so exclude both, or this
      # updater can never converge.
      local recdir="${FM_RECORDER_RECORDINGS_DIR:-$HOME/recordings}"
      local active_file=""
      if [ -d "$recdir" ] && \
         active_file="$(
           find "$recdir" \
             -path "$recdir/tactile-raw" -prune -o \
             -path "$recdir/watchdog" -prune -o \
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
# The pre-release filter matters more here than anywhere: this runs unattended on
# a timer. See lib.sh for why a suffixed tag must never be a convergence target.
command -v latest_release_tag >/dev/null 2>&1 || \
  latest_release_tag() {
    git -C "$1" tag -l 'v[0-9]*' --sort=-v:refname 2>/dev/null \
      | grep -vE '^v[0-9][^-]*-' \
      | head -1
  }

# Fetch one repo's tags; report its release-channel state:
#   current        HEAD is the newest v* tag
#   behind <tag>   a newer v* tag exists — check it out
#   ahead <tag>    HEAD contains the newest tag — wait for a release
#   diverged <tag> HEAD and the newest tag do not share a forward update path
#   untagged       no v* tag yet — the release channel has no target here
#   held           dirty or unfetchable — never moved
_repo_state() {  # dir
  local dir="$1"
  # Tag tips only, shallow when the repo is shallow (--depth 1 appliance
  # clones stay lean). --force: a re-cut tag moves.
  local shallow
  shallow="$(git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null)" \
    || { echo held; return; }
  local -a depth=()
  [ "$shallow" = true ] && depth=(--depth 1)
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
  if [ "$head" = "$tagc" ]; then
    echo current
  elif git -C "$dir" merge-base --is-ancestor "$head" "$tagc" 2>/dev/null; then
    echo "behind $target"
  elif git -C "$dir" merge-base --is-ancestor "$tagc" "$head" 2>/dev/null; then
    echo "ahead $target"
  elif [ "$shallow" = true ]; then
    # A depth-one appliance checkout may not contain the graph between its HEAD
    # and a newly fetched tag. Complete the history only when the first ancestry
    # checks cannot decide; a normal current or one-step release stays shallow.
    git -C "$dir" fetch -q --unshallow origin "$target" 2>/dev/null \
      || { echo held; return; }
    if git -C "$dir" merge-base --is-ancestor "$head" "$tagc" 2>/dev/null; then
      echo "behind $target"
      return
    fi
    if git -C "$dir" merge-base --is-ancestor "$tagc" "$head" 2>/dev/null; then
      echo "ahead $target"
      return
    fi
    echo "diverged $target"
  else
    echo "diverged $target"
  fi
}

main() {
  local role="" check=0
  while [ $# -gt 0 ]; do
    case "$1" in
      recorder|processor)
        [ -z "$role" ] || { echo "error: specify one appliance role" >&2; usage >&2; return 1; }
        role="$1"
        ;;
      --check|--dry-run) check=1 ;;
      -h|--help) usage; return 0 ;;
      *) echo "error: unknown argument '$1'" >&2; usage >&2; return 1 ;;
    esac
    shift
  done
  if [ -z "$role" ]; then
    echo "error: role must be 'recorder' or 'processor'" >&2
    usage >&2
    return 1
  fi

  if [ "$check" = 0 ]; then
    # Overlapping mutating runs (timer tick + manual) collapse to one. Check mode
    # does not need a lock and must not create or truncate updater state.
    exec 9>"/tmp/fm-update-$role.lock"
    if ! flock -n 9; then
      item "another update is already running — skipping"
      return 0
    fi

    # Before the first git call, and before the role installer that also runs git.
    _trust_checkouts
    _reach_private_repos

    if _busy "$role"; then
      return 0
    fi
  fi

  # The workspace itself plus the role's package repos. src/fm_teleop exists
  # only on the recorder (the tracker); absent dirs are simply skipped.
  local -a repos=("$ROOT" "$ROOT/src/fm_data")
  [ "$role" = recorder ] && repos+=("$ROOT/src/fm_teleop")

  local dir state updated=0
  for dir in "${repos[@]}"; do
    [ -d "$dir/.git" ] || continue
    state="$(_repo_state "$dir")"
    if [ "$check" = 1 ]; then
      item "check $(basename "$dir"): $state"
      continue
    fi
    case "$state" in
      behind\ *)
        item "updating $(basename "$dir") -> ${state#behind } ..."
        git -C "$dir" -c advice.detachedHead=false checkout -q "${state#behind }"
        updated=1
        ;;
      untagged)
        item "WARNING: $(basename "$dir") has no release tag yet — left alone (cut a v* tag to put it on the release channel)"
        ;;
      ahead\ *)
        item "WARNING: $(basename "$dir") is ahead of ${state#ahead } — left alone (cut a new release tag before unattended use)"
        ;;
      diverged\ *)
        item "WARNING: $(basename "$dir") diverges from ${state#diverged } — left alone (review the release lineage)"
        ;;
      held)
        item "WARNING: $(basename "$dir") is dirty or unfetchable — left alone"
        ;;
    esac
  done

  # The machine layer is a sibling checkout under the same workspace, not a src/
  # overlay, and it converges through its own entry point rather than this
  # role installer. It is tracked apart from the repos above for two reasons: a
  # machine-layer bump must not drag the ROS stack through a rebuild and a
  # service restart it did not need — on a recorder that restart is an
  # interruption — and the two layers ride their own release tags, so either can
  # move without the other.
  #
  # fm-setup's own scripts/update.sh reads this host's role from the identity
  # card, which is why nothing here maps recorder -> jetson. A timer that
  # hardcoded `install.sh --jetson` would be a second place a machine's role is
  # written down, and the card exists to delete those.
  local fm_setup setup_updated=0
  fm_setup="$(dirname "$ROOT")/fm-setup"
  if [ -d "$fm_setup/.git" ]; then
    state="$(_repo_state "$fm_setup")"
    if [ "$check" = 1 ]; then
      item "check fm-setup: $state"
    else
    case "$state" in
      behind\ *)
        item "updating fm-setup -> ${state#behind } ..."
        git -C "$fm_setup" -c advice.detachedHead=false checkout -q "${state#behind }"
        setup_updated=1
        ;;
      untagged)
        item "WARNING: fm-setup has no release tag yet — left alone (cut a v* tag to put it on the release channel)"
        ;;
      ahead\ *)
        item "WARNING: fm-setup is ahead of ${state#ahead } — left alone (cut a new release tag before unattended use)"
        ;;
      diverged\ *)
        item "WARNING: fm-setup diverges from ${state#diverged } — left alone (review the release lineage)"
        ;;
      held)
        item "WARNING: fm-setup is dirty or unfetchable — left alone"
        ;;
    esac
    fi
  else
    # No checkout, no machine layer. Rigs flashed before the workspace step
    # existed keep fm-setup at ~/.first-motive/fm-setup, outside the workspace
    # this resolves against — so the layer that installs the drivers, the
    # container runtime, and ROS never converged, and the timer reported success
    # on every tick anyway. Silence is what let that go unnoticed on a fleet.
    item "WARNING: no fm-setup checkout at $fm_setup — machine layer not converged"
    item "         link it once: ln -s ~/.first-motive/fm-setup $fm_setup"
  fi

  if [ "$check" = 1 ]; then
    item "release resolution complete — no checkout, build, or service change made"
    return 0
  fi

  # Machine layer first: it owns the drivers, the container runtime, and ROS
  # itself, so a workspace rebuild that follows builds against what this just
  # installed rather than against what was there before.
  if [ "$setup_updated" = 1 ]; then
    if [ -x "$fm_setup/scripts/update.sh" ]; then
      item "machine layer moved — converging fm-setup ..."
      "$fm_setup/scripts/update.sh"
    else
      item "WARNING: fm-setup moved but has no executable scripts/update.sh — machine layer not converged"
    fi
  fi

  if [ "$updated" = 0 ]; then
    [ "$setup_updated" = 1 ] || item "up to date"
    return 0
  fi

  # Something moved: the role installer is the one converge path — idempotent
  # deps + rebuild + service restart (the same command a human runs).
  item "changes pulled — re-running the $role installer ..."
  cd "$ROOT"
  FM_INSTALL_SERVICE=1 \
    FM_BRIDGE_ENV_FILE="${FM_BRIDGE_ENV_FILE:-/etc/fm-bridge.env}" \
    FM_BRIDGE_PORT="$FM_BRIDGE_PORT" \
    FM_BRIDGE_OWNER="$FM_BRIDGE_OWNER" \
    "./scripts/install/setup-$role.sh"
  item "appliance updated ($role)"
}

main "$@"

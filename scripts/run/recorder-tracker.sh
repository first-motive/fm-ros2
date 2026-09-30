#!/usr/bin/env bash
# recorder-tracker.sh — read or set the recorder's hand tracker (on|off).
#
# The tracker is FM_RECORDER_TRACKER in /etc/fm-recorder.env, which recorder-boot.sh
# passes to the launch as tracker:=. Setting it rewrites that one line (every other
# key and comment stays), then restarts fm-recorder so the launch picks it up.
#
#   scripts/run/recorder-tracker.sh                     # on the rig: print the state
#   scripts/run/recorder-tracker.sh on|off              # set it, restart the recorder
#   scripts/run/recorder-tracker.sh off --host fmrec    # from any machine, over ssh
#   scripts/run/recorder-tracker.sh status --json       # one JSON object for Desktop
#
# A set refuses (exit 3) while a take is recording: a restart would cut the open
# .mcap. Setting the value it already has changes nothing and restarts nothing.
# Exit 0 done, 2 usage, 3 refused.
set -uo pipefail

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

HOST="" JSON=false WANT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    status) WANT=""; shift ;;
    on|off) WANT="$1"; shift ;;
    --host)
      [[ "${2:-}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]] || { echo "error: --host needs one SSH host or alias" >&2; exit 2; }
      HOST="$2"; shift 2 ;;
    --json) JSON=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -n "$HOST" ]; then
  remote_args=(${WANT:+"$WANT"}); $JSON && remote_args+=(--json)
  exec ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$HOST" bash -s -- "${remote_args[@]+"${remote_args[@]}"}" < "${BASH_SOURCE[0]}"
fi

ENVFILE=/etc/fm-recorder.env

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Print the result and exit. Refusals carry a stable code for Desktop.
finish() {  # code(ok|<refusal>)  detail  tracker  changed  restarted
  local ok=true status=0
  [ "$1" = ok ] || { ok=false; status=3; }
  if $JSON; then
    printf '{"schema_version":1,"verb":"recorder-tracker","host":"%s","ok":%s,' "$(hostname)" "$ok"
    if $ok; then
      printf '"data":{"tracker":"%s","changed":%s,"restarted":%s,"service":"%s"}}\n' \
        "$3" "$4" "$5" "$(systemctl is-active fm-recorder 2>/dev/null)"
    else
      printf '"error":{"code":"%s","detail":"%s"},"data":{"tracker":"%s"}}\n' "$1" "$(json_escape "$2")" "$3"
    fi
  elif $ok; then
    echo "hand tracker: $3 ($2)"
  else
    echo "hand tracker: $3 — refused: $2" >&2
  fi
  exit "$status"
}

[ -f "$ENVFILE" ] || finish not_installed "$ENVFILE is missing; install the recorder service first" unknown
# The last assignment wins, as it does for systemd's EnvironmentFile.
current="$(sed -n 's/^FM_RECORDER_TRACKER=//p' "$ENVFILE" | tail -1)"
current="${current:-on}"   # recorder-boot.sh's default

[ -n "$WANT" ] || finish ok "from $ENVFILE" "$current" false false
[ "$WANT" != "$current" ] || finish ok "already $current, nothing restarted" "$current" false false

# A take in flight holds its .mcap open. Only the recorder's own user can have it
# open, so this user's /proc is enough and needs no sudo.
recdir="$(sed -n 's/^FM_RECORDER_RECORDINGS_DIR=//p' "$ENVFILE" | tail -1)"
recdir="${recdir:-$HOME/recordings}"
open_bag="$(find /proc/[0-9]*/fd -lname "$recdir/*.mcap*" -print -quit 2>/dev/null)"
[ -z "$open_bag" ] || finish recording "a take is recording (open .mcap under $recdir); stop it first" "$current"
# ponytail: a take started between this check and the restart below is still cut; the
# recorder has no hold-off lock to take, add one there if operators race this.

sudo -n true 2>/dev/null || finish no_sudo "$(id -un) has no passwordless sudo on $(hostname)" "$current"
tmp="$(mktemp)"
if grep -q '^FM_RECORDER_TRACKER=' "$ENVFILE"; then
  sed "s/^FM_RECORDER_TRACKER=.*/FM_RECORDER_TRACKER=$WANT/" "$ENVFILE" > "$tmp"
else
  { cat "$ENVFILE"; echo "FM_RECORDER_TRACKER=$WANT"; } > "$tmp"
fi
# Written beside the target, then renamed over it, so a failure leaves the old file whole.
if ! sudo install -m "$(stat -c %a "$ENVFILE")" -o "$(stat -c %U "$ENVFILE")" -g "$(stat -c %G "$ENVFILE")" \
       "$tmp" "$ENVFILE.new" || ! sudo mv -f "$ENVFILE.new" "$ENVFILE"; then
  rm -f "$tmp"
  finish write_failed "could not write $ENVFILE" "$current"
fi
rm -f "$tmp"

sudo systemctl restart fm-recorder || finish restart_failed "wrote $WANT but fm-recorder did not restart; see journalctl -u fm-recorder" "$WANT"
finish ok "set, fm-recorder restarted" "$WANT" true true

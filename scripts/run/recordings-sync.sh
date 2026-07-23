#!/usr/bin/env bash
# recordings-sync.sh — pull finalized recordings from the recorder host into this
# processor's recordings dir. The transfer half of the two-box split: capture
# stays local on the recorder (never record over a network), and episodes ship
# AFTER they finalize. Driven by fm-sync.timer (install-sync-timer.sh).
#
# Single-box setups need no transfer: with FM_SYNC_SOURCE unset the script exits
# quietly, so the timer is harmless today and a one-line env edit activates the
# split when the recorder moves to its own device.
#
# Knobs (set in /etc/fm-sync.env, the unit's EnvironmentFile):
#   FM_SYNC_SOURCE=<user@host:path | /local/path>   the recorder's recordings dir
#                                                   (empty = single box, no-op)
#   FM_SYNC_DEST=<dir>                              default ~/recordings
#
# Safety posture:
#   - index-driven: only episodes present in the recorder's sessions.jsonl are
#     pulled — the index line is appended at finalize, so an in-flight bag can
#     never ship half-written.
#   - busy gate: recent writes in the source dir (a take in progress) skip the
#     tick rather than compete with capture I/O.
#   - the local index gains a remote episode's line only AFTER its bag landed,
#     so the supervisor never sees an index row without a bag.
#   - nothing is ever deleted on the recorder — retention/pruning is a separate,
#     deliberate step for when the recorder host's disk actually needs it.
#   - remote mode needs key-auth ssh from this host to the recorder.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/lib.sh" ] && . "$ROOT/lib.sh" || item() { echo "$1"; }

INDEX_NAME="sessions.jsonl"
# Minutes of source-dir quiet required before a pull proceeds.
QUIET_MIN=2

usage() {
  cat <<'EOF'
recordings-sync.sh — pull finalized recordings from the recorder host

  scripts/run/recordings-sync.sh          # run one sync pass (timer entry point)
  -h, --help                              # show this help

Configure /etc/fm-sync.env: FM_SYNC_SOURCE=user@host:path (or a local path for
testing); empty means a single-box setup and the pass is a quiet no-op.
EOF
}

# Print the episodes (bag dir + sidecar names) present in the source index but
# absent from the local one — restricted to bags that actually exist at the
# source (a crashed take's index row must not be retried forever). Pure
# stdin/argv python: no temp modules.
_missing_names() {  # source_index_file local_index_file source_listing_file
  python3 - "$1" "$2" "$3" <<'PY'
import json, pathlib, sys

def load(path):
    out = {}
    f = pathlib.Path(path)
    if not f.is_file():
        return out
    for line in f.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(r, dict) and r.get("episode_id"):
            out[r["episode_id"]] = r
    return out

source, local = load(sys.argv[1]), load(sys.argv[2])
listing = set(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8").splitlines())
for eid, r in source.items():
    if eid in local:
        continue
    name = pathlib.Path(str(r.get("path", ""))).name
    if name in ("", ".", "..") or name not in listing:
        continue
    print(name)
    print(name + ".episode.json")
PY
}

# Append source-index lines for episodes whose bag now exists locally and whose
# id the local index lacks. Prints the number of lines appended.
_merge_index() {  # source_index_file local_index_file dest_dir
  python3 - "$1" "$2" "$3" <<'PY'
import json, pathlib, sys

src_path, local_path, dest = sys.argv[1:4]

def load_lines(path):
    f = pathlib.Path(path)
    return f.read_text(encoding="utf-8").splitlines() if f.is_file() else []

local_ids = set()
for line in load_lines(local_path):
    try:
        r = json.loads(line)
    except json.JSONDecodeError:
        continue
    if isinstance(r, dict) and r.get("episode_id"):
        local_ids.add(r["episode_id"])

added = 0
with open(local_path, "a", encoding="utf-8") as out:
    for line in load_lines(src_path):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(r, dict) or not r.get("episode_id"):
            continue
        if r["episode_id"] in local_ids:
            continue
        bag = pathlib.Path(dest) / pathlib.Path(str(r.get("path", ""))).name
        if not bag.is_dir():
            continue
        out.write(line + "\n")
        added += 1
print(added)
PY
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac

  local source="${FM_SYNC_SOURCE:-}"
  local dest="${FM_SYNC_DEST:-$HOME/recordings}"
  dest="${dest/#\~/$HOME}"

  if [ -z "$source" ]; then
    item "no remote recorder configured (single-box setup) — nothing to sync"
    return 0
  fi

  exec 9>/tmp/fm-sync.lock
  if ! flock -n 9; then
    item "another sync is already running — skipping"
    return 0
  fi

  # Remote source is user@host:path; anything without a colon is a local path
  # (useful for tests and odd topologies). All source reads go through $_run.
  local rhost="" rpath="$source"
  case "$source" in
    *:*) rhost="${source%%:*}"; rpath="${source#*:}" ;;
  esac
  _run() {
    if [ -n "$rhost" ]; then ssh -o BatchMode=yes "$rhost" "$*"; else bash -c "$*"; fi
  }

  # Busy gate: a take in progress writes constantly — never compete with it.
  if [ -n "$(_run "find $rpath -mmin -$QUIET_MIN -type f 2>/dev/null | head -1")" ]; then
    item "recorder busy (recent writes at source) — skipping this tick"
    return 0
  fi

  # Globals, not locals: the EXIT trap fires after main() returns, when locals
  # are already out of scope (hit live as an unbound-variable at exit).
  src_index="$(mktemp)"
  src_listing="$(mktemp)"
  list="$(mktemp)"
  trap 'rm -f "${src_index:-}" "${src_listing:-}" "${list:-}"' EXIT

  _run "cat $rpath/$INDEX_NAME 2>/dev/null" > "$src_index" || true
  if [ ! -s "$src_index" ]; then
    item "source has no $INDEX_NAME yet — nothing to sync"
    return 0
  fi

  mkdir -p "$dest"
  _run "ls -1 $rpath 2>/dev/null" > "$src_listing" || true
  _missing_names "$src_index" "$dest/$INDEX_NAME" "$src_listing" > "$list"
  if [ ! -s "$list" ]; then
    item "up to date"
    return 0
  fi

  # Two names (bag dir + sidecar) per episode.
  item "pulling $(( $(wc -l < "$list") / 2 )) episode(s) from $source ..."
  # -r explicitly: --files-from disables the recursion -a normally implies.
  # --ignore-missing-args: an old episode without a sidecar is not an error.
  rsync -a -r --partial --ignore-missing-args --files-from="$list" \
    "$source/" "$dest/"

  local added
  added="$(_merge_index "$src_index" "$dest/$INDEX_NAME" "$dest")"
  item "synced — $added episode(s) added to the local index"
}

main "$@"

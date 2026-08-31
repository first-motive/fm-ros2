#!/usr/bin/env bash
# The dataset verb: turn recorded episodes into a processing manifest, and check
# that what came out is usable.
#
#   ./scripts/run/dataset.sh process              # ~/recordings -> ~/processed
#   ./scripts/run/dataset.sh process --strict     # fail on a quarantined episode
#   ./scripts/run/dataset.sh verify               # assert the manifest is sound
#
# The engine itself lives in fm_data (`dataset_process`), and this verb does not
# reimplement any of it — it resolves the two directories, routes the call to the
# runtime that has the engine, and then grades the result. `verify` is
# the half that matters in CI: a manifest that exists but describes zero episodes
# is a loop that ran and recorded nothing, which is exactly the failure a
# green "artifacts exist" check would hide.
#
# Which runtime: the PROCESSOR's, wherever the processor role is installed — native
# Humble on 22.04, its own container elsewhere. `--backend` is about the recording's
# provenance, not about where the engine runs, and routing on it sent the engine
# into the sim stack's container, which is built without it (fm-ros2#145). Only a
# host with no processor role falls back to the stack container, which is what a
# laptop running the sim-first loop is.
set -euo pipefail

cd "$(dirname "$0")/../.."

# shellcheck source=scripts/internal/lib-stack.sh
source scripts/internal/lib-stack.sh
# shellcheck source=scripts/internal/lib-processor.sh
source scripts/internal/lib-processor.sh

# dataset_exec <overlay> <command...>
# Run one engine command where the engine is. Same argument shape as
# fm_stack_exec, so the call sites below read the same either way.
dataset_exec() {
  local overlay="$1"
  shift
  if fm_processor_installed; then
    fm_processor_exec "$PWD" "$@"
  else
    fm_stack_exec "$overlay" "$@"
  fi
}

# Pull episodes this host is missing from the recorder, before processing them.
#
# The two-box split had no working transfer: fm-sync.timer needs FM_SYNC_SOURCE
# and a rig-to-rig SSH key the tailnet policy does not grant, so takes were being
# relayed by hand through an operator's laptop (fm-ros2#146). fm-comms already
# served episodes over the transport the fleet runs on, and nothing called it.
#
# Deliberately not fatal, and deliberately host-side: the queryable's client is a
# uv project in comms/, not a ROS package, and a processor with the episodes
# already local must still process them when no recorder is reachable.
pull_episodes() {  # recordings-dir
  # Expanded HERE, unlike every other path in this verb: the pull runs on this
  # host, so a literal `~/recordings` would create a directory named `~`.
  local recordings="${1/#\~/$HOME}"
  fm_processor_installed || return 0
  [[ -d comms/episodes ]] || return 0
  # uv is installed per-user, and a systemd unit or a non-interactive `ssh host cmd`
  # does not get ~/.local/bin on PATH — the pull skipped itself on a rig that had
  # uv all along (gate 4.2). Look where the installer puts it before giving up.
  local uv=""
  if command -v uv >/dev/null 2>&1; then
    uv=uv
  elif [[ -x "$HOME/.local/bin/uv" ]]; then
    uv="$HOME/.local/bin/uv"
  else
    echo ">> skipping the episode pull: uv is not installed" >&2
    return 0
  fi
  echo ">> pulling episodes this host is missing"
  "$uv" run --project comms/episodes episodes-fetch --recordings-dir "$recordings" \
    || echo ">> episode pull did not complete — processing what is already local" >&2
}

usage() {
  cat <<'EOF'
dataset.sh — process recorded episodes into a manifest, and verify it

Usage: ./scripts/run/dataset.sh <process|verify|profile> [options]

  process   run the fm_data engine over the recorded episodes
  verify    assert the manifest exists and describes at least one episode
  profile   write a processing profile derived from the engine's default

  --input D      recorded-episode directory (default ~/recordings)
  --output D     processing output directory (default ~/processed);
                 for profile, the JSON file to write
  --config F     processing profile JSON (default: the engine's own)
  --set K=V      (profile) override one dotted key, e.g.
                 thresholds.outcome_labeling.outcome_mode=source_label_only;
                 repeatable
  --strict       (process) exit non-zero on a quarantined or dropped episode
  --backend B    backend the stack was brought up on (default mujoco)
  --real         shorthand for --backend real
  -h, --help     show this help
EOF
}

# Read the manifest the engine wrote and assert it describes usable work: it
# exists, it names episodes, and at least one of them was kept or repaired rather
# than quarantined or dropped. Existence alone is not a passing loop — a run that
# recorded nothing, and a run whose every episode failed validation, both leave a
# manifest behind.
#
# Parsed with python from the ROS environment rather than jq, which the image
# does not carry — the same reason the org's CI helpers avoid it. The path is
# expanded by the far-side shell before python sees it (fm_stack_remote_path).
verify_manifest() {
  local overlay="$1" manifest="$2"
  local checker='
import json, sys
from pathlib import Path

USABLE = {"kept", "repaired"}

path = Path(sys.argv[1])
if not path.is_file():
    sys.exit(f"FAIL: no manifest at {path}")
episodes = json.loads(path.read_text()).get("episodes", [])
if not episodes:
    sys.exit(f"FAIL: {path} describes zero episodes")
usable = [e for e in episodes if e.get("disposition") in USABLE]
if not usable:
    seen = ", ".join(sorted({str(e.get("disposition")) for e in episodes}))
    # A verdict without its reason cannot be acted on. The engine records why
    # per stage (manifest EpisodeReport.stages[].reasons); name the stages that
    # did not keep the episode, with their reasons and scores.
    for e in episodes:
        label = e.get("episode_id", "unknown")
        state = e.get("disposition")
        print(f"  {label}: {state}", file=sys.stderr)
        for s in e.get("stages", []):
            if s.get("disposition") in USABLE and not s.get("reasons"):
                continue
            stage, verdict = s.get("stage"), s.get("disposition")
            reasons = "; ".join(s.get("reasons", []))
            scores = json.dumps(s.get("scores", {}), default=str)[:400]
            print(f"    {stage}: {verdict} — {reasons} {scores}", file=sys.stderr)
    sys.exit(f"FAIL: {len(episodes)} episode(s), none usable ({seen})")
print(f"PASS: {len(usable)}/{len(episodes)} episode(s) usable in {path}")
'
  # The checker rides in as $1 so no quoting of its own survives into the shell;
  # the manifest path is inlined so the far-side shell expands its $HOME.
  dataset_exec "$overlay" bash -lc \
    "python3 -c \"\$1\" \"$manifest\"" fm-verify "$checker"
}

# Write a processing profile derived from the engine's own default with a few
# dotted keys overridden. A whole-file copy would go stale the day the default
# changes; deriving at run time keeps every gate the loop does not name exactly
# as the engine ships it. Values parse as JSON when they can, else as strings.
write_profile() {
  local overlay="$1" out="$2"
  shift 2
  local writer='
import json, sys
from pathlib import Path
from fm_data_dataset.core.config import default_config_path

out, sets = sys.argv[1], sys.argv[2:]
data = json.loads(Path(default_config_path()).read_text())
for item in sets:
    key, _, raw = item.partition("=")
    try:
        value = json.loads(raw)
    except ValueError:
        value = raw
    node = data
    parts = key.split(".")
    for part in parts[:-1]:
        node = node.setdefault(part, {})
    node[parts[-1]] = value
Path(out).parent.mkdir(parents=True, exist_ok=True)
Path(out).write_text(json.dumps(data, indent=2) + "\n")
print(f"wrote profile {out} ({len(sets)} override(s))")
'
  local -a quoted=()
  local s
  for s in "$@"; do quoted+=("$(printf '%q' "$s")"); done
  echo ">> deriving profile -> $out"
  dataset_exec "$overlay" bash -lc \
    "python3 -c \"\$1\" \"$out\" ${quoted[*]}" fm-profile "$writer"
}

main() {
  # shellcheck disable=SC2088  # deliberate: expanded by the far-side shell via
  # fm_stack_remote_path, not by this one.
  local action="" input="" output="" config=""
  local strict=false backend=mujoco real=false
  local -a sets=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        return 0
        ;;
      process | verify | profile)
        action="$1"
        shift
        ;;
      --input)
        input="$2"
        shift 2
        ;;
      --input=*)
        input="${1#--input=}"
        shift
        ;;
      --output)
        output="$2"
        shift 2
        ;;
      --output=*)
        output="${1#--output=}"
        shift
        ;;
      --config)
        config="$2"
        shift 2
        ;;
      --config=*)
        config="${1#--config=}"
        shift
        ;;
      --strict)
        strict=true
        shift
        ;;
      --backend)
        backend="$2"
        shift 2
        ;;
      --backend=*)
        backend="${1#--backend=}"
        shift
        ;;
      --real)
        real=true
        shift
        ;;
      --set)
        sets+=("$2")
        shift 2
        ;;
      --set=*)
        sets+=("${1#--set=}")
        shift
        ;;
      *)
        echo "error: unknown argument '$1'" >&2
        return 2
        ;;
    esac
  done

  if [[ -z "$action" ]]; then
    usage >&2
    echo "error: expected one of process, verify, profile" >&2
    return 2
  fi

  if [[ "$real" == true ]]; then
    if [[ "$backend" != mujoco ]]; then
      echo "error: --real and --backend $backend both set — pick one" >&2
      return 2
    fi
    backend=real
  fi

  # Where this host keeps recordings, in priority order: what the caller asked
  # for, then what the processor role is configured with, then the verb's own
  # default. The middle one is the whole point — a rig with a data volume is not
  # using ~/recordings, and neither should the verb.
  if [[ -z "$input" ]]; then
    input="$(fm_processor_env FM_PROCESSOR_RECORDINGS_DIR)"
    # shellcheck disable=SC2088  # deliberate: expanded by the far-side shell
    input="${input:-'~/recordings'}"
    input="${input//\'/}"
  fi
  if [[ -z "$output" ]]; then
    output="$(fm_processor_env FM_PROCESSOR_OUTPUT_DIR)"
    # shellcheck disable=SC2088  # deliberate: expanded by the far-side shell
    output="${output:-'~/processed'}"
    output="${output//\'/}"
  fi

  backend=$(fm_stack_normalize "$backend")
  fm_stack_check_backend "$backend"

  local overlay
  overlay=$(fm_stack_overlay "$backend")

  if [[ -n "${FM_SELFTEST:-}" ]]; then
    local runtime=stack
    fm_processor_installed && runtime="processor ($(fm_processor_runtime 2>/dev/null || echo unresolved))"
    echo "selftest ok: dataset $action resolved (input=$input, output=$output, strict=$strict, runtime=$runtime)"
    return 0
  fi

  # dataset_process is an ament_python console script: it lives under the
  # package's lib/ dir, not on PATH, so it is reached through `ros2 run` (the
  # processor role's venv is the one place the bare name also works). Its
  # paths need the same `~` treatment the episode index does.
  local remote_input remote_output
  remote_input=$(fm_stack_remote_path "$input")
  remote_output=$(fm_stack_remote_path "$output")

  case "$action" in
    process)
      local cmd="ros2 run fm_data_dataset dataset_process --input \"$remote_input\" --output \"$remote_output\""
      [[ -n "$config" ]] && cmd+=" --config \"$(fm_stack_remote_path "$config")\""
      [[ "$strict" == true ]] && cmd+=" --strict"
      pull_episodes "$input"
      echo ">> processing $input -> $output"
      dataset_exec "$overlay" bash -lc "$cmd"
      ;;
    verify)
      verify_manifest "$overlay" "$remote_output/manifest.json"
      ;;
    profile)
      write_profile "$overlay" "$remote_output" "${sets[@]}"
      ;;
  esac
}

main "$@"

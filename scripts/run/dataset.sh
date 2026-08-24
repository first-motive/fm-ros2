#!/usr/bin/env bash
# The dataset verb: turn recorded episodes into a processing manifest, and check
# that what came out is usable.
#
#   ./scripts/run/dataset.sh process              # ~/recordings -> ~/processed
#   ./scripts/run/dataset.sh process --strict     # fail on a quarantined episode
#   ./scripts/run/dataset.sh verify               # assert the manifest is sound
#
# The engine itself lives in fm_data (`dataset_process`), and this verb does not
# reimplement any of it — it resolves the two directories, routes the call to
# wherever ROS is (container or host), and then grades the result. `verify` is
# the half that matters in CI: a manifest that exists but describes zero episodes
# is a loop that ran and recorded nothing, which is exactly the failure a
# green "artifacts exist" check would hide.
set -euo pipefail

cd "$(dirname "$0")/../.."

# shellcheck source=scripts/internal/lib-stack.sh
source scripts/internal/lib-stack.sh

usage() {
  cat <<'EOF'
dataset.sh — process recorded episodes into a manifest, and verify it

Usage: ./scripts/run/dataset.sh <process|verify> [options]

  process   run the fm_data engine over the recorded episodes
  verify    assert the manifest exists and describes at least one episode

  --input D      recorded-episode directory (default ~/recordings)
  --output D     processing output directory (default ~/processed)
  --config F     processing profile JSON (default: the engine's own)
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
    # A verdict without its reason cannot be acted on: surface every field
    # the engine wrote about why, whatever it named them.
    for e in episodes:
        why = dict((k, v) for k, v in e.items()
                   if any(t in k for t in ("reason", "check", "fail", "quarantin", "drop", "issue", "score")))
        print(f"  {e.get('episode_id', e.get('id', 'unknown'))}: {e.get('disposition')} — {json.dumps(why, default=str)[:900]}", file=sys.stderr)
    sys.exit(f"FAIL: {len(episodes)} episode(s), none usable ({seen})")
print(f"PASS: {len(usable)}/{len(episodes)} episode(s) usable in {path}")
'
  # The checker rides in as $1 so no quoting of its own survives into the shell;
  # the manifest path is inlined so the far-side shell expands its $HOME.
  fm_stack_exec "$overlay" bash -lc \
    "python3 -c \"\$1\" \"$manifest\"" fm-verify "$checker"
}

main() {
  # shellcheck disable=SC2088  # deliberate: expanded by the far-side shell via
  # fm_stack_remote_path, not by this one.
  local action="" input='~/recordings' output='~/processed' config=""
  local strict=false backend=mujoco real=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        return 0
        ;;
      process | verify)
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
      *)
        echo "error: unknown argument '$1'" >&2
        return 2
        ;;
    esac
  done

  if [[ -z "$action" ]]; then
    usage >&2
    echo "error: expected one of process, verify" >&2
    return 2
  fi

  if [[ "$real" == true ]]; then
    if [[ "$backend" != mujoco ]]; then
      echo "error: --real and --backend $backend both set — pick one" >&2
      return 2
    fi
    backend=real
  fi

  backend=$(fm_stack_normalize "$backend")
  fm_stack_check_backend "$backend"

  local overlay
  overlay=$(fm_stack_overlay "$backend")

  if [[ -n "${FM_SELFTEST:-}" ]]; then
    echo "selftest ok: dataset $action resolved (input=$input, output=$output, strict=$strict)"
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
      echo ">> processing $input -> $output"
      fm_stack_exec "$overlay" bash -lc "$cmd"
      ;;
    verify)
      verify_manifest "$overlay" "$remote_output/manifest.json"
      ;;
  esac
}

main "$@"

#!/usr/bin/env bash
# setup-qwen.sh — opt-in provisioning for the REAL annotation model on a
# processor host: uv, an explicitly selected pinned Qwen weights view verified
# against the known inventory identity, the locked cu128 torch runtime, and a
# prewarmed wheel cache. After this, the approval-gated annotation lane
# (fm_data_annotate's annotation_qwen_run) can execute on this box — this
# script only DOWNLOADS; it never loads weights and never runs the model, so
# the lane's human-approval gate is untouched.
#
# Layout matches the existing workstation evidence conventions:
#   ~/fm-data-runs/_model-views/<descriptor>-<rev8>-<inv8>/    weights view
#   ~/fm-data-runs/_model-views/<view>.MODEL_INVENTORY.json    hashed inventory
#   ~/fm-data-runs/_runtime/qwen-cu128/requirements.lock       runtime pins
#
# Opt-in on purpose: each weights view is large, the shared torch wheel cache
# adds several GB, and only GPU hosts benefit. Invoked by setup-processor.sh
# when FM_INSTALL_QWEN=1
# (one-liner: `curl … | FM_INSTALL_QWEN=1 bash -s -- --processor --service`),
# by the process_supervisor's /process/provision command, or standalone.
#
# Usage:
#   ./scripts/install/setup-qwen.sh            # Qwen2.5 baseline (idempotent)
#   ./scripts/install/setup-qwen.sh --model qwen3.5-9b
#   ./scripts/install/setup-qwen.sh uninstall  # remove the weights view + lock copy
set -euo pipefail

# lib.sh fallback keeps the script runnable over `ssh 'bash -s'`.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/../.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/lib.sh" ] && . "$ROOT/lib.sh" || item() { echo "$1"; }

QWEN_ROOT="${FM_QWEN_ROOT:-$HOME/fm-data-runs}"
LOCK_DIR="$QWEN_ROOT/_runtime/qwen-cu128"
LOCK_SRC="$ROOT/scripts/install/qwen/requirements-cu128.lock"
TORCH_INDEX="https://download.pytorch.org/whl/cu128"
MODEL_SOURCE="${FM_QWEN_MODEL_SOURCE:-$ROOT/src/fm_data/fm_data_annotate}"
MODEL_KEY="qwen2.5-vl-7b"
REPO_ID=""
REVISION=""
EXPECTED_INVENTORY_SHA=""
PYTHON_VERSION=""
VIEW_NAME=""
VIEW_DIR=""
INVENTORY_FILE=""
# Free space needed for a cold Qwen3.5 install: weights + wheel cache + slack.
NEED_GB=40

usage() {
  cat <<'EOF'
setup-qwen.sh — provision the real annotation model (opt-in, GPU hosts)

  (no args)    install the baseline pinned Qwen2.5 model
  --model KEY  explicitly select qwen3.5-9b or qwen2.5-vl-7b
  install      install uv, download + verify the selected Qwen weights view,
               install the locked cu128 runtime pins, prewarm the wheel cache
  uninstall    remove the weights view, its inventory, and the lock copy
               (uv and the shared uv cache are left alone)
  -h, --help   show this help

Knobs: FM_QWEN_ROOT (default ~/fm-data-runs), FM_QWEN_MODEL_SOURCE.
Downloading needs the network;
nothing here loads weights or runs the model — execution stays approval-gated.
EOF
}

load_model_descriptor() {
  [ -d "$MODEL_SOURCE" ] || {
    echo "ERROR: fm_data_annotate model descriptor source missing: $MODEL_SOURCE" >&2
    return 1
  }
  local fields=()
  while IFS= read -r field; do
    fields+=("$field")
  done < <(
      PYTHONPATH="$MODEL_SOURCE" "$(_engine_python)" \
        -m fm_data_annotate.qwen_models "$MODEL_KEY" --fields
    )
  [ "${#fields[@]}" -eq 9 ] || {
    echo "ERROR: Qwen model descriptor did not return the expected fields" >&2
    return 1
  }
  MODEL_KEY="${fields[0]}"
  REPO_ID="${fields[2]}"
  REVISION="${fields[3]}"
  EXPECTED_INVENTORY_SHA="${fields[4]}"
  PYTHON_VERSION="${fields[6]}"
  VIEW_NAME="$MODEL_KEY-${REVISION:0:8}-${EXPECTED_INVENTORY_SHA:0:8}"
  VIEW_DIR="$QWEN_ROOT/_model-views/$VIEW_NAME"
  INVENTORY_FILE="$QWEN_ROOT/_model-views/$VIEW_NAME.MODEL_INVENTORY.json"
}

_uv() {
  # uv may have just been installed to ~/.local/bin, which a fresh service
  # shell does not have on PATH.
  if command -v uv >/dev/null 2>&1; then uv "$@"; else "$HOME/.local/bin/uv" "$@"; fi
}

_engine_python() {
  # The processor's engine venv carries fm_data_annotate — its canonical-JSON
  # encoder is the identity-bearing one, so the inventory hash matches the
  # run-spec contract exactly.
  local candidate="$ROOT/.engine-venv/bin/python"
  if [ -x "$candidate" ]; then echo "$candidate"; else command -v python3; fi
}

do_install() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "WARNING: no nvidia-smi on this host — the real annotation model needs" >&2
    echo "         an NVIDIA GPU; skipping Qwen provisioning." >&2
    return 0
  fi

  local free_gb
  free_gb=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
  if [ "${free_gb:-0}" -lt "$NEED_GB" ] && [ ! -d "$VIEW_DIR" ]; then
    echo "ERROR: ~${NEED_GB} GB free needed under \$HOME for the model view; have ${free_gb:-?} GB." >&2
    return 1
  fi

  if ! command -v uv >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/uv" ]; then
    item "installing uv (user-local) ..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi

  # Runtime pins: written only when absent so an existing box's run-spec
  # binding (the lock's hash) is never silently changed underneath it.
  mkdir -p "$LOCK_DIR"
  if [ -f "$LOCK_DIR/requirements.lock" ]; then
    if [ -f "$LOCK_SRC" ] && ! cmp -s "$LOCK_SRC" "$LOCK_DIR/requirements.lock"; then
      item "WARNING: existing runtime lock differs from the repo copy — keeping the existing one (run specs bind its hash)"
    fi
  elif [ -f "$LOCK_SRC" ]; then
    item "installing the cu128 runtime lock ..."
    cp "$LOCK_SRC" "$LOCK_DIR/requirements.lock"
  else
    echo "ERROR: runtime lock missing ($LOCK_SRC) and none installed — run from an fm-ros2 checkout." >&2
    return 1
  fi

  if [ -d "$VIEW_DIR" ] && [ -f "$INVENTORY_FILE" ]; then
    item "weights view already provisioned ($VIEW_NAME) — skipping download"
  elif [ -d "$VIEW_DIR" ]; then
    # A view without its inventory sibling (e.g. hand-provisioned before this
    # script existed): verify what is on disk instead of re-downloading 16 GB.
    item "verifying the existing weights view against the pinned identity ..."
    _verify_and_write_inventory "$VIEW_DIR"
  else
    item "downloading $REPO_ID @ ${REVISION:0:8} (large pinned model view) ..."
    local staging="$QWEN_ROOT/_model-views/.staging-$VIEW_NAME"
    # Unconditional, including onto an existing staging directory: the download
    # is resumable and a no-op once complete, so an interrupt costs only the
    # shards it had not reached. Skipping it when the directory exists dead-ends
    # a partial download instead - verification refuses the missing shards, and
    # every later attempt refuses the same way (fm-ws-01's qwen3.5, stalled at
    # two of four shards since 28 August).
    mkdir -p "$staging"
    _uv run --quiet --python "$PYTHON_VERSION" --no-project \
      --with huggingface_hub python - "$staging" <<PY
import sys
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="$REPO_ID",
    revision="$REVISION",
    local_dir=sys.argv[1],
)
PY
    item "verifying the download against the pinned inventory identity ..."
    _verify_and_write_inventory "$staging"
    rm -rf "$staging/.cache"
    mv "$staging" "$VIEW_DIR"
    item "weights view promoted: $VIEW_DIR"
  fi
  item "prewarming the locked cu128 runtime (torch wheels, first time ~6 GB) ..."
  _uv run --quiet --python "$PYTHON_VERSION" --no-project \
    --extra-index-url "$TORCH_INDEX" --index-strategy unsafe-best-match \
    --with-requirements "$LOCK_DIR/requirements.lock" \
    python -c "import torch; print('torch', torch.__version__, 'cuda', torch.cuda.is_available())" \
    || item "WARNING: runtime prewarm failed — the first real run will retry the resolve"

  item "qwen provisioning complete: $VIEW_NAME"
}

# Hash a directory's regular files into the pinned inventory shape, refuse a
# mismatch with the expected content identity, and write the inventory sibling
# on success. Dot DIRECTORIES (HF bookkeeping under .cache/) are excluded; dot
# FILES like .gitattributes are part of the identity.
_verify_and_write_inventory() {  # directory holding the weights
  "$(_engine_python)" - "$1" "$INVENTORY_FILE" <<PY
import hashlib, json, sys
from pathlib import Path

target, inventory_out = Path(sys.argv[1]), Path(sys.argv[2])
try:
    from fm_data_annotate.canonical import canonical_json_bytes
except ImportError:  # non-processor host: same canonical form, inlined
    def canonical_json_bytes(obj):
        return (json.dumps(obj, ensure_ascii=False, sort_keys=True,
                           separators=(",", ":")) + "\n").encode("utf-8")

files = []
total = 0
for path in sorted(target.rglob("*")):
    rel = path.relative_to(target)
    if any(part.startswith(".") for part in rel.parts[:-1]):
        continue
    if not path.is_file() or path.is_symlink():
        continue
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    size = path.stat().st_size
    files.append({"path": rel.as_posix(), "sha256": digest, "size_bytes": size})
    total += size
inventory = {
    "file_count": len(files),
    "files": files,
    "repo_id": "$REPO_ID",
    "revision": "$REVISION",
    "total_bytes": total,
}
raw = canonical_json_bytes(inventory)
sha = hashlib.sha256(raw).hexdigest()
if sha != "$EXPECTED_INVENTORY_SHA":
    print(f"ERROR: inventory sha {sha} != pinned $EXPECTED_INVENTORY_SHA", file=sys.stderr)
    print("       (corrupt or unexpected content; view NOT promoted)", file=sys.stderr)
    raise SystemExit(1)
inventory_out.write_bytes(raw)
print(f"inventory verified: {sha}")
PY
}

do_uninstall() {
  item "removing the weights view + inventory + lock copy ..."
  rm -rf "$VIEW_DIR"
  rm -f "$INVENTORY_FILE"
  rm -f "$LOCK_DIR/requirements.lock"
  item "left alone: uv itself and the shared uv wheel cache"
}

main() {
  local action="install"
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --model) MODEL_KEY="$2"; shift 2 ;;
      install|uninstall) action="$1"; shift ;;
      *) usage; echo; echo "ERROR: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  load_model_descriptor
  case "$action" in
    install) do_install ;;
    uninstall) do_uninstall ;;
  esac
}

main "$@"

#!/usr/bin/env bash
# setup-qwen.sh — opt-in provisioning for the REAL annotation model on a
# processor host: uv, the pinned Qwen2.5-VL-7B weights view (content-verified
# against the known inventory identity), the locked cu128 torch runtime, and a
# prewarmed wheel cache. After this, the approval-gated annotation lane
# (fm_data_annotate's annotation_qwen_run) can execute on this box — this
# script only DOWNLOADS; it never loads weights and never runs the model, so
# the lane's human-approval gate is untouched.
#
# Layout matches the existing workstation evidence conventions:
#   ~/fm-data-runs/_model-views/qwen2.5-vl-7b-<rev7>-<inv8>/   weights view
#   ~/fm-data-runs/_model-views/<view>.MODEL_INVENTORY.json    hashed inventory
#   ~/fm-data-runs/_runtime/qwen-cu128/requirements.lock       runtime pins
#
# Opt-in on purpose: ~16 GB of weights plus ~6 GB of torch wheels, and only
# GPU hosts benefit. Invoked by setup-processor.sh when FM_INSTALL_QWEN=1
# (one-liner: `curl … | FM_INSTALL_QWEN=1 bash -s -- --processor --service`),
# by the process_supervisor's /process/provision command, or standalone.
#
# Usage:
#   ./scripts/install/setup-qwen.sh            # provision (idempotent)
#   ./scripts/install/setup-qwen.sh uninstall  # remove the weights view + lock copy
set -euo pipefail

# lib.sh fallback keeps the script runnable over `ssh 'bash -s'`.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/../.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/lib.sh" ] && . "$ROOT/lib.sh" || item() { echo "$1"; }

# The model pin — one revision, one content identity. The inventory SHA is the
# canonical-JSON hash of the file inventory; a download that does not reproduce
# it is refused (wrong revision, corrupt file, or upstream tampering).
REPO_ID="Qwen/Qwen2.5-VL-7B-Instruct"
REVISION="cc594898137f460bfe9f0759e9844b3ce807cfb5"
EXPECTED_INVENTORY_SHA="8d5c9508bc873c2628aaf824f88414cefc486b120fb8d49887353b01c05a9548"
VIEW_NAME="qwen2.5-vl-7b-${REVISION:0:8}-${EXPECTED_INVENTORY_SHA:0:8}"

QWEN_ROOT="${FM_QWEN_ROOT:-$HOME/fm-data-runs}"
VIEW_DIR="$QWEN_ROOT/_model-views/$VIEW_NAME"
INVENTORY_FILE="$QWEN_ROOT/_model-views/$VIEW_NAME.MODEL_INVENTORY.json"
LOCK_DIR="$QWEN_ROOT/_runtime/qwen-cu128"
LOCK_SRC="$ROOT/scripts/install/qwen/requirements-cu128.lock"
TORCH_INDEX="https://download.pytorch.org/whl/cu128"
# Free space needed for a cold install: weights + wheel cache + slack.
NEED_GB=30

usage() {
  cat <<'EOF'
setup-qwen.sh — provision the real annotation model (opt-in, GPU hosts)

  (no args)    install uv, download + verify the pinned Qwen weights view,
               install the locked cu128 runtime pins, prewarm the wheel cache
  uninstall    remove the weights view, its inventory, and the lock copy
               (uv and the shared uv cache are left alone)
  -h, --help   show this help

Knobs: FM_QWEN_ROOT (default ~/fm-data-runs). Downloading needs the network;
nothing here loads weights or runs the model — execution stays approval-gated.
EOF
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
    item "downloading $REPO_ID @ ${REVISION:0:8} (~16 GB) ..."
    local staging="$QWEN_ROOT/_model-views/.staging-$VIEW_NAME"
    rm -rf "$staging"
    mkdir -p "$staging"
    _uv run --quiet --no-project --with huggingface_hub python - "$staging" <<PY
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
  _uv run --quiet --no-project \
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
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
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
  case "${1:-install}" in
    -h|--help) usage ;;
    install) do_install ;;
    uninstall) do_uninstall ;;
    *) usage; echo; echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
  esac
}

main "$@"

#!/usr/bin/env bash
# Package the registry robots as browser-ready 3D model packages, end to end:
# resolve.py inside the pixi ROS env, then package.py under uv. See README.md.
set -euo pipefail

usage() {
  cat <<'EOF'
run.sh — package the registry robots as web 3D model packages (URDF + GLB)

Usage: ./scripts/tools/robot-web-models/run.sh [--work DIR] [--out DIR]
                                                [--robots k1,k2] [package.py flags]

  --work DIR      raw URDFs, resolved.json, and the GLB cache
                  (default: <first-motive>/.showcase-work/robot-models-work)
  --out DIR       output root; packages land in <out>/models/
                  (default: <first-motive>/.showcase-work/out)
  --robots LIST   comma-separated robot keys (default: all four)
  --no-optimize   ship the plain trimesh GLB, skip gltf-transform
  --force         redo every conversion, ignore the cache
  --jobs N        parallel mesh conversions (default 4)
  -h, --help      show this help

Needs: the pixi env with install/ built (resolve step), uv and node/npx
(package step). Any other flag is passed to package.py unchanged.
EOF
}

main() {
  local HERE ROOT PARENT
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ROOT="$(cd "$HERE/../../.." && pwd)"
  PARENT="$(cd "$ROOT/.." && pwd)"

  local WORK="$PARENT/.showcase-work/robot-models-work"
  local OUT="$PARENT/.showcase-work/out"
  local ROBOTS=""
  local PASS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --work) WORK="$2"; shift 2 ;;
      --out) OUT="$2"; shift 2 ;;
      --robots) ROBOTS="$2"; shift 2 ;;
      *) PASS+=("$1"); shift ;;
    esac
  done

  cd "$ROOT"
  if [ ! -f install/setup.bash ]; then
    echo "run.sh: no install/setup.bash; build the workspace first (pixi run build)" >&2
    return 1
  fi
  for tool in pixi uv npx; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "run.sh: $tool not found on PATH" >&2
      return 1
    fi
  done
  mkdir -p "$WORK" "$OUT"

  local RESOLVE_ARGS=(--work "$WORK")
  local PACKAGE_ARGS=(--work "$WORK" --out "$OUT")
  if [ -n "$ROBOTS" ]; then
    RESOLVE_ARGS+=(--robots "$ROBOTS")
    PACKAGE_ARGS+=(--robots "$ROBOTS")
  fi

  echo "== resolve (pixi env)"
  # The install overlay sets variables that trip `set -u`; relax it around the source.
  pixi run bash -c 'set +u; source install/setup.bash >/dev/null 2>&1; set -u; exec python "$@"' \
    _ "$HERE/resolve.py" "${RESOLVE_ARGS[@]}"

  echo "== package (uv env)"
  uv run --no-project --with trimesh --with numpy python "$HERE/package.py" \
    "${PACKAGE_ARGS[@]}" ${PASS[@]+"${PASS[@]}"}
}

main "$@"

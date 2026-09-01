#!/usr/bin/env bash
# install-foxglove-service.sh — install the standalone Foxglove bridge owner.
#
# This is the tower-safe mode: Axol may reserve 8765 while this service owns the
# configured First Motive bridge port (8766 on fmtower). It also edits the
# recorder env to disable its embedded bridge, leaving exactly one owner.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib.sh"
# shellcheck disable=SC1091
. "$ROOT/scripts/env/bridge.sh"
# shellcheck disable=SC1091
. "$ROOT/scripts/internal/lib-processor.sh"
cd "$ROOT"

UNIT=/etc/systemd/system/fm-foxglove.service
RECORDER_ENV=/etc/fm-recorder.env
BRIDGE_ENV="${FM_BRIDGE_ENV_FILE:-/etc/fm-bridge.env}"
WRAPPER="$ROOT/scripts/service/foxglove-boot.sh"

# Offline CI can exercise runtime validation and unit rendering without touching
# /etc or invoking a real systemd service. The test still executes this installer;
# it only redirects managed paths and stops before restart/start/probe.
if [ "${FM_FOXGLOVE_SERVICE_TEST_MODE:-0}" = 1 ]; then
  : "${FM_FOXGLOVE_SERVICE_TEST_ROOT:?FM_FOXGLOVE_SERVICE_TEST_ROOT is required in test mode}"
  UNIT="$FM_FOXGLOVE_SERVICE_TEST_ROOT/systemd/fm-foxglove.service"
  RECORDER_ENV="$FM_FOXGLOVE_SERVICE_TEST_ROOT/etc/fm-recorder.env"
  BRIDGE_ENV="${FM_BRIDGE_ENV_FILE:-$FM_FOXGLOVE_SERVICE_TEST_ROOT/etc/fm-bridge.env}"
  export FM_BRIDGE_ENV_FILE="$BRIDGE_ENV"
fi

SERVICE_USER="${SUDO_USER:-$USER}"
# `getent` is Linux-only; keep --help and the platform guard usable on macOS.
SERVICE_HOME="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$SERVICE_HOME" ] || SERVICE_HOME="$HOME"

usage() {
  cat <<'EOF'
install-foxglove-service.sh — install/remove the standalone Foxglove bridge (Linux)

  (no args)       install + enable + start at the configured port
  --port PORT     persist a bridge port before installing (default 8765)
  uninstall       stop + disable + remove the service; keep bridge config
  -h, --help      show this help

The installer writes /etc/fm-bridge.env, disables FM_RECORDER_FOXGLOVE in
/etc/fm-recorder.env when that file exists, and refuses to start over an
existing listener. On a tower with Axol on 8765, use --port 8766. On a Linux
host without native Humble it uses the already-running fm-processor container;
it never creates or recreates that container.
EOF
}

_require_linux_systemd() {
  [ "${FM_FOXGLOVE_SERVICE_TEST_MODE:-0}" = 1 ] && return 0
  if [ "$(uname -s)" != Linux ]; then
    echo "WARNING: the standalone Foxglove service is Linux-only — skipping." >&2
    return 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "WARNING: systemctl not found (no systemd) — skipping the service." >&2
    return 1
  fi
}

_run_priv() {
  if [ "${FM_FOXGLOVE_SERVICE_TEST_MODE:-0}" = 1 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

_set_recorder_bridge() {  # value
  local value="$1"
  [ -f "$RECORDER_ENV" ] || return 0
  if _run_priv grep -q '^FM_RECORDER_FOXGLOVE=' "$RECORDER_ENV"; then
    _run_priv sed -i -E "s#^FM_RECORDER_FOXGLOVE=.*#FM_RECORDER_FOXGLOVE=$value#" "$RECORDER_ENV"
  else
    printf 'FM_RECORDER_FOXGLOVE=%s\n' "$value" | _run_priv tee -a "$RECORDER_ENV" >/dev/null
  fi
}

_validate_processor_runtime() {
  local runtime=""
  if ! runtime="$(fm_processor_runtime)"; then
    echo "ERROR: cannot resolve the ROS 2 runtime for fm-foxglove.service" >&2
    return 1
  fi
  case "$runtime" in
    native)
      ;;
    container)
      [ -f "$ROOT/docker/compose.yaml" ] || {
        echo "ERROR: processor container compose files are missing at $ROOT/docker" >&2
        echo "       Prepare the processor role before installing fm-foxglove.service." >&2
        return 1
      }
      fm_processor_compose "$ROOT"
      if ! "${FM_COMPOSE[@]}" ps --status running --services 2>/dev/null \
          | grep -Fxq fm; then
        echo "ERROR: the prepared processor container is not running" >&2
        echo "       Start fm-processor.service (or the processor compose role), then retry." >&2
        return 1
      fi
      ;;
    *)
      echo "ERROR: unsupported processor runtime '$runtime'" >&2
      return 1
      ;;
  esac
  FM_FOXGLOVE_RUNTIME="$runtime"
}

do_install() {
  _require_linux_systemd || return 0
  [ -f "$WRAPPER" ] || { echo "ERROR: $WRAPPER missing — cannot install the service." >&2; return 1; }

  # Validate the runtime and, for the container path, the already-prepared role
  # before changing bridge ownership or recorder configuration. The bridge route
  # must never create or recreate a processor container as an installer side effect.
  _validate_processor_runtime || return 1

  local port_arg="${1:-}"
  if [ -n "$port_arg" ]; then
    if [ "${FM_FOXGLOVE_SERVICE_TEST_MODE:-0}" = 1 ]; then
      FM_BRIDGE_ENV_FILE="$BRIDGE_ENV" FM_BRIDGE_NO_SUDO=1 \
        ./scripts/install/install-bridge-config.sh --port "$port_arg" --owner standalone
    else
      FM_BRIDGE_ENV_FILE="$BRIDGE_ENV" ./scripts/install/install-bridge-config.sh \
        --port "$port_arg" --owner standalone
    fi
  else
    if [ "${FM_FOXGLOVE_SERVICE_TEST_MODE:-0}" = 1 ]; then
      FM_BRIDGE_ENV_FILE="$BRIDGE_ENV" FM_BRIDGE_NO_SUDO=1 \
        ./scripts/install/install-bridge-config.sh --owner standalone
    else
      FM_BRIDGE_ENV_FILE="$BRIDGE_ENV" ./scripts/install/install-bridge-config.sh --owner standalone
    fi
  fi
  # Reload the durable file after the installer created it.
  # shellcheck disable=SC1091
  . "$ROOT/scripts/env/bridge.sh"

  _set_recorder_bridge false
  # Stop our previous instance before the conflict check. A different process
  # remains visible and causes a loud, actionable refusal below.
  _run_priv systemctl stop fm-foxglove.service 2>/dev/null || true
  if fm_bridge_port_in_use "$FM_BRIDGE_PORT"; then
    echo "error: cannot install fm-foxglove.service; FM_BRIDGE_PORT=$FM_BRIDGE_PORT is already listening." >&2
    echo "       Inspect it with: sudo ss -ltnp 'sport = :$FM_BRIDGE_PORT'" >&2
    echo "       Stop the competing Axol/embedded bridge, then retry." >&2
    return 1
  fi

  # Keep the host wrapper as ExecStart for both runtimes. It resolves native vs
  # container at boot and, on the container path, exports the existing-only and
  # recursion guard markers before entering container-exec.sh. Calling
  # container-exec.sh directly here would fall back to its lifecycle-owning
  # `up -d` path and could recreate the prepared processor role.
  local exec_start="/bin/bash $WRAPPER" exec_stop="" requires="" after="network-online.target"
  if [ "$FM_FOXGLOVE_RUNTIME" = container ]; then
    exec_stop="ExecStop=/bin/bash $ROOT/scripts/service/container-exec.sh stop 'foxglove-boot.sh'"
    requires="Requires=docker.service"
    after="network-online.target docker.service"
  fi

  item "writing $UNIT (User=$SERVICE_USER, HOME=$SERVICE_HOME, port=$FM_BRIDGE_PORT, runtime=$FM_FOXGLOVE_RUNTIME) ..."
  _run_priv tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=First Motive standalone Foxglove bridge (port $FM_BRIDGE_PORT)
After=$after
Wants=network-online.target
$requires
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
Environment=HOME=$SERVICE_HOME
EnvironmentFile=-$RECORDER_ENV
EnvironmentFile=-$BRIDGE_ENV
WorkingDirectory=$ROOT
ExecStart=$exec_start
$exec_stop
TimeoutStopSec=15
# A deliberate stop first ends the wrapper inside the container, then systemd
# sends SIGTERM to this unit's compose exec, which exits 143. Without this the
# journal records every clean stop as a failure, so a real one stops standing out.
SuccessExitStatus=143
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  if [ "${FM_FOXGLOVE_SERVICE_TEST_MODE:-0}" = 1 ]; then
    echo "fm-foxglove test: rendered $UNIT (service not started)"
    return 0
  fi

  # The recorder can remain running while its env is changed, but restarting it
  # here applies the single-owner setting before this bridge binds.
  if _run_priv systemctl is-active --quiet fm-recorder.service; then
    item "restarting fm-recorder.service with its embedded bridge disabled ..."
    _run_priv systemctl restart fm-recorder.service
  fi
  item "enabling + starting fm-foxglove.service ..."
  _run_priv systemctl daemon-reload
  _run_priv systemctl enable fm-foxglove.service
  _run_priv systemctl restart fm-foxglove.service

  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if python3 "$ROOT/scripts/internal/bridge-probe.py"; then
      break
    fi
    [ "$attempt" -eq 10 ] || sleep 1
  done
  python3 "$ROOT/scripts/internal/bridge-probe.py" >/dev/null

  cat <<EOF

fm-foxglove.service installed and started — it owns ws://<this-host-ip>:$FM_BRIDGE_PORT.
  status:  systemctl status fm-foxglove
  logs:    journalctl -u fm-foxglove -f
  config:  sudo nano $BRIDGE_ENV   (then: sudo systemctl restart fm-foxglove)
  recorder: FM_RECORDER_FOXGLOVE=false in $RECORDER_ENV
EOF
}

do_uninstall() {
  _require_linux_systemd || return 0
  item "stopping + disabling fm-foxglove.service (if present) ..."
  _run_priv systemctl disable --now fm-foxglove.service 2>/dev/null || true
  _run_priv rm -f "$UNIT"
  _run_priv systemctl daemon-reload 2>/dev/null || true
  item "fm-foxglove.service removed; $BRIDGE_ENV was kept so its port survives updates."
  item "To restore the embedded default, set FM_BRIDGE_OWNER=embedded and FM_RECORDER_FOXGLOVE=true explicitly."
}

main() {
  local port=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port)
        [ "$#" -ge 2 ] || { echo "error: --port needs a value" >&2; exit 2; }
        port="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      uninstall)
        [ -z "$port" ] || { echo "error: uninstall cannot combine with --port" >&2; return 2; }
        do_uninstall; return $? ;;
      *) echo "error: unknown argument '$1'" >&2; usage >&2; return 2 ;;
    esac
  done
  do_install "$port"
}

main "$@"

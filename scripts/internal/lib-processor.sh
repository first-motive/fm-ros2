#!/usr/bin/env bash
# Where the processor role runs on this host. Sourced by setup-processor.sh and
# the service installers — never executed.
#
# Two runtimes, one role:
#
#   native     ROS 2 Humble on the host (Ubuntu 22.04). Build and services run
#              directly, as they always have.
#   container  the host is Linux without Humble (the fm-setup workstation is
#              26.04 / Lyrical). Build and launch run inside the published Humble
#              image on the Linux compose overlay; systemd units on the host exec
#              into it (#127, option 1). The workspace and the user's home are
#              bind-mounted at their host paths, so every ~/recordings-shaped
#              knob means the same thing on both sides.
#
# Native on a non-22.04 Linux host (option 2 in #127) is future work: it needs
# the Humble gate dropped and a Lyrical CI job, and nothing here blocks it.

# The compose project the processor owns. Without it the role ran under the
# checkout directory's name, which the sim stack's checkout carries too, and the
# two shared one container (#135).
# shellcheck source=lib-compose.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-compose.sh"

# fm_processor_runtime
# Echo native | container. Fails with a message when neither is possible.
# FM_PROCESSOR_RUNTIME, when set, is the answer — the container re-exec sets it,
# and a host can pin it.
fm_processor_runtime() {
  if [ -n "${FM_PROCESSOR_RUNTIME:-}" ]; then
    printf '%s\n' "$FM_PROCESSOR_RUNTIME"
    return 0
  fi
  if [ -f /opt/ros/humble/setup.bash ] || fm_processor_is_jammy; then
    echo native
    return 0
  fi
  if [ "$(uname -s)" = Linux ] && fm_processor_has_docker; then
    echo container
    return 0
  fi
  cat >&2 <<'MSG'
ERROR: ROS 2 Humble not found at /opt/ros/humble, this host is not Ubuntu 22.04
       (the one distro its binaries target), and docker is not reachable — so the
       processor can run neither natively nor in the Humble container. Install
       docker (fm-setup's docker step), or Humble: https://docs.ros.org/en/humble/Installation.html
MSG
  return 1
}

# Split out so a test can stub them: the real checks read the host.
fm_processor_is_jammy() {
  # shellcheck disable=SC1091
  [ "$(. /etc/os-release 2>/dev/null && echo "${ID:-}:${VERSION_ID:-}")" = "ubuntu:22.04" ]
}
fm_processor_has_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# Directories the processor overlay bind-mounts (compose.processor.yaml). Created
# below the shared data root before the first `up`, so docker never creates them
# root-owned. A provisioned workstation owns /data; a standalone developer host
# falls back to HOME.
FM_PROCESSOR_MOUNTS=(recordings processed annotations fm-data-runs dataset-releases lerobot-staged)

# Roles Anywhere material is deliberately a separate, read-only mount set.  It
# must never be folded into the HOME bind mount: the latter would expose SSH and
# Git credentials to the Humble container.  The identity installer creates these
# paths before compose starts; this helper only verifies that a container launch
# cannot silently proceed with Docker-created root-owned placeholders.
FM_PROCESSOR_IDENTITY_MOUNTS=(
  "${FM_AWS_IDENTITY_ETC_DIR:-/etc/fm-aws-identity}"
  "${FM_AWS_IDENTITY_STATE_DIR:-/var/lib/fm-processor/identity}"
)

# fm_processor_compose <workspace-root>
# Fill FM_COMPOSE with the compose invocation for the processor container: the
# shared base, the Linux overlay, and the processor overlay that mounts $HOME.
# shellcheck disable=SC2034  # FM_COMPOSE is read by the caller
fm_processor_compose() {
  local root="$1"
  export FM_IMAGE="${FM_IMAGE:-ghcr.io/first-motive/fm-app:humble}"
  export FM_WS="$root"
  export FM_PROCESSOR_UV_PYTHON_ROOT="${FM_PROCESSOR_UV_PYTHON_ROOT:-$HOME/.local/share/uv/python}"
  [ -d "$FM_PROCESSOR_UV_PYTHON_ROOT" ] || {
    echo "ERROR: managed uv Python root is missing: $FM_PROCESSOR_UV_PYTHON_ROOT" >&2
    echo "       Run the processor setup from the provisioned workstation account." >&2
    return 1
  }
  if [ -z "${FM_PROCESSOR_DATA_ROOT:-}" ]; then
    if [ -d /data ] && [ -w /data ]; then
      export FM_PROCESSOR_DATA_ROOT=/data
    else
      export FM_PROCESSOR_DATA_ROOT="$HOME"
    fi
  fi
  FM_COMPOSE=(docker compose -p "$(fm_compose_project processor)" \
    -f "$root/docker/compose.yaml" -f "$root/docker/compose.linux.yaml" \
    -f "$root/compose.processor.yaml")
  if [ -f "${FM_AWS_IDENTITY_ETC_DIR:-/etc/fm-aws-identity}/aws-config" ]; then
    FM_COMPOSE+=(-f "$root/compose.processor.aws.yaml")
  fi
}

# fm_processor_prepare_mounts
# Create the bind-mounted data directories below the resolved shared data root.
fm_processor_prepare_mounts() {
  local d root="${FM_PROCESSOR_DATA_ROOT:-$HOME}"
  for d in "${FM_PROCESSOR_MOUNTS[@]}"; do mkdir -p "$root/$d"; done
}

# fm_processor_prepare_identity_mounts
# Fail closed when the identity installer has not completed its protected
# directories and the complete pinned AWS CLI runtime.  The compose overlay
# mounts them read-only and puts the runtime's own bin directory on PATH.
fm_processor_prepare_identity_mounts() {
  local path aws_install aws_runtime
  [ -f "${FM_AWS_IDENTITY_ETC_DIR:-/etc/fm-aws-identity}/aws-config" ] || return 0
  for path in "${FM_PROCESSOR_IDENTITY_MOUNTS[@]}"; do
    # The identity service user owns a mode-0700 parent. A normal installer
    # cannot stat its child, while Docker can mount it. Probe only directory
    # existence with noninteractive privilege; never widen identity access.
    test -d "$path" || sudo -n -- /usr/bin/test -d "$path" 2>/dev/null || {
      echo "ERROR: processor identity path is missing or cannot be verified: $path" >&2
      echo "       Check the identity installation and noninteractive sudo access." >&2
      return 1
    }
  done
  aws_install="${FM_AWS_IDENTITY_AWS_INSTALL_DIR:-/usr/local/aws-cli}"
  [ -d "$aws_install" ] || {
    echo "ERROR: pinned AWS CLI install tree is missing: $aws_install" >&2
    echo "       Run scripts/install/install-processor-identity.sh first." >&2
    return 1
  }
  aws_runtime="$aws_install/v2/current/bin/aws"
  [ -x "$aws_runtime" ] || {
    echo "ERROR: pinned AWS CLI runtime is missing or not executable: $aws_runtime" >&2
    echo "       Run scripts/install/install-processor-identity.sh first." >&2
    return 1
  }
}

# fm_processor_import_docker <workspace-root>
# Clone the shared container infra into docker/ at the tag fm-ros2.repos pins,
# when it is absent. The processor role skips the full `vcs import` (it needs
# none of the package repos), so it fetches the one entry it does need.
fm_processor_import_docker() {
  local root="$1" url version
  [ -d "$root/docker" ] && return 0
  url="$(awk '/^  docker:/{f=1} f && /url:/{print $2; exit}' "$root/fm-ros2.repos")"
  version="$(awk '/^  docker:/{f=1} f && /version:/{print $2; exit}' "$root/fm-ros2.repos")"
  [ -n "$url" ] && [ -n "$version" ] || { echo "ERROR: no docker entry in fm-ros2.repos" >&2; return 1; }
  git clone --quiet --depth 1 --branch "$version" "$url" "$root/docker"
}

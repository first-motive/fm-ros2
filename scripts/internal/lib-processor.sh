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

# The transport this host speaks, sourced at load exactly as the stack library
# does it. fm_compose_transport reads what the profile resolved, and the callers
# that build a processor container (container-exec.sh, setup-processor.sh,
# install-foxglove-service.sh) do not source a profile of their own — without this
# they would start the processor on `none` on a zenoh host, and its nodes would
# publish where the host's bridge is not listening.
#
# Guarded, because this library is also sourced from synthetic workspaces in the
# service tests, which carry the libraries and none of the profiles. A real
# checkout always has the file — it is tracked — so an absence is a fixture, and
# saying so beats aborting every caller.
_fm_processor_comms="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/env/comms.sh"
if [ -f "$_fm_processor_comms" ]; then
  # shellcheck source=../env/comms.sh disable=SC1091
  . "$_fm_processor_comms"
else
  echo "processor: no scripts/env/comms.sh beside this library — the container will" >&2
  echo "           inherit whatever middleware its image defaults to." >&2
fi
unset _fm_processor_comms

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
# on the host before the first `up`, so docker never creates them root-owned.
FM_PROCESSOR_MOUNTS=(recordings processed annotations fm-data-runs dataset-releases)

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
  # The processor container is host-networked too, so it joins the host's DDS
  # island the same way the sim stack's does.
  fm_compose_transport "$root/docker/compose.linux.yaml"
  FM_COMPOSE=(docker compose -p "$(fm_compose_project processor)" \
    -f "$root/docker/compose.yaml" -f "$root/docker/compose.linux.yaml" \
    -f "$root/compose.processor.yaml")
  if [ -f "${FM_AWS_IDENTITY_ETC_DIR:-/etc/fm-aws-identity}/aws-config" ]; then
    FM_COMPOSE+=(-f "$root/compose.processor.aws.yaml")
  fi
}

# fm_processor_prepare_mounts
# Create the bind-mounted data directories under $HOME, user-owned.
fm_processor_prepare_mounts() {
  local d
  for d in "${FM_PROCESSOR_MOUNTS[@]}"; do mkdir -p "$HOME/$d"; done
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

# fm_processor_installed
# 0 when this host carries the processor role. The role's EnvironmentFile is the
# marker: install-processor-service.sh writes it, and nothing else does.
#
# Used to decide where a dataset verb runs. `fm dataset process` used to resolve
# the SIM stack's compose project, so on a workstation it ran the engine inside a
# container built without it and reported `Package 'fm_data_dataset' not found`
# while the processor container sat beside it with the engine built (fm-ros2#145).
fm_processor_installed() {
  [ -f "${FM_PROCESSOR_ENV_FILE:-/etc/fm-processor.env}" ]
}

# fm_processor_exec <workspace-root> <command...>
# Run one command in the processor's runtime — natively on a Humble host, or
# through the role's own container anywhere else. The same split the systemd units
# take (scripts/service/container-exec.sh), so a verb and a unit cannot end up
# running the engine in two different places.
fm_processor_exec() {
  local root="${1:?workspace root}"
  shift
  case "$(fm_processor_runtime)" in
    native)
      "$@"
      ;;
    *)
      fm_processor_compose "$root"
      # Through the image entrypoint: `exec` skips ENTRYPOINT, so ROS and the
      # workspace overlay would be unsourced and every `ros2 run` would fail.
      "${FM_COMPOSE[@]}" exec -T fm /ros_entrypoint.sh "$@"
      ;;
  esac
}

# The supervisors' node-facing Python deps, healed by asking the question the
# launch asks rather than by keeping a list.
#
# fm_data declares them (`<exec_depend>python3-jsonschema</exec_depend>`) and
# rosdep installs them where its database is usable. Inside the published Humble
# image it is not, and the miss does not surface at install — it surfaces at boot,
# as process_supervisor dying on `No module named 'jsonschema'` while systemd
# reports the service started (#134).
#
# Import-driven rather than a hand-kept list: the packages already declare their
# dependencies, and a second copy of that list here would drift from them.
#
# Both sides of the container boundary need this, which is why it lives here.
# On a Humble host the ROS interpreter is the host's, and setup-processor.sh heals
# it at install. On a host whose processor runs in the container (#127) the ROS
# interpreter is the container's, so the install-time heal runs against an
# interpreter the nodes never use — there, processor-boot.sh heals at boot, inside.

# fm_processor_supervisor_import_error <workspace-root>
# Echo the import error the supervisors raise under the ROS interpreter, empty when
# they import cleanly. Run in a subshell by every caller, so the overlay it sources
# never leaks into the rest of the script.
fm_processor_supervisor_import_error() {  # workspace-root
  local root="${1:?workspace root}"
  # Neither errexit nor nounset: the overlay's setup.bash reads unset variables by
  # design, and a failing import is the answer being collected rather than a reason
  # to abort.
  set +eu
  # shellcheck disable=SC1091
  . "$root/install/setup.bash" >/dev/null 2>&1
  # Only the error text is wanted: stderr takes over the caller's stdout, then the
  # command's own stdout is dropped. Order matters — the redirections are applied
  # left to right, so this is not "both to /dev/null".
  # shellcheck disable=SC2069  # deliberate: stderr to the caller, stdout dropped
  python3 -c 'import fm_data_dataset.process_supervisor, fm_data_dataset.release_supervisor' 2>&1 1>/dev/null
  return 0
}

# fm_processor_install_for_ros_python <module>
# Install one module for the ROS interpreter — never the engine venv, which only
# the dataset_process subprocess uses.
fm_processor_install_for_ros_python() {  # module
  if python3 -m pip --version >/dev/null 2>&1; then
    python3 -m pip install --quiet "$1"
  elif [ "$(id -u)" = 0 ]; then
    apt-get install -y "python3-$1"
  else
    sudo apt-get install -y "python3-$1"
  fi
}

# fm_processor_heal_imports <workspace-root>
# Install what the supervisors turn out to be missing. 0 when they import cleanly
# afterwards, 1 with the error on stderr when they still do not — the caller
# decides whether that is fatal.
fm_processor_heal_imports() {  # workspace-root
  local root="${1:?workspace root}" error module _attempt
  # Three passes: each install can reveal the next missing module.
  for _attempt in 1 2 3; do
    error="$(fm_processor_supervisor_import_error "$root")"
    [ -z "$error" ] && return 0
    module="$(printf '%s' "$error" | sed -n "s/.*No module named '\([^']*\)'.*/\1/p" | head -1)"
    # Anything that is not a missing module (a syntax error, a broken build) is not
    # this step's to fix, and a missing WORKSPACE package is a build problem —
    # installing a same-named thing from an index would paper over it.
    case "${module:-none}" in
      none | fm_data*) break ;;
    esac
    echo "processor: installing '$module' for the ROS interpreter" >&2
    fm_processor_install_for_ros_python "$module" || true
  done
  error="$(fm_processor_supervisor_import_error "$root")"
  [ -z "$error" ] && return 0
  printf '%s\n' "$error" | sed 's/^/       /' >&2
  return 1
}

# fm_processor_env <key>
# Echo one value from the processor role's EnvironmentFile, or nothing.
#
# The role's directories are configured, not assumed: a rig with a data volume
# reads /data/recordings while the verb's own default is ~/recordings. `fm dataset
# process` used its default on such a host and pointed the engine at a directory
# the processor container does not even mount — it reported the input as missing
# while the episodes sat where the service would have found them (gate 4.2).
#
# Parsed rather than sourced: the file belongs to a systemd unit and may carry
# anything, and sourcing it would import all of it into the verb's shell.
fm_processor_env() {  # key
  local key="${1:?env key}" file="${FM_PROCESSOR_ENV_FILE:-/etc/fm-processor.env}"
  [ -f "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -1
}

# fm_processor_heal_bag_tier <workspace-root>
# Install the engine's bag-ingest tier for the ROS interpreter when it is absent.
#
# On a Humble host setup-processor.sh puts this in the engine venv. In the
# container there is no venv — dataset_process runs under the ROS interpreter — and
# nothing installed it there, so every `fm dataset process` over a real recording
# stopped at "bag ingest requires the package-owned bag tier" (gate 4.2).
#
# The tier resolves on the container's Python 3.10 now that requirements-image.txt
# splits its numpy pin on a marker (fm-ros2#145); before that it could not have
# been installed here at all.
#
# Idempotent and quiet once satisfied: one import decides.
fm_processor_heal_bag_tier() {  # workspace-root
  local root="${1:?workspace root}" tier
  python3 -c 'import rosbags' >/dev/null 2>&1 && return 0
  tier="$root/src/fm_data/fm_data_dataset/requirements-bags.txt"
  if [ ! -f "$tier" ]; then
    echo "processor: no bag tier at $tier — bag ingest will refuse" >&2
    return 0
  fi
  echo "processor: installing the bag-ingest tier for the ROS interpreter" >&2
  python3 -m pip install --quiet -r "$tier" || {
    echo "processor: the bag tier did not install — bag ingest will refuse" >&2
    return 0
  }
}

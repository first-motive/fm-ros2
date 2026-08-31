#!/usr/bin/env bash
# The processor runtime resolution (#127): native on Humble or 22.04, container on
# a Linux host with docker, a plain refusal otherwise, and an explicit pin wins.
# The host checks are stubbed so this runs on any CI guest.
set -euo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. scripts/internal/lib-processor.sh

fail=0
check() {  # label expected  (stubs set by the caller)
  local got
  got="$(fm_processor_runtime 2>/dev/null)" || got=error
  if [ "$got" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 — got '$got', want '$2'"; fail=1; fi
}

uname() { echo Linux; }
fm_processor_is_jammy() { return 1; }
fm_processor_has_docker() { return 1; }

if [ -f /opt/ros/humble/setup.bash ]; then
  check "humble on the host resolves native" native
else
  check "no humble, no jammy, no docker refuses" error
  fm_processor_has_docker() { return 0; }
  check "linux + docker resolves container" container
  uname() { echo Darwin; }
  check "docker on macos still refuses" error
  fm_processor_is_jammy() { return 0; }
  check "jammy resolves native" native
fi
FM_PROCESSOR_RUNTIME=container check "an explicit pin wins" container

# Simulate the protected service-user parent even when CI itself runs as root.
# Only the exact read-only probe is permitted; no real sudo or key is needed.
(
  fixture="$(mktemp -d)"
  trap 'rm -rf "$fixture"' EXIT
  export FM_AWS_IDENTITY_ETC_DIR="$fixture/etc"
  export FM_AWS_IDENTITY_AWS_INSTALL_DIR="$fixture/aws-cli"
  protected="$fixture/protected/identity"
  mkdir -p "$FM_AWS_IDENTITY_ETC_DIR" "$protected" \
    "$FM_AWS_IDENTITY_AWS_INSTALL_DIR/v2/current/bin"
  touch "$FM_AWS_IDENTITY_ETC_DIR/aws-config" \
    "$FM_AWS_IDENTITY_AWS_INSTALL_DIR/v2/current/bin/aws"
  chmod +x "$FM_AWS_IDENTITY_AWS_INSTALL_DIR/v2/current/bin/aws"
  FM_PROCESSOR_IDENTITY_MOUNTS=("$FM_AWS_IDENTITY_ETC_DIR" "$protected")
  probe_count=0
  probe_allowed=1
  probe_exists=1
  test() {
    if [ "$#" = 2 ] && [ "$1" = -d ] && [ "$2" = "$protected" ]; then
      return 1
    fi
    builtin test "$@"
  }
  sudo() {
    [ "$#" = 5 ] && [ "$1" = -n ] && [ "$2" = -- ] &&
      [ "$3" = /usr/bin/test ] && [ "$4" = -d ] && [ "$5" = "$protected" ] || return 1
    probe_count=$((probe_count + 1))
    [ "$probe_allowed" = 1 ] && [ "$probe_exists" = 1 ]
  }
  fm_processor_prepare_identity_mounts
  fm_processor_prepare_identity_mounts
  [ "$probe_count" = 2 ]
  echo "PASS: protected identity directory passes repeated read-only privileged probes"
  probe_exists=0
  if fm_processor_prepare_identity_mounts 2>"$fixture/error"; then
    echo "FAIL: missing protected identity directory was accepted" >&2
    exit 1
  fi
  grep -q 'missing or cannot be verified' "$fixture/error"
  echo "PASS: missing protected identity directory is refused"
  probe_exists=1
  probe_allowed=0
  if fm_processor_prepare_identity_mounts 2>"$fixture/error"; then
    echo "FAIL: unavailable noninteractive privilege was accepted" >&2
    exit 1
  fi
  echo "PASS: unavailable noninteractive privilege is refused without prompting"
)

# The container side stacks three compose files; each must exist or be imported.
[ -f compose.processor.yaml ] && [ -f compose.processor.aws.yaml ] && echo "PASS: processor overlays present" || { echo "FAIL: processor overlay missing"; fail=1; }
grep -q 'container-exec.sh' scripts/install/install-processor-service.sh \
  && echo "PASS: processor unit knows the container runtime" || { echo "FAIL: unit ignores runtime"; fail=1; }
grep -q 'prepare_release_runtime' scripts/install/setup-processor.sh \
  && grep -q 'requirements-release.txt' scripts/install/setup-processor.sh \
  && grep -q "FM_INSTALL_RLDS=\${FM_INSTALL_RLDS:-1}" scripts/install/setup-processor.sh \
  && echo "PASS: processor setup installs release and RLDS runtimes" || { echo "FAIL: full data runtime missing"; fail=1; }
grep -q 'FM_PROCESSOR_RELEASE_ROOT=/data/dataset-releases' scripts/install/install-processor-service.sh \
  && grep -q '.release-venv/bin/hf' scripts/service/processor-boot.sh \
  && echo "PASS: processor boot activates shared releases and hf" || { echo "FAIL: release service wiring missing"; fail=1; }
grep -q 'sudo chown -R.*release_venv' scripts/install/setup-processor.sh \
  && grep -q 'PYTHONDONTWRITEBYTECODE=1' scripts/service/processor-boot.sh \
  && echo "PASS: repeated install keeps the release runtime host-writable" || { echo "FAIL: release runtime ownership guard missing"; fail=1; }
grep -q 'FM_PROCESSOR_UV_PYTHON_ROOT' scripts/internal/lib-processor.sh \
  && grep -q '/home/fm/.local/share/uv/python:ro' compose.processor.yaml \
  && echo "PASS: container can execute the host-built release Python" || { echo "FAIL: release Python mount missing"; fail=1; }
grep -q '\.ros-runtime' scripts/internal/lib-processor.sh \
  && grep -q '\.ros-runtime' scripts/service/processor-boot.sh \
  && echo "PASS: ROS Python dependencies survive container recreation" || { echo "FAIL: persistent ROS Python runtime missing"; fail=1; }
grep -q 'git curl ffmpeg' scripts/install/setup-processor.sh \
  && echo "PASS: processor setup installs release media tools" || { echo "FAIL: ffmpeg install missing"; fail=1; }
grep -q 'FM_PROCESSOR_HUGGINGFACE_HOME:-/data/fm-data-runs/huggingface' scripts/service/processor-boot.sh \
  && echo "PASS: Hugging Face auth state uses persistent processor storage" || { echo "FAIL: persistent Hugging Face auth path missing"; fail=1; }
grep -q 'FM_AWS_INFERENCE_SERVICE_MODE' scripts/install/install-processor-service.sh \
  && grep -q 'FM_AWS_INFERENCE_READINESS_DIR' scripts/install/install-processor-service.sh \
  && echo "PASS: processor service exposes the explicit Ohio readiness route" || { echo "FAIL: Ohio readiness route missing"; fail=1; }
grep -q 'annotate_git_commit' scripts/service/processor-boot.sh \
  && grep -q 'FM_PROCESSOR_ANNOTATE_GIT_COMMIT' scripts/service/container-exec.sh \
  && echo "PASS: processor boot carries exact data package source identity" || { echo "FAIL: source identity route missing"; fail=1; }

[ "$fail" = 0 ] && echo "processor runtime: all checks passed"
exit "$fail"

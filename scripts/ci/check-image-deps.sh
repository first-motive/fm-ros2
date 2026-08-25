#!/usr/bin/env bash
# Assert every dependency the assembled workspace declares is present in the image.
#
#   ./scripts/ci/check-image-deps.sh fm-ros2:ci
#
# The images install hand-written apt lists and never run rosdep, so a `<depend>` in a
# package.xml reaches a container only if someone separately remembers a Dockerfile
# line. The declaration and the install list are two copies of the same facts and
# nothing compared them — which is how `joint_state_publisher_gui` went missing and
# broke the container rviz path entirely (fm-robot#35). This is the comparison.
#
# It runs here, not in each package repo, for two reasons found by measuring:
#
#   * The images are layered (fm-docker -> fm-robot -> fm-app) and each layer
#     legitimately lacks what a later one adds. Checking fm-robot's packages against
#     fm-robot's own image reports moveit, rviz2 and the sim backends as missing —
#     all supplied downstream. Only the top of the chain, the image this workspace
#     actually runs, can be held to the full set.
#   * Only here are every repo's package.xml files present at once.
#
# Everything runs inside the image in one invocation: it already carries rosdep, so
# keys are classified against the image's own OS rather than the host's. Running
# rosdep on a Mac resolves the same key differently and reports a page of failures
# that are not real.
#
# Architecture matters, and is not special-cased on purpose. Gazebo has no arm64
# upstream build, so `gz_ros2_control` and `ros_gz_sim` are genuinely absent from the
# arm64 image and the fm-app Dockerfile installs them behind a TARGETARCH conditional.
# CI runs amd64, where they are present. Run this on an Apple Silicon Mac and those
# two are reported missing — correctly. Teaching the check to ignore them would mean
# a hand-maintained exception list, which is the failure mode it exists to remove.
#
# Not errexit: every dependency is checked so one run lists everything missing.
set -uo pipefail

usage() {
  cat <<'EOF'
check-image-deps.sh — assert declared dependencies exist in the image

Usage: ./scripts/ci/check-image-deps.sh <image> [-h]

  <image>      image to check, e.g. fm-ros2:ci
  -h, --help   show this help

Run from the workspace root with src/ populated.
EOF
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac
  local image="${1:?usage: check-image-deps.sh <image>}"

  local ROOT
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  cd "$ROOT" || return 1

  # Mount the sources at a neutral path, never at /ws. The image's entrypoint sources
  # /ws/install/setup.bash, so mounting a built workspace there shadows the image's
  # own overlay with whatever the host last built — on a Mac that is a pixi build
  # full of host paths, and the entrypoint dies before running anything. The question
  # here is what the image contains, so the workspace supplies package.xml files and
  # nothing else.
  # Scope to the repos this manifest assembles. A developer checkout also carries the
  # private learning overlay (fm_data, fm_policy, fm_learning), whose packages the
  # fm-app image is not built to run — holding the image to their dependencies
  # reports gaps that are not the image's to fill. CI clones only the manifest, so
  # without this the check would behave differently on a laptop than in CI, which is
  # its own kind of lie.
  local scoped=""
  while read -r url; do
    local name="${url##*/}"; name="${name%.git}"; name="${name//-/_}"
    [ -d "$ROOT/src/$name" ] && scoped="$scoped /declared/$name"
  done < <(grep -oE 'https://github.com/[^ ]+\.git' "$ROOT/fm-ros2.repos")
  [ -n "$scoped" ] || { echo "error: no manifest repo found under src/" >&2; return 1; }
  echo "==> scope:$(echo "$scoped" | sed 's|/declared/||g')"

  docker run --rm -v "$ROOT/src:/declared:ro" -e SCOPED="$scoped" "$image" bash -lc '
    # No -u: ROS setup.bash reads unset variables by design, and under set -u the
    # shell aborts while sourcing it rather than returning non-zero, so `|| true`
    # cannot save it. This is the second time that trap has bitten in this repo.
    set -o pipefail
    source "/opt/ros/${ROS_DISTRO}/setup.bash" 2>/dev/null || true

    # A name no package can plausibly have. It goes through the same lookup as a real
    # dependency and must come back absent: a lookup that answers "present" for
    # everything is a check that cannot fail, which is the thing this file exists to
    # remove. If this ever passes, the check is broken, not the image.
    CANARY="fm_this_package_does_not_exist"

    # An uninitialised rosdep answers "" for every key, which would silently classify
    # every dependency as workspace-provided and skip the lot. Prove the database
    # works on a key that must resolve before trusting any answer from it.
    rosdep update --rosdistro "${ROS_DISTRO}" >/dev/null 2>&1 || true
    if ! rosdep resolve rclcpp 2>/dev/null | grep -q "^ros-"; then
      echo "FAIL: rosdep cannot resolve rclcpp in this image — its database is unusable,"
      echo "      so every dependency would be skipped and this check would pass blind."
      exit 1
    fi

    declared="$(grep -rhoE "<(exec_depend|depend|build_depend)>[^<]+" \
                  --include=package.xml $SCOPED 2>/dev/null | sed "s/.*>//" | sort -u)"
    own="$(grep -rhoE "<name>[^<]+" --include=package.xml $SCOPED 2>/dev/null |
             sed "s/.*>//" | sort -u)"
    deps="$(comm -23 <(echo "$declared") <(echo "$own"))"

    fails=0 checked=0 skipped=0
    for dep in $deps; do
      resolved="$(rosdep resolve "$dep" 2>/dev/null | grep -v "^#" | tr "\n" " ")"
      if [ -z "$resolved" ]; then
        # No apt package provides it, so it comes from the workspace build (a
        # vendored external like unitree_hg, or a sibling package). Not the image s
        # job to carry, and not this check s business.
        skipped=$((skipped + 1))
        continue
      fi
      checked=$((checked + 1))
      case "$resolved" in
        ros-*)
          # `ros2 pkg prefix` asks what a launch file asks — can this be found at
          # runtime — and is satisfied by an apt install or a workspace build alike.
          ros2 pkg prefix "$dep" >/dev/null 2>&1 && continue ;;
        *)
          dpkg -s $resolved >/dev/null 2>&1 && continue ;;
      esac
      echo "FAIL: $dep is declared in a package.xml but absent from the image"
      echo "      (rosdep resolves it to: $resolved )"
      fails=$((fails + 1))
    done

    if ros2 pkg prefix "$CANARY" >/dev/null 2>&1; then
      echo "FAIL: canary $CANARY resolved — this check cannot detect a missing package"
      fails=$((fails + 1))
    fi

    echo "==> image deps: ${checked} checked, ${skipped} provided by the workspace build,"
    echo "    ${fails} failure(s)"
    [ "$fails" -eq 0 ]
  '
}

main "$@"

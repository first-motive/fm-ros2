#!/usr/bin/env bash
# The compose project each role owns. Sourced by the stack library, the
# processor library, and the run verbs — never executed.
#
# Compose derives a project name from the directory the compose file sits in
# when none is given. Every role here runs compose out of its checkout's
# `docker/`, so the sim stack in ~/fm/fm_ros2 and the processor in
# ~/processor/fm_ros2 both landed on the project `docker` and shared one
# container, `docker-fm-1`. Installing the processor recreated the container
# under the running sim, killing the launch and its logs; `fm stack up`
# afterwards did the same back (#135).
#
#   sim         fm-sim        the robot stack: stack / sim / teleop / foxglove / run.sh
#   processor   fm-processor  the dataset processor's own workspace
#
# One project per role, so each verb's `up`, `exec`, and `down` reach only what
# that role started. FM_COMPOSE_PROJECT overrides it for a host that runs two
# checkouts of the SAME role — role alone does not tell those apart.

# fm_compose_project <role>
# Echo the compose project name for a role.
fm_compose_project() {
  printf '%s\n' "${FM_COMPOSE_PROJECT:-fm-${1:?compose role}}"
}

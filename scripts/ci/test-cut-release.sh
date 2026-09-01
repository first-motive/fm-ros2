#!/usr/bin/env bash
# Offline behavior test for the release guard in scripts/dev/cut-release.sh: a
# workspace missing any manifest repo is refused before any tag is planned, and
# a fully assembled one gets through to the plan. No network, no real remotes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { echo "test-cut-release: $*" >&2; exit 1; }

WS="$TMP_DIR/workspace"
mkdir -p "$WS/scripts/dev"
cp "$ROOT/scripts/dev/cut-release.sh" "$WS/scripts/dev/"
cp "$ROOT/lib.sh" "$WS/"
cat >"$WS/fm-ros2.repos" <<'EOF'
# fixture manifest: two pinned infra repos and two package repos
repositories:
  docker:
    type: git
    url: https://example.invalid/fm-docker.git
    version: v0.1.0
  comms:
    type: git
    url: https://example.invalid/fm-comms.git
    version: v0.1.0
  src/fm_alpha:
    type: git
    url: https://example.invalid/fm-alpha.git
    version: main
  src/fm_beta:
    type: git
    url: https://example.invalid/fm-beta.git
    version: main
EOF

init_repo() {  # dir
  mkdir -p "$1"
  git -C "$1" init -q
}
init_repo "$WS"

# A bare clone: only the root is a checkout.
rc=0
out="$(bash "$WS/scripts/dev/cut-release.sh" 2>&1)" || rc=$?
[ "$rc" = 2 ] || fail "bare clone was not refused (rc=$rc): $out"
for path in docker comms src/fm_alpha src/fm_beta; do
  grep -q "$path" <<<"$out" || fail "refusal does not name missing $path: $out"
done

# Root plus docker/ only: two repos on disk, still not the manifest's set. This
# is the shape the old count-based guard let through.
init_repo "$WS/docker"
rc=0
out="$(bash "$WS/scripts/dev/cut-release.sh" 2>&1)" || rc=$?
[ "$rc" = 2 ] || fail "partial workspace was not refused (rc=$rc): $out"
grep -q "src/fm_alpha" <<<"$out" || fail "refusal does not name the missing package repo: $out"
if grep -q "docker" <<<"$(grep -A20 'no checkout' <<<"$out")"; then
  fail "refusal lists a repo that is checked out: $out"
fi

# Every manifest path present: the guard passes and the plan runs. Each fixture
# repo has no remote, so every one is skipped loudly and nothing is tagged.
init_repo "$WS/comms"
init_repo "$WS/src/fm_alpha"
init_repo "$WS/src/fm_beta"
out="$(bash "$WS/scripts/dev/cut-release.sh" 2>&1)" || fail "assembled workspace was refused: $out"
grep -q "scanned 5 repos" <<<"$out" || fail "assembled workspace did not scan every repo: $out"
grep -q "nothing to release" <<<"$out" || fail "assembled workspace did not reach the plan: $out"

# A private overlay manifest widens the expected set for the member that has it.
cat >"$WS/private-overlay.repos" <<'EOF'
repositories:
  src/fm_private:
    type: git
    url: https://example.invalid/fm-private.git
    version: main
EOF
rc=0
out="$(bash "$WS/scripts/dev/cut-release.sh" 2>&1)" || rc=$?
[ "$rc" = 2 ] || fail "missing overlay repo was not refused (rc=$rc): $out"
grep -q "src/fm_private" <<<"$out" || fail "refusal does not name the overlay repo: $out"

echo "test-cut-release: passed"

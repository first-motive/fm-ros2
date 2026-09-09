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
# repo has no remote, so the release must fail before creating any tag.
init_repo "$WS/comms"
init_repo "$WS/src/fm_alpha"
init_repo "$WS/src/fm_beta"
rc=0
out="$(bash "$WS/scripts/dev/cut-release.sh" 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "an unfetchable repo did not block the release"
grep -q "scanned 5 repos" <<<"$out" || fail "assembled workspace did not scan every repo: $out"
grep -q "could not fetch tags" <<<"$out" || fail "fetch failure was not reported: $out"

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

rm "$WS/private-overlay.repos"
# Real local remotes test tag ordering. Only the GitHub API is replaced.
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = repo ]; then
  basename "$PWD"
elif [[ "$2" == "repos/${FM_TEST_ARCHIVED:-none}" ]]; then
  echo false
elif [[ "$2" == */check-runs ]]; then
  [[ " $* " == *' --slurp '* ]] || exit 1
  # Two pages must produce one verdict, as the real API does with --slurp.
  printf '%s\n' '[{"check_runs":[{"status":"completed","conclusion":"success"}]},{"check_runs":[{"status":"completed","conclusion":"skipped"}]}]' | jq -r "${@: -1}"
else
  echo true
fi
EOF
chmod +x "$TMP_DIR/bin/gh"
export PATH="$TMP_DIR/bin:$PATH"
for path in . docker comms src/fm_alpha src/fm_beta; do
  dir="$WS/$path"
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  git -C "$dir" config user.name 'First Motive CI'
  git -C "$dir" config user.email ci@firstmotive.ai
  git -C "$dir" commit -q --allow-empty -m initial
  git clone -q --bare "$dir" "$TMP_DIR/$(basename "$dir").git"
  git -C "$dir" remote add origin "$TMP_DIR/$(basename "$dir").git"
done
init_repo "$WS/src/fm_retired"
rc=0
out="$(FM_TEST_ARCHIVED=fm_beta bash "$WS/scripts/dev/cut-release.sh" --apply 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "an archived final member did not block the release"
[ -z "$(git -C "$WS" tag -l)" ] || fail "root was tagged before all members passed"
grep -q 'archived or not writable' <<< "$out" || fail "archived refusal was not reported: $out"

mkdir -p "$WS/src/fm_beta/scripts"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WS/src/fm_beta/scripts/check-release.sh"
git -C "$WS/src/fm_beta" add scripts/check-release.sh
git -C "$WS/src/fm_beta" commit -q -m 'reject metadata'
git -C "$WS/src/fm_beta" push -q origin main
if bash "$WS/scripts/dev/cut-release.sh" --apply > "$TMP_DIR/output" 2>&1; then
  fail 'invalid package metadata was released'
fi
[ -z "$(git -C "$WS" tag -l)" ] || fail 'root was tagged before package metadata passed'
# shellcheck disable=SC2016 # The proposed tag is expanded by the fixture hook.
printf '#!/usr/bin/env bash\n[ "$1" = v0.1.0 ]\n' > "$WS/src/fm_beta/scripts/check-release.sh"
git -C "$WS/src/fm_beta" add scripts/check-release.sh
git -C "$WS/src/fm_beta" commit -q -m 'accept metadata'
git -C "$WS/src/fm_beta" push -q origin main
# Simulate interruption between local tag creation and its push.
git -C "$WS" tag -a v0.1.0 -m v0.1.0
bash "$WS/scripts/dev/cut-release.sh" --apply > "$TMP_DIR/output" 2>&1 || fail "valid release failed: $(cat "$TMP_DIR/output")"
git -C "$WS" ls-remote --exit-code origin refs/tags/v0.1.0 >/dev/null || fail 'unpublished local tag was skipped on retry'
for path in . docker comms src/fm_alpha src/fm_beta; do
  [ "$(git -C "$WS/$path" tag -l)" = v0.1.0 ] || fail "missing release for $path"
done
[ -z "$(git -C "$WS/src/fm_retired" tag -l)" ] || fail 'a stale checkout joined the release'

echo "test-cut-release: passed"

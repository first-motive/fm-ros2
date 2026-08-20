#!/usr/bin/env bash
# The checkout paths in a .repos manifest decide what lands under src/. Repos are
# named fm-<kebab>, but src/ is a colcon package tree and colcon aborts when one
# repo lands under two spellings, so every checkout path here is fm_<snake>.
#
# Two things are checked: the tracked manifests hold that spelling, and the
# guard that reads an untracked one refuses a manifest that does not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=/dev/null
. "$ROOT/lib.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Every tracked manifest, whatever it is named. A new one is covered the day it
# is added rather than the day someone remembers to list it here.
# read -r in a loop rather than mapfile: this repo's scripts run on bash 3.2 too.
manifests=()
while IFS= read -r manifest; do
  manifests+=("$manifest")
done < <(git ls-files '*.repos')
if [ "${#manifests[@]}" -eq 0 ]; then
  echo "no tracked .repos manifests found — this test is checking nothing" >&2
  exit 1
fi

for manifest in "${manifests[@]}"; do
  if ! refuse_kebab_manifest "$manifest"; then
    echo "tracked manifest $manifest carries a kebab checkout path" >&2
    exit 1
  fi
done
printf 'checked %d tracked manifest(s): %s\n' \
  "${#manifests[@]}" "${manifests[*]}"

# The guard has to actually refuse. A guard that returns 0 on a bad manifest is
# the failure this test exists to prevent, and it looks identical to a pass.
#
# The fixture names a repo that does not exist: only the checkout path is parsed,
# and this tree is public, so it must not carry the name of a private one.
cat > "$TMP_DIR/kebab.repos" <<'YAML'
repositories:
  src/fm-example:
    type: git
    url: https://github.com/first-motive/fm-example.git
    version: main
YAML
if refuse_kebab_manifest "$TMP_DIR/kebab.repos" 2>/dev/null; then
  echo "refuse_kebab_manifest accepted a kebab checkout path" >&2
  exit 1
fi

# ... and has to accept the snake form, or it would refuse every import.
cat > "$TMP_DIR/snake.repos" <<'YAML'
repositories:
  src/fm_example:
    type: git
    url: https://github.com/first-motive/fm-example.git
    version: main
YAML
if ! refuse_kebab_manifest "$TMP_DIR/snake.repos"; then
  echo "refuse_kebab_manifest rejected a snake checkout path" >&2
  exit 1
fi

# An absent overlay manifest is the normal case for a clone without access.
if ! refuse_kebab_manifest "$TMP_DIR/does-not-exist.repos"; then
  echo "refuse_kebab_manifest failed on an absent manifest" >&2
  exit 1
fi

echo "test-manifest-paths: passed"

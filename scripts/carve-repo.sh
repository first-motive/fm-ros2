#!/usr/bin/env bash
#
# carve-repo.sh — carve one package group out of the fm-ros2 monorepo into its
# own standalone first-motive repo, preserving history.
#
# This is the locked carve-out recipe (see docs/CARVE-RECIPE.md). It runs
# git-filter-repo on a fresh single-branch clone of `main` — never the live
# working tree — then injects governance, per-repo docs, and a standalone CI
# workflow, commits, and (with PUSH=1) creates and pushes the remote.
#
# Usage:
#   scripts/carve-repo.sh <repo-name> <subdir> [drop-subdir ...]
#
#     repo-name    kebab repo + package-domain, e.g. fm-robot
#     subdir       monorepo path promoted to the new repo root, e.g. fm_robot
#                  or a nested path, e.g. fm_learning/fm_data
#     drop-subdir  path(s) removed AFTER promotion — used for fm-learning, whose
#                  thin metapackage drops the carved-out fm_data / fm_policy dirs
#
# Environment:
#   SRC      monorepo path           (default: this repo's toplevel)
#   ASSETS   per-repo asset dir      (default: scripts/carve-assets/<repo-name>)
#            holds README.md, CLAUDE.md, CODEOWNERS, <repo-name>.repos, ci.yml,
#            gitignore, description
#   ORG      github org              (default: first-motive)
#   OUT      output dir for the carve (default: a fresh mktemp dir)
#   PUSH     1 = create remote + push; 0 = local carve only (default: 0)
#
# Examples:
#   scripts/carve-repo.sh fm-robot fm_robot                    # dry, local only
#   PUSH=1 scripts/carve-repo.sh fm-robot fm_robot             # create + push
#   PUSH=1 scripts/carve-repo.sh fm-learning fm_learning \
#                                fm_learning/fm_data fm_learning/fm_policy
#
set -euo pipefail

usage() {
  cat <<'EOF'
carve-repo.sh — carve one package group out of the monorepo into its own repo

Usage:
  scripts/carve-repo.sh <repo-name> <subdir> [drop-subdir ...]
  scripts/carve-repo.sh -h|--help

  repo-name    kebab repo + package-domain, e.g. fm-robot
  subdir       monorepo path promoted to the new repo root, e.g. fm_robot
  drop-subdir  path(s) removed AFTER promotion (fm-learning thin metapackage)
  -h, --help   show this help

Environment:
  SRC      monorepo path           (default: this repo's toplevel)
  ASSETS   per-repo asset dir      (default: scripts/carve-assets/<repo-name>)
  ORG      github org              (default: first-motive)
  OUT      output dir for the carve (default: a fresh mktemp dir)
  PUSH     1 = create remote + push; 0 = local carve only (default: 0)
EOF
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac

  local NAME="${1:?repo-name required}"
  local SUBDIR="${2:?subdir required}"
  shift 2
  local DROPS=("$@")

  local SRC="${SRC:-$(git rev-parse --show-toplevel)}"
  local ASSETS="${ASSETS:-$SRC/scripts/carve-assets/$NAME}"
  local ORG="${ORG:-first-motive}"

  # Validate the names that reach the shell / gh CLI, so a stray value can't inject
  # flags or commands into `gh repo create/edit`.
  [[ "$NAME" =~ ^fm-[a-z0-9-]+$ ]] || { echo "error: bad repo name: $NAME" >&2; return 1; }
  [[ "$ORG"  =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "error: bad org: $ORG" >&2; return 1; }
  local PUSH="${PUSH:-0}"
  local OUT="${OUT:-$(mktemp -d)/$NAME}"

  command -v git-filter-repo >/dev/null 2>&1 || {
    echo "error: git-filter-repo not on PATH (brew install git-filter-repo)" >&2
    return 1
  }
  [ -d "$ASSETS" ] || { echo "error: assets dir not found: $ASSETS" >&2; return 1; }

  echo ">> carving $NAME from $SUBDIR -> $OUT"

  # 1. Fresh single-branch clone of main — isolates the carve from the live tree
  #    and from any in-progress working branch.
  rm -rf "$OUT"
  git clone --single-branch --branch main "file://$SRC" "$OUT"
  cd "$OUT"

  # 2. Heal every rename hop, then promote the group dir to the repo root.
  #    The monorepo moved these packages repeatedly (src/ flatten, fm_vlta split,
  #    group folders); carve-paths.py normalizes all history onto the current paths
  #    so the subdirectory-filter keeps full history instead of truncating at the
  #    last move.
  local PATHS_SPEC
  PATHS_SPEC="$(mktemp)"
  python3 "$SRC/scripts/carve-paths.py" "$SUBDIR" > "$PATHS_SPEC"
  git filter-repo --force --paths-from-file "$PATHS_SPEC"
  git filter-repo --force --subdirectory-filter "$SUBDIR"

  # 3. Drop any sub-dirs carved into their own repos (fm-learning thin meta).
  if [ "${#DROPS[@]}" -gt 0 ]; then
    local d rel
    for d in "${DROPS[@]}"; do
      rel="${d#"$SUBDIR"/}"
      echo ">> dropping $rel"
      git filter-repo --force --invert-paths --path "$rel/"
    done
  fi

  # 4. Inject shared governance straight from the monorepo source of truth.
  cp "$SRC/LICENSE" "$SRC/SECURITY.md" "$SRC/CONTRIBUTING.md" .
  mkdir -p .github/ISSUE_TEMPLATE .github/workflows
  cp "$SRC/.github/dependabot.yml" "$SRC/.github/pull_request_template.md" .github/
  cp "$SRC"/.github/ISSUE_TEMPLATE/* .github/ISSUE_TEMPLATE/

  # 5. Inject per-repo assets.
  cp "$ASSETS/README.md"     README.md
  cp "$ASSETS/CLAUDE.md"     CLAUDE.md
  cp "$ASSETS/CODEOWNERS"    .github/CODEOWNERS
  cp "$ASSETS/$NAME.repos"   "./$NAME.repos"
  cp "$ASSETS/ci.yml"        .github/workflows/ci.yml
  cp "$ASSETS/gitignore"     .gitignore

  # 6. One bootstrap commit on top of the preserved history.
  git add -A
  git commit -m "init: scaffold $NAME from monorepo"

  echo ">> carved $NAME: $(git rev-list --count HEAD) commits, $(git ls-files | wc -l | tr -d ' ') files"

  # 7. Create + push the remote (opt-in).
  if [ "$PUSH" = "1" ]; then
    local DESC
    DESC="$(cat "$ASSETS/description" 2>/dev/null || echo "First Motive ROS2 package")"
    echo ">> creating $ORG/$NAME (private) and pushing"
    gh repo create "$ORG/$NAME" --private -d "$DESC"
    git remote remove origin 2>/dev/null || true
    git remote add origin "https://github.com/$ORG/$NAME.git"
    git push -u origin main
    gh repo edit "$ORG/$NAME" \
      --add-topic first-motive --add-topic ros2 --add-topic "${NAME#fm-}"
    echo ">> pushed: https://github.com/$ORG/$NAME"
  else
    echo ">> local carve only (set PUSH=1 to create + push). repo at: $OUT"
  fi
}

main "$@"

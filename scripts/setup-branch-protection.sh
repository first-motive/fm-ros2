#!/usr/bin/env bash
# Apply branch protection to the First Motive repos so the owner-free-on-main
# governance model (CONTRIBUTING.md) is enforced once the repos are public:
#
#   - Owner pushes to main directly         (enforce_admins=false → admin bypass)
#   - Everyone else branches, opens a PR, an owner (CODEOWNERS) reviews + merges
#   - PRs must pass CI and be up to date with main before merging
#   - No force-push, no branch deletion on main
#
# CODEOWNERS already lives in each repo (* @ubunish). "Require review from Code
# Owners" is the branch-protection setting that makes it binding — free on public
# repos, paid (Team/Enterprise) on private ones. Run this AFTER flipping a repo
# public; on a private repo the API call fails with the upgrade error.
#
# Prerequisites:
#   - gh CLI authenticated as an org admin:  gh auth status
#   - The owner handle in CODEOWNERS (@ubunish) must match the GitHub account
#     that pushes to main — verify before relying on the bypass.
#   - Each repo has run CI at least once, so the status-check contexts below
#     exist; GitHub matches them by job id (see contexts_for).
#
# Usage:
#   ./scripts/setup-branch-protection.sh            # dry-run: print plan only
#   ./scripts/setup-branch-protection.sh --apply    # apply to every repo below
set -euo pipefail

OWNER="first-motive"
BRANCH="main"

# Every repo that goes public. The private learning overlay (fm-data, fm-policy,
# fm-learning) stays private; add it here only if those repos are ever made
# public too.
REPOS=(
  fm-ros2
  fm-robot
  fm-sim
  fm-teleop
  fm-app
)

# Required CI status checks per repo, as a JSON array of job ids (the contexts
# GitHub reports). fm-ros2 runs three jobs; each package repo runs one. Keep this
# in sync with each repo's .github/workflows/ci.yml job ids.
contexts_for() {
  case "$1" in
    fm-ros2) echo '["workspace","macos","panel"]' ;;
    fm-robot|fm-sim|fm-teleop|fm-app) echo '["build-test"]' ;;
    *) echo '[]' ;;
  esac
}

APPLY=false
[[ "${1:-}" == "--apply" ]] && APPLY=true

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not found — https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated — run: gh auth login" >&2; exit 1; }

# Branch-protection payload for one repo. enforce_admins=false keeps
# owner-free-on-main: the owner (admin) pushes straight to main; the rules bind
# everyone else. strict=true requires the PR branch be current with main before
# merge (CONTRIBUTING: "keep the branch current with main").
payload_for() {
  local contexts; contexts="$(contexts_for "$1")"
  cat <<JSON
{
  "required_status_checks": { "strict": true, "contexts": ${contexts} },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true,
  "required_conversation_resolution": true
}
JSON
}

for repo in "${REPOS[@]}"; do
  checks="$(contexts_for "$repo")"
  if ! $APPLY; then
    echo "[dry-run] ${OWNER}/${repo}@${BRANCH}: PR + code-owner review, CI ${checks}, admin bypass, no force-push/delete"
    continue
  fi
  echo "==> Protecting ${OWNER}/${repo}@${BRANCH} (CI ${checks}) ..."
  payload_for "$repo" | gh api \
    --method PUT \
    -H "Accept: application/vnd.github+json" \
    "repos/${OWNER}/${repo}/branches/${BRANCH}/protection" \
    --input - >/dev/null
  echo "    done."
done

$APPLY && echo "All done." || echo "Dry-run only. Re-run with --apply to enforce."

# Contributing to fm-ros2

Commits here are planned, not improvised. Work is drafted as a plan, the commits
are listed and approved before any code is written, and each commit lands at a
planned boundary with its planned message.

## Planned-Commit Workflow

```
plan drafted → commits listed in plan → approved → branch + commit → push, PR, merge
```

1. **Plan** — write the work as a dated plan in `plans/` (gitignored, local only):
   context, architecture, ordered steps, and one declared commit message per step.
2. **Approve** — the plan is reviewed before execution. No coding starts until the
   commit list is agreed.
3. **Branch** — create a working branch from `main` (see Branches below).
4. **Execute** — work the steps. Independent steps may run in parallel; commits stay
   sequential in plan order. If scope shifts mid-execution, pause and update the plan
   before continuing — do not commit work that is not in the plan.
5. **Gate each commit** — tests pass, code reviewed against the project's coding
   principles, and the commit message validated against the format below.
6. **Hand off** — push the branch, open a PR (or use a direct merge for solo,
   low-risk work), then merge.

## Commit Format

`prefix: short phrase` — lowercase prefix, imperative phrase, subject line only.

No body. No trailers. No `Co-Authored-By` unless explicitly requested.

| Prefix | Use |
|--------|-----|
| `init` | First commit of a new repo (bootstrapping only, never after) |
| `feat` | New feature or content |
| `fix` | Bug fix or content correction |
| `docs` | Documentation edits that are not fixes |
| `refactor` | Restructure without changing behavior |
| `chore` | Housekeeping: gitignore, deps, file moves |

Pick the narrowest prefix that fits. If a change spans two, split the commit.

Good:

```
feat: add foxglove bridge and bringup launch
fix: control node joint order
chore: bump mujoco wheel
```

Not:

```
feat: Added Bringup Launch.    (capital, past tense, period)
update: stuff                  (vague, non-standard prefix)
```

## Branches

`main` is canonical — finished, merged work only.

Working branches use the same prefix set: `prefix/short-phrase`.

```
feat/add-search-bar
fix/login-redirect
docs/add-contributing
```

Rules:

- Lowercase, hyphen-separated.
- No `:` or spaces (invalid in git).
- Short — the branch name is not a description.

## Pull Requests

Title uses the commit format: `prefix: short phrase`.

Body:

```markdown
## Summary
- <1-3 bullets, why over what>

## Test Plan
- [ ] <verifiable check>
- [ ] <verifiable check>
```

- Summary explains motivation, not a file-by-file diff.
- Test plan is a checklist, not prose.
- One PR per branch, one concern per PR.

For solo, low-risk work where a PR adds no value, merge the branch straight into
`main` and delete it. For anything reviewed or shared, open a PR.

# Carve-Out Recipe

How a package group is split out of this monorepo into its own standalone
`first-motive` repo, with full git history preserved. This is the locked recipe
used for the polyrepo split (see
[`plans/`](../plans) and [ARCHITECTURE.md](ARCHITECTURE.md)).

## Tooling

| File | Role |
|------|------|
| [`scripts/carve-repo.sh`](../scripts/carve-repo.sh) | Drives one carve end to end: clone → heal history → strip → inject governance → commit → (optionally) create + push the remote |
| [`scripts/carve-paths.py`](../scripts/carve-paths.py) | Emits the `git filter-repo` rename spec that heals every historical rename hop so history survives the carve |
| [`scripts/carve-assets/<repo>/`](../scripts/carve-assets) | Per-repo seed files: `README.md`, `CLAUDE.md`, `CODEOWNERS`, `<repo>.repos`, `ci.yml`, `gitignore`, `description` |

Prerequisite: `brew install git-filter-repo`.

## Why History Needs Healing

A plain `git filter-repo --subdirectory-filter <group>` keeps only commits that
touched the group under its *current* path. These packages moved several times —
`src/` flatten, the `fm_vlta` → `fm_data`/`fm_policy` split, then the group
folders — so a naive filter truncates history at the last move.

```
src/fm_vlta/fm_vlta_dataset  →  fm_vlta/fm_vlta_dataset
                             →  fm_data/fm_data_dataset
                             →  fm_learning/fm_data/fm_data_dataset
```

`carve-paths.py` composes git's exact (100%-similarity) rename pairs backward
through commit history, links every current file to its full lineage, and emits a
file-level `old==>current` rename for each historical path. Feeding that to
filter-repo normalizes all history onto the current paths; the
`--subdirectory-filter` then strips the prefix with history intact. Renames are
emitted before the keep line because filter-repo tests the keep filter against the
already-renamed name.

## Run It

```bash
# Local carve only — inspect the result, no remote touched:
scripts/carve-repo.sh fm-robot fm_robot

# Create the private remote and push:
PUSH=1 scripts/carve-repo.sh fm-robot fm_robot

# A group that drops sub-dirs carved into their own repos (fm-learning is a thin
# metapackage over the fm-data and fm-policy repos):
PUSH=1 scripts/carve-repo.sh fm-learning fm_learning \
                             fm_learning/fm_data fm_learning/fm_policy
```

Group → subdir → drops for the seven repos:

| Repo | Subdir | Drops |
|------|--------|-------|
| fm-robot | `fm_robot` | — |
| fm-sim | `fm_sim` | — |
| fm-teleop | `fm_teleop` | — |
| fm-data | `fm_learning/fm_data` | — |
| fm-policy | `fm_learning/fm_policy` | — |
| fm-learning | `fm_learning` | `fm_learning/fm_data`, `fm_learning/fm_policy` |
| fm-app | `fm_app` | — |

## Verify a Carve

```bash
cd <carved-repo>
git rev-list --count HEAD          # full history, not 1–2 commits
git log --oneline | tail -3        # pre-split commits present
```

The carved payload (everything except injected governance and the rewritten
`README.md`) is byte-identical to the monorepo subtree it came from.

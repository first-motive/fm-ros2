#!/usr/bin/env python3
"""Emit a git-filter-repo --paths-from-file spec that heals every rename hop for
one package group, so the carved repo keeps full history.

The fm-ros2 monorepo moved its packages several times (src/ flatten, the
fm_vlta -> fm_data/fm_policy split, the group folders). A plain
`git filter-repo --subdirectory-filter <group>` prunes any commit predating the
last move, because those commits touched the package under its *old* path.

This walks the exact (100%-similarity) rename pairs git recorded at each commit
and composes them backward in commit order, so every current file is linked to
its full lineage of historical paths — deterministically, with no heuristic
rename guessing (which falsely links unrelated files). It then emits a file-level
rename rule `old==>current` for every historical alias, plus a keep line for the
current group.

Run inside the clone being filtered:

    python3 carve-paths.py <group-subdir> > /tmp/paths
    git filter-repo --paths-from-file /tmp/paths      # normalize history onto current paths
    git filter-repo --subdirectory-filter <group-subdir>   # strip prefix, history intact
"""

import subprocess
import sys


def run(args):
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout


def renames_by_commit():
    """{commit: [(old, new), ...]} for exact (R100) renames, parsed in one pass."""
    out = run(
        [
            "log", "main",
            "--diff-filter=R", "--find-renames=100%",
            "--name-status", "--format=__commit__ %H",
        ]
    )
    by_commit, cur = {}, None
    for line in out.splitlines():
        if line.startswith("__commit__ "):
            cur = line.split(" ", 1)[1]
            by_commit[cur] = []
        elif line.startswith("R") and cur is not None:
            parts = line.split("\t")
            if len(parts) == 3:
                by_commit[cur].append((parts[1], parts[2]))
    return by_commit


def main():
    group = sys.argv[1].rstrip("/")
    current = [f for f in run(["ls-files", group]).splitlines() if f]

    by_commit = renames_by_commit()
    # rev-list is newest -> oldest. alias[path] = the current file it became.
    order = [c for c in run(["rev-list", "main"]).splitlines() if c]
    alias = {f: f for f in current}
    for commit in order:                       # newest -> oldest
        for old, new in by_commit.get(commit, []):
            if new in alias:                    # file at `new` after this commit
                alias[old] = alias[new]         # so before it, it lived at `old`

    # Order matters: filter-repo applies these in sequence and tests the keep
    # filter against the running (already-renamed) name. Emit the renames first
    # so each historical path is normalized onto its current path BEFORE the
    # group keep line decides what survives.
    seen = set()
    for path, cur in alias.items():
        if path != cur and path not in seen:
            seen.add(path)
            print(f"{path}==>{cur}")
    print(f"{group}/")                          # keep the current group wholesale


if __name__ == "__main__":
    main()

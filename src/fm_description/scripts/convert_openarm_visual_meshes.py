#!/usr/bin/env python3
# Copyright 2026 First Motive
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Convert OpenArm visual COLLADA meshes to STL.

Why this exists: OpenArm's upstream visual meshes are COLLADA (.dae) with
inconsistent declared ``up_axis`` values (the arm and pinch-gripper meshes are
``Y_UP``, the body mesh is ``Z_UP``). RViz honours each file's ``up_axis``, so it
renders the robot upright. Foxglove Studio ignores per-file ``up_axis`` and applies
one global "mesh up" setting, so the raw .dae meshes render mis-rotated and no
single Foxglove toggle fixes the mixed set.

The fix is to bake each file's ``up_axis`` into the geometry. assimp does exactly
that when it loads a COLLADA file: it applies the declared ``up_axis`` and exports
STL in that resolved frame — the same orientation RViz presents. So a plain assimp
export per visual mesh is the whole conversion; NO extra rotation is applied. The
URDF's own ``<visual>`` origins then place each mesh exactly as they do in RViz,
and Foxglove (mesh-up set to Z-up, matching the G1/SO101 views) renders the robot
upright. Baking an additional rotation here would double-rotate the meshes and
scatter the assembled robot.

Output mirrors the source tree under ``--out`` so launch path rewrites map
``package://openarm_description/<rel>.dae`` to
``package://fm_description/openarm_meshes/<rel>.stl`` by a plain substitution.
"""

import argparse
import pathlib
import subprocess
import sys


def _convert_one(dae, out_stl, assimp):
    out_stl.parent.mkdir(parents=True, exist_ok=True)
    # Skip if the output is already newer than the source (keeps rebuilds fast).
    if out_stl.exists() and out_stl.stat().st_mtime >= dae.stat().st_mtime:
        return False
    result = subprocess.run(
        [assimp, "export", str(dae), str(out_stl)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"assimp export failed for {dae}:\n{result.stderr or result.stdout}"
        )
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src", required=True, help="openarm_description source root")
    parser.add_argument("--out", required=True, help="output root for the STL meshes")
    parser.add_argument("--assimp", default="assimp", help="assimp CLI path")
    args = parser.parse_args()

    src, out = pathlib.Path(args.src), pathlib.Path(args.out)
    daes = sorted(src.rglob("*/visual/*.dae"))
    if not daes:
        print(f"convert_openarm_visual_meshes: no visual DAE under {src}", file=sys.stderr)
        return 1

    converted = 0
    for dae in daes:
        rel = dae.relative_to(src).with_suffix(".stl")
        if _convert_one(dae, out / rel, args.assimp):
            converted += 1
            print(f"  stl: {rel}")
    print(
        f"convert_openarm_visual_meshes: {converted} converted, "
        f"{len(daes) - converted} up to date ({len(daes)} total)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

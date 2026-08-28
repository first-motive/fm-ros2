#!/usr/bin/env python3
"""Resolve the registry robots to raw URDFs and mesh source files (step 1 of 2).

Runs inside the ROS environment (the pixi env with install/ sourced). It needs
fm_bringup.registry to build each description and ament_index to turn
package:// mesh URIs into files. Step 2, package.py, runs outside ROS and
never imports anything from the workspace.

Usage:
  python resolve.py --work DIR [--robots g1_d,so101]

Writes:
  <work>/<robot>/<variant>.urdf.src   raw URDF per registry variant
  <work>/resolved.json                robot table + mesh URI -> source file map
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import xml.etree.ElementTree as ET

# Robots and variants to package. The first variant of each robot is the
# website's default. Aliases map a website variant name onto a registry
# variant; the package ships both names with identical content.
ROBOTS = [
    {"key": "g1_d", "variants": ["g1_d", "g1_29dof_rev_1_0"]},
    {"key": "so101", "variants": ["so101"]},
    {
        "key": "openarm",
        "variants": [
            "default_bimanual",
            "right_arm_with_pinch_gripper",
            "left_arm_with_pinch_gripper",
            "right_arm",
            "left_arm",
        ],
    },
    {"key": "axol", "variants": ["axol"], "aliases": {"bimanual": "axol"}},
]

# The mock backend yields the plain description: no simulator plugins, no
# hardware paths, every mesh still a package:// URI.
SIM_BACKEND = "mock"


def utc_now() -> str:
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    return now.isoformat().replace("+00:00", "Z")


def mesh_uris(urdf_xml: str) -> list[str]:
    """Every distinct <mesh filename> in document order."""
    root = ET.fromstring(urdf_xml)
    seen: dict[str, None] = {}
    for mesh in root.iter("mesh"):
        uri = mesh.get("filename")
        if uri:
            seen.setdefault(uri, None)
    return list(seen)


def resolve_uri(uri: str, share_dir) -> dict:
    if not uri.startswith("package://"):
        raise SystemExit(f"unsupported mesh URI (expected package://): {uri}")
    pkg, _, rel = uri[len("package://") :].partition("/")
    path = os.path.join(share_dir(pkg), rel)
    if not os.path.isfile(path):
        raise SystemExit(f"mesh not found: {uri} -> {path}")
    return {"path": path, "pkg": pkg, "rel": rel, "bytes": os.path.getsize(path)}


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--work", required=True, help="work directory for the raw URDFs and resolved.json")
    p.add_argument("--robots", default="", help="comma-separated robot keys (default: all)")
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    # Imported here so the ROBOTS table is readable without a ROS environment.
    from ament_index_python.packages import get_package_share_directory
    from fm_bringup import registry

    wanted = [k for k in args.robots.split(",") if k]
    known = {r["key"] for r in ROBOTS}
    unknown = sorted(set(wanted) - known)
    if unknown:
        raise SystemExit(f"unknown robots: {', '.join(unknown)} (known: {', '.join(sorted(known))})")
    table = [r for r in ROBOTS if not wanted or r["key"] in wanted]

    robots: dict[str, dict] = {}
    meshes: dict[str, dict] = {}
    for entry in table:
        key = entry["key"]
        spec = registry.get(key)
        robot_dir = os.path.join(args.work, key)
        os.makedirs(robot_dir, exist_ok=True)
        urdfs: dict[str, str] = {}
        for variant in entry["variants"]:
            xml = spec.build_description(variant, SIM_BACKEND)
            rel = os.path.join(key, f"{variant}.urdf.src")
            with open(os.path.join(args.work, rel), "w", encoding="utf-8") as fh:
                fh.write(xml)
            urdfs[variant] = rel
            uris = mesh_uris(xml)
            for uri in uris:
                if uri not in meshes:
                    meshes[uri] = resolve_uri(uri, get_package_share_directory)
            print(f"{key:8s} {variant:30s} {len(uris):3d} meshes")
        robots[key] = {
            "label": spec.label,
            "default_variant": entry["variants"][0],
            "variants": list(entry["variants"]),
            "aliases": dict(entry.get("aliases", {})),
            "urdfs": urdfs,
        }

    out = {
        "generated_at": utc_now(),
        "sim_backend": SIM_BACKEND,
        "robots": robots,
        "meshes": meshes,
    }
    with open(os.path.join(args.work, "resolved.json"), "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2, sort_keys=False)
        fh.write("\n")
    total_mb = sum(m["bytes"] for m in meshes.values()) / 1e6
    print(f"resolved {len(robots)} robots, {len(meshes)} distinct meshes, {total_mb:.1f} MB source -> {args.work}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Package resolved robots into browser-ready model packages (step 2 of 2).

Runs outside ROS:
  uv run --no-project --with trimesh --with numpy python package.py --work DIR --out DIR

Reads <work>/resolved.json and the raw URDFs resolve.py wrote, converts every
visual mesh once (trimesh -> GLB, then gltf-transform optimize), rewrites the
URDFs to reference meshes/<name>.glb, strips collision and controller blocks,
and writes <out>/models/<robot>/... plus manifest.json and index.json.

Conversions are cached under <work>/glb/<robot>/ and skipped while the cached
GLB is newer than its source; --force redoes them, --no-optimize ships the
plain trimesh export (larger, handy when a mesh looks wrong after simplify).
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor

MOVABLE_JOINTS = ("revolute", "prismatic", "continuous")

# Elements the web viewer never reads. Collision geometry would double the mesh
# count; the controller blocks describe hardware, not shape.
STRIP_TAGS = ("collision", "ros2_control", "transmission", "gazebo")

# The only glTF extension a shipped mesh may require. three.js decodes it
# natively; anything else (draco, meshopt) needs a wasm decoder on the page.
ALLOWED_EXTENSIONS = {"KHR_mesh_quantization"}

OPTIMIZE_ARGS = [
    "--compress", "quantize",
    "--simplify", "true",
    "--simplify-ratio", "0.5",
    "--simplify-error", "0.001",
]

INDEX_SOURCE = "fm_ros2 registry + fm_description meshes"

_ABSOLUTE_ATTR = re.compile(r'="/')
_SAFE_NAME = re.compile(r"[^a-z0-9._-]+")


def utc_now() -> str:
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    return now.isoformat().replace("+00:00", "Z")


def short_hash(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8")).hexdigest()[:8]


def drop_none(record: dict) -> dict:
    return {k: v for k, v in record.items() if v is not None}


# --- mesh naming -------------------------------------------------------------


def mesh_names(uris) -> dict[str, str]:
    """Map each mesh URI to its GLB file name inside one robot's meshes/ dir.

    The name is the source basename, lower-cased, with a .glb extension. Two
    different sources sharing a basename each get a short hash suffix so
    neither shadows the other.
    """
    by_stem: dict[str, list[str]] = {}
    for uri in dict.fromkeys(uris):
        stem = os.path.splitext(os.path.basename(uri))[0].lower()
        stem = _SAFE_NAME.sub("_", stem) or "mesh"
        by_stem.setdefault(stem, []).append(uri)
    names: dict[str, str] = {}
    for stem, members in by_stem.items():
        if len(members) == 1:
            names[members[0]] = f"{stem}.glb"
        else:
            for uri in members:
                names[uri] = f"{stem}-{short_hash(uri)}.glb"
    return names


# --- URDF rewrite -------------------------------------------------------------


def _float(value):
    return None if value is None else float(value)


def joint_record(joint: ET.Element) -> dict:
    record = {"name": joint.get("name"), "type": joint.get("type")}
    limit = joint.find("limit")
    if limit is not None:
        record["lower"] = _float(limit.get("lower"))
        record["upper"] = _float(limit.get("upper"))
    mimic = joint.find("mimic")
    if mimic is not None:
        record["mimic"] = drop_none(
            {
                "joint": mimic.get("joint"),
                "multiplier": _float(mimic.get("multiplier")),
                "offset": _float(mimic.get("offset")),
            }
        )
    return drop_none(record)


def visual_mesh_uris(urdf_xml: str) -> list[str]:
    """Distinct mesh URIs referenced by <visual> elements, in document order."""
    root = ET.fromstring(urdf_xml)
    seen: dict[str, None] = {}
    for visual in root.iter("visual"):
        for mesh in visual.iter("mesh"):
            uri = mesh.get("filename")
            if uri:
                seen.setdefault(uri, None)
    return list(seen)


def rewrite_urdf(urdf_xml: str, names: dict[str, str]) -> tuple[str, dict]:
    """Return the web URDF text and what it contains.

    Parsing with ElementTree drops comments, which is where xacro writes the
    absolute path of the source file. Stripping runs before the rewrite so
    collision-only meshes never need a name.
    """
    root = ET.fromstring(urdf_xml)
    for parent in list(root.iter()):
        for child in list(parent):
            if child.tag in STRIP_TAGS:
                parent.remove(child)
    used: dict[str, None] = {}
    for mesh in root.iter("mesh"):
        uri = mesh.get("filename")
        if uri is None:
            continue
        if uri not in names:
            raise ValueError(f"mesh URI has no GLB name: {uri}")
        mesh.set("filename", f"meshes/{names[uri]}")
        used.setdefault(names[uri], None)
    joints = [joint_record(j) for j in root.iter("joint") if j.get("type") in MOVABLE_JOINTS]
    links = len(root.findall("link"))
    if hasattr(ET, "indent"):
        ET.indent(root, space="  ")
    text = '<?xml version="1.0"?>\n' + ET.tostring(root, encoding="unicode") + "\n"
    if "package://" in text or "file://" in text or _ABSOLUTE_ATTR.search(text):
        raise ValueError("web URDF still carries a package://, file://, or absolute path")
    return text, {"joints": joints, "links": links, "meshes": sorted(used)}


# --- mesh conversion ------------------------------------------------------------


def gltf_transform_command() -> list[str]:
    exe = shutil.which("gltf-transform")
    return [exe] if exe else ["npx", "-y", "@gltf-transform/cli"]


def glb_info(path: str) -> dict:
    """Triangle count and required extensions, read from the GLB header."""
    with open(path, "rb") as fh:
        magic, _version, _length = struct.unpack("<4sII", fh.read(12))
        if magic != b"glTF":
            raise ValueError(f"not a GLB: {path}")
        chunk_len, chunk_type = struct.unpack("<II", fh.read(8))
        if chunk_type != 0x4E4F534A:  # 'JSON'
            raise ValueError(f"GLB without a leading JSON chunk: {path}")
        doc = json.loads(fh.read(chunk_len))
    accessors = doc.get("accessors", [])
    triangles = 0
    for mesh in doc.get("meshes", []):
        for prim in mesh.get("primitives", []):
            if prim.get("mode", 4) != 4:
                continue
            index = prim.get("indices", prim.get("attributes", {}).get("POSITION"))
            if index is not None:
                triangles += accessors[index]["count"] // 3
    return {"triangles": triangles, "extensions_required": doc.get("extensionsRequired", [])}


def is_stale(target: str, source: str) -> bool:
    return not os.path.exists(target) or os.path.getmtime(target) < os.path.getmtime(source)


def convert_mesh(src: str, raw_glb: str, out_glb: str, optimize: bool, force: bool, command=None) -> str:
    """Convert one source mesh, returning the GLB to ship (raw or optimized)."""
    os.makedirs(os.path.dirname(raw_glb), exist_ok=True)
    if force or is_stale(raw_glb, src):
        import trimesh

        mesh = trimesh.load(src, force="mesh")
        mesh.merge_vertices()
        mesh.export(raw_glb)
    if not optimize:
        return raw_glb
    if force or is_stale(out_glb, raw_glb):
        cmd = list(command or gltf_transform_command()) + ["optimize", raw_glb, out_glb] + OPTIMIZE_ARGS
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(f"gltf-transform failed on {src}:\n{proc.stdout}\n{proc.stderr}")
    required = set(glb_info(out_glb)["extensions_required"])
    if not required <= ALLOWED_EXTENSIONS:
        raise RuntimeError(f"{out_glb} requires a decoder extension: {sorted(required - ALLOWED_EXTENSIONS)}")
    return out_glb


# --- manifest and index -------------------------------------------------------------


def assert_clean_json(value, path="$") -> None:
    """Reject nulls and anything that looks like a filesystem path or host."""
    if value is None:
        raise ValueError(f"null at {path}")
    if isinstance(value, dict):
        for key, item in value.items():
            assert_clean_json(item, f"{path}.{key}")
    elif isinstance(value, list):
        for i, item in enumerate(value):
            assert_clean_json(item, f"{path}[{i}]")
    elif isinstance(value, str):
        if value.startswith("/") or "://" in value or value.startswith("~") or re.match(r"^[A-Za-z]:\\", value):
            raise ValueError(f"path-like string at {path}: {value!r}")


def package_files(manifest: dict) -> list[str]:
    """The closed list of files under models/<robot>/, relative names."""
    files = ["manifest.json"]
    files += [v["urdf"] for v in manifest["variants"].values()]
    files += [f"meshes/{name}" for name in manifest["meshes"]]
    return files


def build_index(models_dir: str, generated_at: str) -> dict:
    """Index every robot package present under models_dir, sorted by key."""
    models = []
    for key in sorted(os.listdir(models_dir)) if os.path.isdir(models_dir) else []:
        manifest_path = os.path.join(models_dir, key, "manifest.json")
        if not os.path.isfile(manifest_path):
            continue
        with open(manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
        models.append(
            {
                "key": manifest["key"],
                "label": manifest["label"],
                "variants": list(manifest["variants"]),
                "default_variant": manifest["default_variant"],
                "files": package_files(manifest),
            }
        )
    return {"generated_at": generated_at, "source": INDEX_SOURCE, "models": models}


def write_json(path: str, value) -> None:
    assert_clean_json(value)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(value, fh, indent=2)
        fh.write("\n")


# --- driver -----------------------------------------------------------------------


def package_robot(key: str, robot: dict, resolved_meshes: dict, work: str, out: str, optimize: bool, force: bool, jobs: int, command=None) -> dict:
    """Write models/<key>/ and return the size row for the summary table."""
    generated_at = utc_now()
    sources = {}
    for variant, rel in robot["urdfs"].items():
        with open(os.path.join(work, rel), encoding="utf-8") as fh:
            sources[variant] = fh.read()

    uris: dict[str, None] = {}
    for xml in sources.values():
        for uri in visual_mesh_uris(xml):
            uris.setdefault(uri, None)
    missing = [u for u in uris if u not in resolved_meshes]
    if missing:
        raise SystemExit(f"{key}: resolved.json lacks {len(missing)} mesh URIs, rerun resolve.py: {missing[0]}")
    names = mesh_names(uris)

    robot_dir = os.path.join(out, "models", key)
    meshes_dir = os.path.join(robot_dir, "meshes")
    cache_dir = os.path.join(work, "glb", key)
    os.makedirs(meshes_dir, exist_ok=True)

    def convert(uri: str) -> tuple[str, str]:
        name = names[uri]
        stem = name[: -len(".glb")]
        src = resolved_meshes[uri]["path"]
        shipped = convert_mesh(
            src,
            os.path.join(cache_dir, f"{stem}.raw.glb"),
            os.path.join(cache_dir, f"{stem}.glb"),
            optimize,
            force,
            command,
        )
        dest = os.path.join(meshes_dir, name)
        if force or is_stale(dest, shipped) or os.path.getsize(dest) != os.path.getsize(shipped):
            shutil.copy2(shipped, dest)
        return uri, dest

    with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        shipped_paths = dict(pool.map(convert, list(uris)))

    manifest_meshes = {}
    for uri in uris:
        info = resolved_meshes[uri]
        dest = shipped_paths[uri]
        manifest_meshes[names[uri]] = {
            "bytes": os.path.getsize(dest),
            "source": f"{info['pkg']}/{info['rel']}",
            "triangles": glb_info(dest)["triangles"],
        }
    manifest_meshes = dict(sorted(manifest_meshes.items()))

    variants = {}
    urdf_bytes = 0
    for variant, xml in sources.items():
        text, info = rewrite_urdf(xml, names)
        urdf_name = f"{variant}.urdf"
        with open(os.path.join(robot_dir, urdf_name), "w", encoding="utf-8") as fh:
            fh.write(text)
        urdf_bytes += len(text.encode("utf-8"))
        variants[variant] = {"urdf": urdf_name, **info}
    for alias, target in robot.get("aliases", {}).items():
        if target not in variants:
            raise SystemExit(f"{key}: alias {alias} points at unknown variant {target}")
        alias_name = f"{alias}.urdf"
        shutil.copyfile(os.path.join(robot_dir, variants[target]["urdf"]), os.path.join(robot_dir, alias_name))
        urdf_bytes += os.path.getsize(os.path.join(robot_dir, alias_name))
        variants[alias] = {**variants[target], "urdf": alias_name, "alias_of": target}

    mesh_bytes = sum(m["bytes"] for m in manifest_meshes.values())
    manifest = {
        "key": key,
        "label": robot["label"],
        "default_variant": robot["default_variant"],
        "variants": variants,
        "meshes": manifest_meshes,
        "total_bytes": urdf_bytes + mesh_bytes,
        "generated_at": generated_at,
    }
    write_json(os.path.join(robot_dir, "manifest.json"), manifest)

    # Keep the tree equal to the closed list: a renamed or dropped mesh must not
    # linger on disk, or a plain sync would upload something nothing serves.
    keep = set(package_files(manifest))
    for base, _dirs, files in os.walk(robot_dir):
        for name in files:
            rel = os.path.relpath(os.path.join(base, name), robot_dir)
            if rel not in keep:
                os.remove(os.path.join(base, name))
                print(f"{key}: removed stale {rel}")

    return {
        "robot": key,
        "variants": len(variants),
        "meshes": len(manifest_meshes),
        "src_mb": sum(resolved_meshes[u]["bytes"] for u in uris) / 1e6,
        "glb_mb": mesh_bytes / 1e6,
        "urdf_kb": urdf_bytes / 1e3,
    }


def print_table(rows: list[dict]) -> None:
    header = f"{'robot':10s} {'variants':>8s} {'meshes':>6s} {'src MB':>8s} {'glb MB':>8s} {'urdf KB':>8s}"
    print(header)
    print("-" * len(header))
    for r in rows:
        print(f"{r['robot']:10s} {r['variants']:8d} {r['meshes']:6d} {r['src_mb']:8.1f} {r['glb_mb']:8.2f} {r['urdf_kb']:8.0f}")
    if len(rows) > 1:
        print("-" * len(header))
        print(
            f"{'total':10s} {sum(r['variants'] for r in rows):8d} {sum(r['meshes'] for r in rows):6d} "
            f"{sum(r['src_mb'] for r in rows):8.1f} {sum(r['glb_mb'] for r in rows):8.2f} {sum(r['urdf_kb'] for r in rows):8.0f}"
        )


def package_all(work: str, out: str, robots=(), optimize=True, force=False, jobs=4, command=None) -> list[dict]:
    with open(os.path.join(work, "resolved.json"), encoding="utf-8") as fh:
        resolved = json.load(fh)
    wanted = [k for k in robots if k]
    unknown = sorted(set(wanted) - set(resolved["robots"]))
    if unknown:
        raise SystemExit(f"not in resolved.json: {', '.join(unknown)}")
    rows = []
    for key, robot in resolved["robots"].items():
        if wanted and key not in wanted:
            continue
        rows.append(package_robot(key, robot, resolved["meshes"], work, out, optimize, force, jobs, command))
    models_dir = os.path.join(out, "models")
    os.makedirs(models_dir, exist_ok=True)
    write_json(os.path.join(models_dir, "index.json"), build_index(models_dir, utc_now()))
    return rows


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--work", required=True, help="work directory written by resolve.py")
    p.add_argument("--out", required=True, help="output root; packages land in <out>/models/")
    p.add_argument("--robots", default="", help="comma-separated robot keys (default: all in resolved.json)")
    p.add_argument("--no-optimize", action="store_true", help="ship the plain trimesh GLB, skip gltf-transform")
    p.add_argument("--force", action="store_true", help="redo every conversion, ignore the cache")
    p.add_argument("--jobs", type=int, default=4, help="parallel mesh conversions (default 4)")
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    rows = package_all(
        args.work,
        args.out,
        robots=args.robots.split(","),
        optimize=not args.no_optimize,
        force=args.force,
        jobs=args.jobs,
    )
    print()
    print_table(rows)
    print(f"\nwrote {os.path.join(args.out, 'models')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

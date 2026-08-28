# Robot Web Models

Packages the four registry robots as browser-ready 3D model packages for the
First Motive website viewer: one URDF per variant plus the visual meshes as
GLB, with a manifest per robot and an index over all of them. Nothing here
runs on a rig; it is a maintainer tool that turns the workspace's descriptions
into static files a web page can load.

```
fm_bringup registry ──▶ resolve.py ──▶ <work>/            ──▶ package.py ──▶ <out>/models/
(xacro + package://)    pixi ROS env    *.urdf.src            uv env           index.json
                                        resolved.json         trimesh          <robot>/manifest.json
                                                              gltf-transform   <robot>/<variant>.urdf
                                                                               <robot>/meshes/*.glb
```

## Run

```bash
./scripts/tools/robot-web-models/run.sh                 # all four robots
./scripts/tools/robot-web-models/run.sh --robots so101  # one robot
./scripts/tools/robot-web-models/run.sh --force         # ignore the GLB cache
./scripts/tools/robot-web-models/run.sh --no-optimize   # plain trimesh GLB, for debugging a mesh
```

Defaults: `--work <first-motive>/.showcase-work/robot-models-work` and
`--out <first-motive>/.showcase-work/out`, where `<first-motive>` is the
folder holding this workspace, so the tree lands beside the episode packages
as `out/models/`. Needs the workspace built (`pixi run build`) plus `uv` and
`npx` on PATH.

Tests: `uv run --no-project --with pytest --with trimesh --with numpy python -m pytest scripts/tools/robot-web-models -q`

## Two Steps, Two Environments

The registry and `ament_index` live in the ROS environment, and that
environment cannot host the mesh toolchain cleanly. The tool is therefore
split at the file system:

| Step | Runs in | Does |
| ---- | ------- | ---- |
| `resolve.py` | pixi env, `install/` sourced | `build_description(variant, "mock")` per variant, resolves every `package://` mesh URI to a file, writes the raw URDFs and `resolved.json` |
| `package.py` | `uv run --with trimesh --with numpy`, no ROS | converts meshes, rewrites URDFs, writes manifests and the index |

The robot and variant table lives at the top of `resolve.py`. The first
variant of a robot is the website's default; `aliases` lets the website call a
variant by another name (`axol/bimanual` ships as a copy of `axol/axol`,
marked `alias_of` in the manifest). A robot whose registry spec has no
`preset_arg` builds the same description for every variant name, so it gets
one variant and aliases for the rest (`g1_d/g1_29dof_rev_1_0`); `resolve.py`
refuses a second standalone variant on such a robot.

## What Package.py Emits

```
models/index.json
models/<robot>/manifest.json
models/<robot>/<variant>.urdf          mesh URIs rewritten to meshes/<name>.glb
models/<robot>/meshes/<name>.glb
```

Everything is relative to its own directory, so the tree serves from any
prefix. Per variant the URDF keeps links, joints, visuals, and materials;
`<collision>`, `<ros2_control>`, `<transmission>`, and `<gazebo>` blocks are
dropped, and only meshes a `<visual>` references are converted. The xacro
header comment, which names the source file by absolute path, does not
survive the parse.

Mesh names are the source basename lower-cased with `.glb`, reduced to what
the website worker serves: `[A-Za-z0-9][A-Za-z0-9._-]*` with no `..`
(`WORKER_FILE_RE` in `package.py`). Unsafe characters become `_`, dot runs
collapse, leading `._-` go, long stems are capped, and a stem with nothing
left becomes `mesh-<hash>`. Two different sources with the same stem inside
one robot each get a short hash suffix (`link-1a2b3c4d.glb`). A source shared
by several variants converts once. `package.py` checks every name on the
`files` list against the pattern and fails rather than emit one the worker
would drop.

`manifest.json` per robot:

```json
{
  "key": "openarm", "label": "Enactic OpenArm", "default_variant": "default_bimanual",
  "variants": {
    "default_bimanual": {"urdf": "default_bimanual.urdf", "links": 22,
                         "joints": [{"name": "…", "type": "revolute", "lower": -1.0, "upper": 1.0}],
                         "meshes": ["…glb"]},
    "…": {"urdf": "…", "alias_of": "…"}
  },
  "meshes": {"link0.glb": {"bytes": 12345, "source": "fm_description/…/link0.stl", "triangles": 1070}},
  "total_bytes": 1234567, "generated_at": "2026-08-28T12:00:00Z"
}
```

`joints` lists movable joints only (revolute, prismatic, continuous) with the
URDF limits and any `mimic`. `source` is provenance, `<pkg>/<rel>` under the
package share; no output file carries an absolute path or a host name, and no
JSON value is null (`package.py` refuses to write otherwise).

`index.json` lists every robot package present under `models/`:

```json
{"generated_at": "…", "source": "fm_ros2 registry + fm_description meshes",
 "models": [{"key": "g1_d", "label": "Unitree", "variants": ["g1_d", "g1_29dof_rev_1_0"],
             "default_variant": "g1_d", "files": ["manifest.json", "g1_d.urdf", "…", "meshes/….glb"]}]}
```

`files` is the closed list of every file under `models/<robot>/`; the website
worker serves only names on that list. `package.py` removes anything else it
finds in the package directory, so the tree and the list stay equal.

## How the Website Consumes It

The tree mirrors `showcase/models/` in the B2 bucket, next to the episode
packages. Upload the whole directory; nothing needs excluding:

```bash
aws s3 sync "$OUT/models" s3://<bucket>/showcase/models --endpoint-url <b2-endpoint>
```

The viewer fetches `models/index.json`, picks a robot and variant, loads
`models/<robot>/<variant>.urdf`, and resolves each `meshes/<name>.glb`
relative to the URDF. Add `--delete` to the sync when a robot or variant was
removed on purpose.

## Mesh Pipeline and the No-Decoder Rule

Per mesh: `trimesh.load(force="mesh")`, `merge_vertices()`, export to GLB, then

```
gltf-transform optimize in.glb out.glb --compress quantize --simplify true \
    --simplify-ratio 0.5 --simplify-error 0.001
```

The only glTF extension a shipped mesh may require is `KHR_mesh_quantization`,
which three.js decodes natively. Draco and meshopt shrink files further but
need a wasm decoder on the page; `package.py` reads each GLB header after
optimizing and fails on any other required extension. Keep it that way.

Conversions cache under `<work>/glb/<robot>/` (`<name>.raw.glb` from trimesh,
`<name>.glb` optimized). Each entry has a `.stamp.json` beside it recording
the source path, size, mtime, and the optimize arguments; the entry is rebuilt
when the stamp differs, so a rerun after a description change converts only
what moved, while a URI retargeted to another file or a change to the
optimize flags rebuilds what it must. `--force` rebuilds everything.

One caveat when inspecting output with trimesh: it ignores the `normalized`
flag on quantized accessors, so bounds of an optimized GLB read as the raw
integer range. Face counts are right; the browser applies the node transform
and renders at true scale. Check bounds on the `.raw.glb` instead.

## Size Expectations

Measured on the 2026-08-28 run, visual meshes only:

| Robot | Variants | Meshes | Source STL | Shipped GLB |
| ----- | -------- | ------ | ---------- | ----------- |
| g1_d | 2 (one alias) | 41 | 29.9 MB | 3.05 MB |
| so101 | 1 | 13 | 16.1 MB | 1.63 MB |
| openarm | 5 | 11 | 13.4 MB | 1.49 MB |
| axol | 2 (one alias) | 18 | 0.1 MB | 0.03 MB |

Quantization plus a 0.5 simplify ratio lands the STL meshes at about a tenth
of their source size; the whole tree is 6.2 MB and the g1_d package, at 3 MB,
is the largest single download. The openarm count is low because its left and
right arms share mesh files, which convert once. The full run takes under a
minute on a laptop; a cached rerun takes seconds.

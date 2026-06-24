# External Dependencies

Robot descriptions and learning assets are vendored from upstream repos rather
than committed here. The setup scripts call the import step; run it standalone to
refresh.

```bash
./scripts/import-externals.sh        # vendor sources: vcs import external < external.repos
./scripts/setup-lerobot.sh           # then: editable lerobot env from the vendored source
```

Pins in `external.repos` are placeholders (LeRobot, OpenArm, Unitree) — replace
with real tags and fork before patching upstream. Vendored sources live under
`external/` and are gitignored. If `vcs` is not on the host, run it inside the
container.

## LeRobot Env

`setup-lerobot.sh` creates `~/.venvs/lerobot` and installs lerobot editable from
the vendored `external/lerobot`, so it runs **after** `import-externals.sh`.
The env is host-native — same story as the MuJoCo env on the M5 (CPU sim and
dataset work, no container). It uses Python 3.12 and installs the `dataset` and
`feetech` extras because the local replay/export flows import Hugging Face
dataset APIs directly and the SO101 hardware path needs Feetech support. The
script is idempotent: it skips when the venv already exists. Pass `--force` to
wipe and reinstall, which also migrates an older PyPI lerobot venv to this
editable source install.

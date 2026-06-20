# Diagrams

Orchestrator-level architecture diagrams, authored in [d2](https://d2lang.com).
This repo holds only the two top-of-stack views — `run` (front door) and `system`
(entry points into the launcher). Per-package diagrams live in each package repo's
`docs/diagrams/` (see [Diagram Ownership](#diagram-ownership)).

Each `.d2` file is the source of truth; the matching `.svg` is a generated
artifact referenced by the docs. Edit the `.d2`, then re-render.

## Render

```bash
./render.sh          # renders every *.d2 to *.svg with the brand font
```

Needs `d2` on `PATH`. The font ships in [`fonts/`](fonts/), so rendering is
self-contained — no font install, no personal tooling. The script passes the
font explicitly:

```bash
d2 --layout elk --font-regular fonts/GeistMono-VF.ttf \
   --font-bold fonts/GeistMono-VF.ttf --font-italic fonts/GeistMono-VF.ttf in.d2 out.svg
```

## Font

**Geist Mono** — First Motive's brand monospace ([Vercel](https://github.com/vercel/geist-font),
OFL). Ships as `fonts/GeistMono-VF.ttf`. Mono suits the technical tokens the
diagrams carry (`fm_*`, `*.launch.py`, `ros2_control`).

## Palette

Mirrors firstmotive.ai. Defined once in [`styles.d2`](styles.d2), imported with
`...@styles`.

| Token | Hex | Use |
|-------|-----|-----|
| plum | `#3B3443` | role band, borders, edges |
| lavender | `#B6A5C6` | package band |
| cream | `#E7DDC8` | artifact / node band |
| light text | `#ECE2CF` | text on plum |
| deep | `#342E3B` | text on lavender / cream |

## Block Grammar

Every component is a stacked block built as a `grid-rows` container:

```
┌─────────────────┐  role  — human label (plum)
├─────────────────┤  pkg   — package name (lavender), one colour for all packages
├─────────────────┤  art   — artifact / node (cream)
└─────────────────┘
```

- Blocks without a package (run steps) drop the `pkg` band.
- A block expanded in a deeper diagram uses `class: zoom` (dashed border).
- Layout is ELK (straight orthogonal edges); `direction: right` for fan-in.

## Zoom Hierarchy

Diagrams nest from orientation to detail; a dashed block expands in the next.
The two orchestrator views live here; deeper blocks expand in the package repos.

```
run        run.sh → host → overlay/bare-metal → build → ROS2 System ⇢ system
system     entry · robots → fm_tui Launcher ⇢ launcher → fm_bringup ⇢ bringup
           ↳ launcher · bringup expand in fm-app/docs/diagrams/
           ↳ controllers · hardware · view_robot in fm-robot/docs/diagrams/
```

## Diagram Ownership

`fm-ros2` is the orchestrator; each package repo owns the diagrams for what it
does. The detail that used to sit here moved down with its package.

| Diagram | Owner repo | Shows |
|---------|------------|-------|
| `run`, `system` | **fm-ros2** | front door + entry into the launcher |
| `launcher`, `bringup`, `viz` | [fm-app](https://github.com/first-motive/fm-app) | launcher menu, bringup composition, visualization |
| `controllers`, `view_robot`, `hardware` | [fm-robot](https://github.com/first-motive/fm-robot) | ros2_control graph, robot state, hardware abstraction |

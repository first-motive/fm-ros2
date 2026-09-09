# Releasing

Appliances ride release tags, never `main`. This page is the whole flow: what a
release is, how to cut one, and how often.

## Why Tags

A recorder or a processor provisioned with `--service` gets two halves of one
mechanism. At install, `setup-<role>.sh` pins each repo to its newest `v*` tag
(`pin_release` in `lib.sh`). From then on, `fm-update-<role>.timer` runs
[`scripts/service/appliance-update.sh`](../scripts/service/appliance-update.sh)
about every 15 minutes, and it moves a repo only when a **newer** `v*` tag
exists. Merging to `main` therefore changes nothing on a rig: a tag is the only
signal the fleet listens to. Both paths require the tag to descend from the
current checkout; an ahead or divergent checkout is held for review.

The stable channel selects only complete `vMAJOR.MINOR.PATCH` tags. It ignores
suffixes such as `-rc1` or `-zenoh.2`, even when Git sorts them above a stable
release. Deploy those tags only through a separately reviewed exact-pin change.
This rule also applies to the release script's version-bump baseline.

The updater resolves `fm-setup` from the `workspace` field in
`/etc/fm/machine.json` (`FM_MACHINE_FILE` for a test card). A separate processor
workspace does not need a guessed sibling link. A missing card keeps the legacy
sibling lookup; an invalid card holds the machine layer. The selected checkout
still has to pass the same clean-source, fetch, and ancestry checks.

That makes an untagged repo invisible to the channel rather than merely behind.
The updater reports it `untagged` and leaves it on whatever commit the clone
landed on, forever. So a release is the whole set of repos the workspace
assembles, not the orchestrator alone — tagging `fm-ros2` while a role's package
repo stays untagged ships nothing to that role.

## Cutting One

From a workspace checkout with every repo imported:

```bash
./scripts/dev/cut-release.sh                  # print the plan, change nothing
./scripts/dev/cut-release.sh --apply          # cut and push the patch bump
./scripts/dev/cut-release.sh --minor --apply  # cut and push the minor bump
```

The script selects the workspace root and the repos in `fm-ros2.repos` and
`private-overlay.repos`. It excludes `external/` and old checkouts that are no
longer in those manifests. Each selected path must have a checkout.

Before it creates the first tag, the script checks access and completed CI
checks for every proposed release. An archived repo, a fetch failure, or a
failed check stops the run. If a repo has `scripts/check-release.sh`, the script
runs that package-owned check from the proposed commit with the new tag as its
first argument. The hook must refuse invalid release metadata.

Each repo bumps from its own newest published tag, so repos on different
versions stay on different versions. This is a release train, not a shared version number — the
set moves together, the numbers do not have to match. A repo with no tag yet is
seeded at `v0.1.0`; `--only-untagged` restricts a run to exactly those, which is
the pass to use when a new repo joins the workspace.

Tags are cut on the remote's default-branch tip, not on local `HEAD`, so a
maintainer's half-finished branch or an appliance-test detached checkout cannot
leak into a release. A repo whose newest tag already points at that tip is
reported and skipped: re-cutting a tag would move a ref the fleet may already be
sitting on.

GitHub cannot publish tags across repos in one transaction. If a push fails,
run the command again. A matching local tag that was not published is reused;
an existing tag is never moved.

Two things the script deliberately leaves to you:

- **The pinned repos.** `docker/` and `comms/` are pinned by tag in
  `fm-ros2.repos`, not tracked to `main`. Cutting a new tag for either does
  nothing until that `version:` is bumped in the manifest and merged — one more
  commit, on purpose, because the transport and the base image must not move
  under a running fleet without someone deciding they should.
- **The rollout.** Nothing is pushed to any rig. Each timer fetches on its own
  schedule and converges within a tick.

## Cadence

Cut a release when merged work should reach the fleet, and at least once a
sprint so no rig drifts more than a sprint behind `main`. Two rules around that:

- **Never cut into a capture session.** The updater's busy gate holds a rig that
  is mid-take, so nothing is interrupted — but a rig that stays busy stays behind,
  and the convergence you wanted has not happened yet.
- **Cut the whole set.** Partial release trains are how a repo quietly falls off
  the channel. Run the script without `--only-untagged` unless you are seeding a
  newly added repo.

## Verifying

After a release, on a provisioned rig:

```bash
./scripts/service/appliance-update.sh --check recorder
./scripts/service/appliance-update.sh recorder
```

Run `--check` first. It fetches and reports the release state without checking
out source, building, or changing a service. A checkout ahead of the latest tag
is held until a new release is cut; the updater never rolls it back. Then run
the updater once by hand rather than waiting for the timer. It converges the
repos that moved, re-runs the role installer, and restarts the services. A
second `--check` reports each repo as `current`. A failed install remains
pending even when Git is current. In that case `--check` exits with failure,
and the next update retries the installer after the normal safety checks.
Verify the installed package version and service health as well as Git state.

# Contributing to zenit

Thanks for taking a look. zenit is a Zig GUI framework for native macOS
applications; it is pre-1.0 and the public API is still moving.

## Before you start

- **Platform**: macOS only today (Apple Silicon is what gets regular testing).
  The Linux/Windows backends in `src/system_sdk/` are stubs: they compile, but
  they do not run an app. A cross-platform compile check runs in CI so they
  cannot silently rot.
- **Zig**: `0.15.2` exactly, as declared in `build.zig.zon`. CI installs the
  same version. If `zig version` disagrees, fix that first, since most confusing
  build errors come from version drift.
- **Xcode Command Line Tools**: `xcode-select --install`, for the macOS frameworks.

```bash
git clone <your-fork>
cd zenit
zig build test        # deterministic suite, ~25s
zig build hello-button && open "zig-out/Hello Button.app"
```

`zig build` with no arguments intentionally does nothing; there is no default
install step. Use a named step (`zig build -l` lists them all).

## The one thing to read first

[`docs/UI_OSS_BOUNDARY.md`](docs/UI_OSS_BOUNDARY.md) defines what does and does
not belong in this repo. zenit is a GUI framework, not an editor, not a
language toolkit. That line is enforced at build time: `zig build hello-button`
only allows framework modules to be reachable, so a boundary violation fails the
build rather than being caught in review.

If you want a task with real leverage, the open render bugs in
the [issue tracker](https://github.com/version-next/zenit/issues) are the best entry point; they cluster, so
fixing one often fixes several.

## Before you open a PR

Start with these high-signal gates; they cover formatting, deterministic tests,
the public package, and the architectural boundaries most likely to affect a PR:

```bash
bash scripts/check_zig_format.sh      # formatting ratchet
zig build test                        # deterministic suite
zig build test-package-consumer       # build + launch as an external dependency
bash scripts/check_oss_boundary.sh    # module boundary
bash scripts/check_v04_deletions.sh all # removed API / architecture invariants
bash scripts/check_style_literals.sh  # no bare style literals in examples/
bash scripts/check_release_truth.sh   # docs/evidence consistency
```

Two of these are **ratchets**: `check_zig_format.sh` and
`check_style_literals.sh` allow a fixed budget that may only shrink. Don't widen
the allowlist to make your change pass; format the file, or use the documented
`ui.arb.px()` / `ui.arb.hex()` escape hatch for intentionally off-token values
(see [`docs/STYLING.md`](docs/STYLING.md)).

The real-window E2E suite needs `bun` and a live WindowServer:

```bash
bash scripts/run_storybook_e2e.sh
```

It is flaky under load, so if it fails, re-run before assuming you broke
something, and set `ZENIT_E2E_TIMEOUT_MS=30000` on a slow machine. A genuine
failure reproduces. To rerun one or more named cases against a fresh app process:

```bash
ZENIT_E2E_FILTER='damage-rect|modal body' bash scripts/run_storybook_e2e.sh
```

## House rules

**Tests must be able to fail.** A test that passes against broken code is worse
than no test. When fixing a bug, confirm the new test goes red against the
unfixed code before you commit it. This repo has been bitten by tests that
looked green because they never exercised the path, and by "0 failures" results
that were really compile errors.

**Match the surrounding code.** Comment density, naming, and idiom vary by
module; follow the file you're in. Comments here tend to explain *why*,
especially the non-obvious constraint a line is defending. That convention is
worth keeping.

**Public API changes need a note.** Anything in the `ui.*` / `zenit_app.*`
surface is what users depend on. Breaking changes go in
[`docs/MIGRATION.md`](docs/MIGRATION.md) with a mechanical migration snippet.
See [`docs/API_STABILITY.md`](docs/API_STABILITY.md) for what is considered
stable.

**Rendering changes need eyes on pixels.** Pixel assertions in E2E catch
geometry regressions but will happily pass while the wrong shader draws the
wrong thing. If you touch glass, blur, or compositing, look at the screenshots.

## Commits and PRs

- Conventional-commit prefixes (`fix(render):`, `feat(ui):`, `docs:`); see
  `git log` for the local flavor.
- Explain the root cause, not just the symptom. If you disproved a plausible
  theory on the way, that is worth a line; it saves the next person the trip.
- One logical change per PR where you can manage it.

## Reporting bugs

Include your macOS version, chip (Apple Silicon / Intel), `zig version`, and a
minimal reproduction. For rendering bugs, a screenshot is worth far more than a
description, and mention whether it reproduces in `examples/storybook`, which
is the fastest shared reproduction target.

For security issues, do **not** open a public issue; see
[`SECURITY.md`](SECURITY.md).

## License

zenit is dual-licensed (GPL-3.0-only or commercial, see
[`LICENSING.md`](LICENSING.md)). Before your first pull request can be merged
you must accept the [Contributor License Agreement](CLA.md) by adding this line
to the PR description:

> I have read the zenit CLA (CLA.md) and I agree to its terms.

You keep the copyright in your work; the CLA grants the maintainer the right
to distribute it under both licenses.

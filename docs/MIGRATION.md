# Migration notes

zenit is pre-1.0 and breaking changes happen. This file lists them in
reverse chronological order so consumers can see what to fix when bumping.

> Which APIs are frozen for v1.0 vs. still fair game: see
> [`docs/API_STABILITY.md`](API_STABILITY.md).

## How to add an entry

When you land a breaking change, prepend a section here with:

- the date and a one-line summary ending in `— BREAKING`
- **what changed** — the old shape and the new shape
- **why** — enough that a consumer can tell whether it affects them
- a mechanical migration snippet (before / after code), not prose

`CONTRIBUTING.md` makes this part of the PR checklist for any change that
alters a public symbol.

---

_No entries yet._ Nothing has been published to external consumers, so there
is nothing to migrate from. The pre-1.0 internal reshaping (namespace
tightening, builder-API removal, icon relicensing, and so on) all happened
before any release and is deliberately **not** recorded here — carrying
"how to upgrade from 0.4.x" notes into a first public release would describe
a version nobody outside this repo has ever had.

# Migration notes

zenit is pre-1.0 and breaking changes happen. This file lists them in
reverse chronological order so consumers can see what to fix when bumping.

> Which APIs are frozen for v1.0 vs. still fair game: see
> [`docs/API_STABILITY.md`](API_STABILITY.md).

## How to add an entry

When you land a breaking change, prepend a section here with:

- the date and a one-line summary ending in `(BREAKING)`
- **what changed**: the old shape and the new shape
- **why**: enough that a consumer can tell whether it affects them
- a mechanical migration snippet (before / after code), not prose

`CONTRIBUTING.md` makes this part of the PR checklist for any change that
alters a public symbol.

---

## 2026-10-01: momentum phase and deterministic ScrollArea state (BREAKING)

**What changed.** `ScrollEvent.is_momentum: bool` is replaced by
`momentum: ui.events.MomentumPhase` (`none | began | changed | ended`); use
`scroll.isMomentum()`. `system_sdk.events.MouseWheel` gets the same field.

`ScrollState` no longer guesses gesture boundaries from frame counts. Removed:
`user_scrolling`, `scroll_idle_frames`, `scroll_event_idle_frames`,
`tail_idle_frames`, `momentum_idle_frames`, `has_scroll_history`,
`is_trackpad_session`, `awaiting_trackpad_reengage`, `phase_end_guard_frames`,
`suppress_outward_momentum_x/y`, `bounce_done_time_x/y`, and the tuning fields
`wheel_release_frames`, `trackpad_reengage_delta_threshold`,
`phase_end_guard_frames`, `idle_residual_delta_threshold`,
`momentum_bonus_tail_cutoff`. Added: `touching`, `momentum_active`,
`momentum_spent_x/y`, `input_serial` and `inputActive()`.

Behavior: a mouse wheel without gesture phases no longer rubber-bands (same as
NSScrollView). Momentum that reaches an edge bounces once; the rest of that
momentum stream does not push outward again. Losing window focus cancels an
in-progress gesture and momentum. A diagonal event on a `.both` ScrollArea that
can scroll only one of its axes goes to the layer of its dominant axis instead
of dropping the other component. `Notifier` cards are swiped by trackpad
gestures only: `ended` commits past the threshold, `cancelled` springs back,
and a mouse wheel no longer swipes (there was a 140 ms silence timeout before).

**Why.** The old state was released by timeouts, and several guards were
frame or millisecond windows. Begin/end signals now exist for gestures and
momentum, so the state follows them directly.

**Migration.**

```zig
// before
const active = ss.user_scrolling or ss.scroll_event_idle_frames <= ScrollState.scroll_tuning.wheel_release_frames;
const momentum = ss.momentum_idle_frames <= 2;
if (scroll.is_momentum) ...

// after
const active = ss.inputActive(); // gesture, momentum or scrollbar drag in progress
const scrolled_this_frame = ss.input_serial != last_seen_serial;
if (scroll.isMomentum()) ...
```

## 2026-10-01: scroll events carry the gesture phase (BREAKING)

**What changed.** `ui.events.ScrollEvent` replaces `phase_ended: bool` and
`is_trackpad: bool` with `phase: ui.events.ScrollPhase`
(`none | may_begin | began | changed | ended | cancelled`). Use
`scroll.phaseEnded()` (ended or cancelled) and `scroll.isTrackpad()` instead of
the old fields. `Cx.handleScrollEx` and `Cx.handleScrollWithModifiers` are
replaced by `Cx.handleScroll(ScrollEvent)` and `Cx.handleSdkWheel(MouseWheel)`.
The SystemSdk `mouse_wheel` event is now `system_sdk.events.MouseWheel` with a
`phase` field.

**Why.** Only `phase_ended` reached the dispatcher, so it could not tell when a
new trackpad gesture began. If an `ended` event was lost, every later trackpad
scroll went to the previous gesture's scroll area. `began` now starts a new
gesture deterministically, and `cancelled` releases it.

**Migration.**

```zig
// before
cx.handleScrollWithModifiers(e.x, e.y, e.dx, e.dy, e.is_momentum, e.phase_ended, e.is_trackpad, mods);
if (scroll.phase_ended) release();
if (scroll.is_trackpad) ...

// after
cx.handleSdkWheel(e); // e: system_sdk.events.MouseWheel
if (scroll.phaseEnded()) release();
if (scroll.isTrackpad()) ...
```

Test harness: `POST /scroll` without `phase` is now a mouse-wheel event. Send
trackpad gestures as a full sequence (`phase: "began"`, `"changed"`...,
`"ended"`), or use `trackpadScroll()` from `e2e/client.ts`.

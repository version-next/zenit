# Console and the DevTools Console

Zenit provides each `ui.Cx` with its own independent, thread-safe, capacity-bounded
diagnostic Console. Applications write logs through `cx.console()`; a single log
entry can be printed to the terminal and, at the same time, stored as a structured
event in the target window's in-memory repository, where the DevTools Console panel
and the E2E harness read it incrementally.

Its scope is close to the logging portion of the browser `console`, but it is not a
Zig/JavaScript REPL: the Console panel cannot evaluate expressions, and it does not
persist, upload, or remotely transmit logs.

## Quick start

```zig
const log = cx.console();

log.debug("layout pass {d}", .{pass});
log.log("selected item {d}", .{item_id});
log.info("opened {s}", .{path});
log.warn("cache pressure: {d}%", .{percent});
log.err("save failed: {s}", .{@errorName(err)});
```

Format strings and arguments follow Zig `std.fmt` rules. The second argument is
always an argument tuple; when there are no arguments, pass an empty tuple:

```zig
log.info("application ready", .{});
```

For long-lived subsystems, create a scope. The Console panel renders each scope as
a separate tab, and the filter box matches it too:

```zig
const network = cx.console().scoped("network");
network.info("GET {s} -> {d}", .{ url, status });
network.warn("retry {d}", .{attempt});
```

`ScopedConsole` is only a lightweight reference to its parent Console. It — like
pointers obtained from `cx.console()` — must not outlive the owning `Cx`. Before
closing a window, stop or `join` any worker that may still write logs.

## Opening the DevTools Console

Console is a top-level tab of the separate DevTools window. The DevTools `cx` and
the observed window's `target_cx` are two distinct `Cx` instances:

```zig
fn mountDevTools(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    _ = scope;
    return ui.devtools.mountPanel(cx, target_cx, .{
        .title = "My App DevTools",
    });
}
```

For a complete two-window example see `examples/console_probe`:

```bash
zig build console-probe
open "zig-out/Console Probe.app"
```

DevTools can display historical logs that were captured before the panel was
opened. The panel refreshes with its own low-frequency polling, so new events
never dirty or wake the observed window. Performance data for the target is
therefore not polluted.

> Lifetime requirement: DevTools currently holds the `target_cx` pointer directly.
> Close DevTools first, or ensure the target window outlives the entire DevTools
> session.

## Console panel overview

### Toolbar

The toolbar always spans the full panel width and consists of three parts:

| Control | Behavior |
|---|---|
| **Clear** | Clears the Console authoritative repository of the target `Cx` as well as the current panel mirror. It is not view-only: subsequent harness reads cannot see the removed events either. |
| **Filter console output** | Case-insensitive substring match against `message` and `scope`. Filtering affects only the current DevTools view; repository events are not deleted. |
| **Debug / Log / Info / Warn / Error** | Combinable level filters. Highlighted means enabled, translucent means disabled; all levels are enabled by default. |

Text filtering and level filtering are applied at the same time. To restore the
full list, clear the input box and re-enable all levels.

### Log list

Each row shows, in order: a level color dot, the level, an optional scope, the
message, and an optional source location:

```text
● warn  network  retry 2                              client.zig:84
```

- `warn` / `error` use a subtle semantic background color and never cover the whole
  row in a high-saturation color.
- `group_depth` is converted into left indentation.
- The list is virtualized with a fixed row height, so no UI nodes are created for
  every event when the log volume is large.
- When the user is at the bottom of the list, new logs are followed automatically;
  scrolling up pauses auto-follow so the reading position is never stolen.
- After scrolling back to the bottom, new logs are followed automatically again.

Messages currently render on a single line and are clipped beyond the available
width. Multi-line expansion, object tree expansion, a real columnar `table`, and
collapsing of repeated messages are not implemented yet.

### Status bar

The bottom status bar shows:

```text
120 shown / 860 captured | evicted 42 dropped 0
```

- `shown`: how many entries are visible under the current text and level filters.
- `captured`: how many events are in the current DevTools mirror.
- `evicted`: cumulative count of entries evicted due to the `max_entries` /
  `max_bytes` limits.
- `dropped`: cumulative count of events dropped because of an allocation failure or
  because an event could not fit within the capacity limits.

`evicted` and `dropped` exist to identify *incomplete logs*; they are not ordinary
filter counts.

## Go to source

Ordinary `debug()` / `info()` style methods cannot automatically obtain the
caller location. Zig has no default arguments and no macro that could expand to
the call site from inside a method; when you need a source location, pass `@src()`
explicitly:

```zig
cx.console().writeAt(.err, @src(), "invalid response: {s}", .{reason});
```

Rows that carry a source location display `file.zig:line`. Clicking it reuses the
DevTools source launcher. The application must configure the source roots and the
editor at startup — see [DEVTOOLS.md](DEVTOOLS.md#goto-source):

```zig
ui.devtools.source_link.configure(.{
    .framework_root = "/absolute/path/to/zenit",
    .app = .{
        .entries = &my_generated_index.entries,
        .root = "/absolute/path/to/my-app",
    },
});
```

If `writeAt` was not called, the source launcher is not configured, or the
corresponding source cannot be found on the build machine, the log still displays
normally — it just is not clickable.

## API reference

### Level methods

| API | Level | Description |
|---|---|---|
| `debug(fmt, args)` | debug | High-frequency development diagnostics. |
| `log(fmt, args)` | log | Ordinary logging, corresponding to `console.log` in the Web Console. |
| `info(fmt, args)` | info | Lifecycle or otherwise notable normal events. |
| `warn(fmt, args)` | warn | Recoverable anomalies, degradation, or risk warnings. |
| `err(fmt, args)` | error | Operation failure or unrecoverable error. The method name is `err`; the level string in the panel and harness is `error`. |
| `writeAt(level, @src(), fmt, args)` | specified level | Records a source location you can click to jump to. |

Level thresholds compare as `debug < log < info < warn < error`. For example,
`capture_level = .info` captures info, warn, and error.

### Helper methods

```zig
const log = cx.console();

log.assert(user_id != 0, "invalid user id", .{});
log.inspect("request", request);
log.table(items);

log.group("loading project", .{});
defer log.groupEnd();
log.info("read config", .{});

log.count("retry");
log.countReset("retry");

log.time("load");
// ...
log.timeLog("load");
log.timeEnd("load");
```

| API | Current semantics |
|---|---|
| `assert(condition, fmt, args)` | Writes an error assertion only when the condition is `false`. |
| `trace(fmt, args)` | Writes a debug event with kind `trace`; no call stack is captured automatically yet. |
| `inspect(label, value)` | Prints `label = value` using Zig `{any}` formatting. |
| `table(value)` | Currently falls back to `{any}` text; no columnar table UI yet. |
| `group()` / `groupCollapsed()` / `groupEnd()` | Maintains an indentation depth for subsequent logs of the same writer thread. `groupCollapsed` currently provides no clickable collapse UI. |
| `count(label)` | Increments a counter keyed by `scope + label` and writes an info event. |
| `countReset(label)` | Resets the corresponding counter without writing an extra event. |
| `time(label)` | Starts a named timer; starting it again writes a warn. |
| `timeLog(label)` | Writes the current elapsed time and keeps the timer. |
| `timeEnd(label)` | Writes the current elapsed time and removes the timer. |
| `scoped(name)` | Returns a lightweight `ScopedConsole` bound to a scope. |

Groups are isolated per writer thread; counters and timers are isolated per
`scope + label`. Every public write method may be called from a worker thread —
Console uses the same internal lock to assign the globally monotonic `seq` to each
event.

## Configuration

`zenit_app.Config.console` controls the terminal sink, the in-memory capture sink,
and capacity:

```zig
const app = try zenit_app.App.init(allocator, .{
    .window = .{ .title = "My App" },
    .console = .{
        .terminal_level = .info,
        .capture_level = .debug,
        .max_entries = 10_000,
        .max_bytes = 8 * 1024 * 1024,
        .max_entry_bytes = 64 * 1024,
    },
});
```

Each window created with `MultiWindowApp.createWindowWith` also accepts the same
`.console` configuration individually.

| Field | Default (Debug) | Description |
|---|---:|---|
| `terminal_level` | `.debug` | Minimum terminal level; `null` turns terminal output off completely. |
| `capture_level` | `.debug` | Minimum in-memory capture level; `null` turns DevTools/harness capture off completely. |
| `max_entries` | `10_000` | Maximum number of retained events; beyond it, eviction starts from the oldest event. |
| `max_bytes` | `8 MiB` | Total capacity limit for scope and message text. |
| `max_entry_bytes` | `64 KiB` | Maximum bytes for a single message; truncation stays on a valid UTF-8 boundary and sets `truncated = true`. |

Terminal output and in-memory capture are two independent sinks. As a result,
"visible in the terminal but not in DevTools" is possible, and so is capturing
only into DevTools without terminal output.

### Default policy per build mode

| Build mode | terminal | capture |
|---|---|---|
| Debug | debug and above | debug and above |
| ReleaseSafe | info and above | info and above |
| ReleaseFast / ReleaseSmall | warn and above | off by default |

Opening DevTools never silently modifies the target's capture policy. If
Console history is genuinely needed under ReleaseFast/ReleaseSmall, set
`capture_level` explicitly and weigh sensitive information and memory cost.

You can also reconfigure at runtime:

```zig
cx.console().configure(.{
    .terminal_level = null,
    .capture_level = .info,
    .max_entries = 2_000,
});
```

`configure()` is thread-safe; lowering capacity triggers eviction immediately.

## Clear, capacity, and event order

- `clear()` frees the currently retained events and increments `clear_generation`.
- `clear()` does not reset `seq`, so events from before and after a clear never
  share the same cursor.
- Capacity eviction does not block new events from being written; consumers use
  `gap` to detect that their cursor has fallen behind the oldest event.
- `evicted_total`, `dropped_oom`, and `dropped_oversize` are cumulative over the
  entire Console lifetime.
- Console data lives in memory only and is not retained after the window / Cx is
  destroyed.

Do not treat Console as a business audit log, a crash-recovery log, or compliance
storage. Sensitive values such as passwords, tokens, and personal data should not
be written to diagnostic logs.

## E2E harness

The TypeScript client provides incremental queries, clearing, and waiting:

```ts
import {
  clearConsole,
  consoleEvents,
  waitForConsole,
} from "./client";

// Wait only for logs produced after this point, to avoid matching old history.
const baseline = await consoleEvents(0, 1);
const event = await waitForConsole(
  { text: "save failed", level: "error" },
  5_000,
  baseline.newest_seq,
);

console.log(event.scope, event.source);
await clearConsole();
```

The underlying endpoints are:

- `POST /console`: body is `{ after_seq, limit }`; the server clamps the per-page
  `limit` to 200.
- `POST /console/clear`: calls `console.clear()` on the target `Cx`.

Key fields of `ConsoleSnapshot`:

| Field | Meaning |
|---|---|
| `events` | Deep copies of the events on this page, in ascending `seq` order. |
| `next_cursor` | The `after_seq` to use for the next query. |
| `oldest_seq` / `newest_seq` | The oldest / newest event in the repository at query time. |
| `has_more` | Another page exists after the current cursor. |
| `gap` | Events between `after_seq` and the current oldest event have been evicted. |
| `clear_generation` | The generation of the repository clear, used by consumers to discard stale mirrors. |

`waitForConsole` polls every 25ms and matches by message substring plus an optional
level; on timeout it attaches the most recent 10 events to help diagnose the test
failure. It does not match scope or source.

## Advanced incremental consumption

Consumers inside the framework can read snapshots directly:

```zig
var snapshot = try cx.console().snapshotSince(allocator, after_seq, 200);
defer snapshot.deinit(allocator);

for (snapshot.events) |event| {
    // event.seq / level / kind / scope / message / source / truncated
}
after_seq = snapshot.next_cursor;
```

Consumers must handle pagination, `gap`, and `clear_generation`, and must release
the deep-copied events with `Snapshot.deinit()`. DevTools maintains its own bounded
mirror through exactly this interface.

## FAQ

### The terminal has logs, but the Console panel is empty

1. Check whether `capture_level` is `null`, especially under
   ReleaseFast/ReleaseSmall.
2. Check whether DevTools is attached to the `target_cx` of the correct window.
3. Clear the text filter and re-enable every level.
4. Confirm the logs come from `cx.console()`; `std.log` is not bridged into the
   Zenit Console automatically today.

### Console has logs, the terminal does not

Check `terminal_level`. It can be set to `null` independently, or higher than
`capture_level`; this is a supported configuration.

### The source location is missing or not clickable

Ordinary level methods carry no source. Switch to
`writeAt(level, @src(), ...)`, and configure the source roots and the editor
command of `ui.devtools.source_link`.

### Older logs disappeared

Check `evicted` in the status bar. If it keeps growing, raise
`max_entries` / `max_bytes`, or lower the capture level. Console prioritizes
staying within its bounds and never consumes unbounded memory.

### A message was truncated

Check the event's `truncated` field and `max_entry_bytes`. Overlong messages are
cut on a UTF-8 safe boundary.

### Can I type code into it like the Chrome Console

No. Zenit embeds no JavaScript/Zig evaluator; today the Console targets log
capture, filtering, inspection, go-to-source, and test assertion capabilities.

## Acceptance and regression

Headless unit tests:

```bash
zig test src/ui/console.zig
```

Build the real two-window probe:

```bash
zig build console-probe
```

Smoke script against a real window:

```bash
bash scripts/run_console_smoke.sh
```

The smoke test covers history from before the panel was opened, writes from worker
threads, DevTools self-refresh while the target is idle, text filtering, Clear, and
new logs written after a clear.

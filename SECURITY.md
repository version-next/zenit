# Security Policy

## Supported versions

zenit is pre-1.0. Only the latest tagged release and `main` receive fixes.
There are no long-term support branches yet; that changes at `v1.0.0`.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report privately through GitHub's
[Report a vulnerability](../../security/advisories/new) form, which opens a
private advisory visible only to the maintainers. If that is unavailable to you,
open a public issue containing only "requesting a security contact" and no
details, and a maintainer will reach out with a private channel.

Please include:

- macOS version and chip (Apple Silicon / Intel)
- `zig version`
- What an attacker gains, and what they need to start (a local user? a crafted
  file the app opens? attacker-controlled text?)
- A minimal reproduction if you have one

You should get an initial response within about a week. This is a small project
— if you hear nothing, a ping on the same thread is welcome rather than assumed
to be unwelcome.

## What is in scope

zenit is a GUI framework linked into applications; it has no network stack, no
sandbox, and no privilege boundary of its own. The interesting attack surface is
**memory safety when handling untrusted input**:

- Text handling — shaping, bidi, grapheme segmentation, and the `text_core`
  data structures, when fed attacker-controlled strings
- SVG / icon parsing (`src/icon_ir.zig`, the SVG pipeline)
- Clipboard, drag-and-drop, and file-dialog payloads crossing the
  `system_sdk` boundary
- The GPU/render path, where a malformed display list can produce out-of-bounds
  reads or writes

Crashes reachable from untrusted input are in scope even without a demonstrated
exploit — in a Zig codebase, a reproducible out-of-bounds or use-after-free is a
real finding, and we would rather hear about it.

## What is out of scope

- Anything requiring the attacker to already run arbitrary code in the host
  application's process
- Denial of service through obviously unreasonable input (a billion-node tree
  exhausting memory)
- Findings in an application that merely *uses* zenit, unless the root cause is
  in this repo
- The stubbed Linux/Windows backends — they do not run applications yet

## Disclosure

We will confirm the issue, fix it in `main`, and credit you in the release notes
unless you prefer otherwise. Please give us a reasonable window to ship a fix
before publishing. If a report turns out to be a non-security bug, we will say
so plainly and move it to a normal issue rather than leaving it in limbo.

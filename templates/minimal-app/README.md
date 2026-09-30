# minimal-app — zenit consumer template

A self-contained example of using zenit from a downstream project.

## Layout

```
minimal-app/
├── build.zig          # uses zenit.attach() — one-line wiring
├── build.zig.zon      # declares zenit dependency
├── e2e/record-demo.ts # drives and records the app through Harness
└── src/main.zig       # full counter button app
```

## Use it

1. **Copy this directory** anywhere outside the zenit repo.
2. **Edit `build.zig.zon`** — update `.dependencies.zenit`. The default
   `.path = "../../"` only resolves when the template stays inside the
   zenit repo at `templates/minimal-app/`. After copying, either:
   - Point `.path` at your local zenit checkout, or
   - `zig fetch --save=zenit <url>` to pin a published revision.
3. **Update `.fingerprint`** in the same file — the template's value will
   collide if you keep it. Delete the line and run `zig build` once; Zig
   prints the unique value to paste back.

```bash
zig build run    # unbundled
zig build app    # build a .app bundle (macOS only)
```

## Record an automated run

The template forwards `-Dtest-mode` to Zenit and installs the typed Harness
client into `zig-out/share/zenit/harness/client.ts`.

Build and run the app in one terminal:

```bash
zig build -Dtest-mode=true
ZENIT_E2E_FILE_RPC_DIR=/tmp/myapp-e2e ./zig-out/bin/myapp
```

Run the included controller in another terminal:

```bash
ZENIT_E2E_FILE_RPC_DIR=/tmp/myapp-e2e bun run e2e/record-demo.ts
```

The result is `artifacts/minimal-app.mp4`. It contains only the Retina app
surface and Zenit's virtual cursor; it does not capture the desktop or require
macOS Screen Recording permission. See [`docs/HARNESS.md`](../../docs/HARNESS.md)
in the Zenit package for the complete contract.

## What `zenit.attach()` does

`zenit.attach(zenit_dep, exe)` is a public API of zenit's root `build.zig` —
`const zenit = @import("zenit");` at the top of your `build.zig` makes it
available (Zig 0.15.2). A single call does three things:

1. Adds the `@import("ui")` and `@import("zenit_app")` module imports to your
   exe's root module.
2. Compiles the 5 macOS native ObjC bridges (window / recording / metal /
   coretext / image) out of the package.
3. Links the required platform frameworks (Cocoa / Metal / CoreText /
   AVFoundation / QuartzCore / ImageIO / ...).

Without the helper, a consumer would hand-roll the same `addCSourceFile` +
`linkFramework` boilerplate from zenit's own `build.zig`. If you want to see
(or customize) exactly what gets wired, read `attach` / `addNativeLibs` there.

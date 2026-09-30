# Zenit icons — Lucide (open-source releases)

This directory holds the **Lucide** icon set: 2,025 upstream 24×24 stroke SVGs
plus `hand-pointing.svg`, a byte-identical compatibility alias of upstream
`pointer.svg`, from
[`lucide-static` v1.31.0](https://lucide.dev), vendored **unmodified**
(byte-identical to upstream).

**This is the default and only set to ship in public/open-source builds.** The
optional internal profile lives in the separate
`private/zenit-icons-untitled` package, which is paid-licensed and cannot be
redistributed.

## License

Lucide is [ISC licensed](LICENSE) — the full text, including the notice for
icons derived from Feather, is in the `LICENSE` file here. ISC permits
redistribution provided the copyright notice travels with the copies, which is
why `LICENSE` sits beside the SVGs and must ship with them.

These icons are **not** covered by zenit's own license (GPL-3.0-only or
commercial); [`LICENSING.md`](../../../LICENSING.md) carves this directory out
explicitly.

## Selecting this set

```sh
bash scripts/switch_icon_set.sh lucide
```

That verifies the Lucide build profile without modifying the worktree.

Regenerate the committed provider module only when the SVG set changes:

```sh
zig build gen-icons-lucide
```

## Updating the vendored copy

```sh
rm src/ui/icons_oss/*.svg
cp <lucide-static>/icons/*.svg src/ui/icons_oss/
cp <lucide-static>/LICENSE     src/ui/icons_oss/LICENSE
zig build gen-icons-lucide
```

Delete before copying — icon sets rename files between releases, and a plain
copy leaves the old ones behind, still generating stale constants. Keep the
files byte-identical to upstream: the ISC notice covers verbatim copies, and
matching upstream exactly makes the next update a clean overwrite.

## Names

Named constants use underscores because they are Zig identifiers; registry
names keep the original kebab-case spelling. Names colliding with a Zig keyword
or primitive are escaped — Lucide ships a `type.svg`, so `ui.icons.@"type"` is
real. The generator handles this, so an upstream rename cannot silently break
the build.

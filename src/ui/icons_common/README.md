# Zenit common icons

This is the small provider-neutral source set behind `ui.assets.common`.
17 of the 18 SVG files are byte-identical copies of Lucide v1.31.0 icons;
filenames retain Zenit's historical API spelling (`chevron_down`, `x_close`,
etc.). `mark.svg` maps to Lucide `crosshair.svg`, and `x_close.svg` maps to
`x.svg`. `star_filled.svg` is Lucide `star.svg` with `fill="currentColor"`
(the Rate component's default glyph).

The icons are ISC licensed under [`../icons_oss/LICENSE`](../icons_oss/LICENSE).
Regenerate their flattened geometry with:

```sh
zig build gen-icons-common
```

Reusable components should prefer `ui.system_icons` for new semantic roles.
This compatibility set remains for existing component props and
`ui.assets.common.*` callers.

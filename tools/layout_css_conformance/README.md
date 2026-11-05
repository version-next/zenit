# Layout and CSS conformance

Compare Zenit layout rectangles with browser DOMRects in headless Chromium,
Firefox and WebKit. The fixtures cover flex sizing and wrapping, text baselines,
the box model, positioning, aspect ratio, Grid and long words. See
[the migration notes](../../docs/MIGRATION.md) for the layout API.

```sh
npm ci --ignore-scripts --prefix tools/layout_css_conformance
PLAYWRIGHT_BROWSERS_PATH="$PWD/tools/layout_css_conformance/.browsers" \
  node tools/layout_css_conformance/node_modules/playwright-core/cli.js install chromium-headless-shell firefox webkit
zig build test-layout-css-conformance
zig build layout-css-conformance
# Enforce required fixtures on every selected browser:
zig build layout-css-conformance -- --enforce --require-all
```

Requires Node >=22, Zig 0.17.0 and the host font backend (macOS CoreText; Linux FreeType as configured by the repository). The build step is registered in the existing macOS/Linux UI graph. Windows support is not claimed. Chromium uses chrome-headless-shell with `--single-process --in-process-gpu --disable-gpu`; no visible browser and no OS input control. Firefox/WebKit use Playwright's headless mode and report launch failures. Running WebKit here is not a Safari application acceptance run.

Browser downloads, npm modules and results are ignored. Browser install is a separate explicit setup operation; a build never downloads binaries automatically. The local font server binds only 127.0.0.1 and serves exactly the fixed font file. A missing Chromium or measurement error fails the command; absent optional engines are recorded. If no engine completes measurement, the command always fails. Use `--require-all` when availability is required.

The executable is built by Zig, then Node invokes it with `<suite.json> <zenit-output.json>`. Node accepts `--fixtures PATH`, `--out DIR`, `--browsers chromium,firefox,webkit`, `--enforce`, `--require-all`. Outputs are `zenit.json`, `report.json`, `report.md`, and one generated HTML per fixture/engine. HTML files reference the temporary loopback font URL; rerun the command to measure them with the same font. Reports contain every node, including matching nodes, deltas and property-tag summaries. Multiple property tags overlap and are not causal attribution.

## Fixture v1

```json
{"version":1,"fixtures":[{
  "id":"grow-min","properties":["grow","min-max"],"must_match":false,
  "width":300,"height":100,
  "root":{"id":"root","style":{"width":{"px":300},"height":{"px":100},"direction":"row"},"children":[
    {"id":"a","style":{"width":{"grow":{"min":250}},"height":{"px":20}}},
    {"id":"b","style":{"width":{"grow":{}},"height":{"px":20}}}
  ]}
}]}
```

IDs are unique within each tree; fixture IDs are unique within the suite. Root dimensions should be explicit; width/height also define available viewport size. Node style defaults mirror Zenit (fit/fit, column, stretch, flex/shrink=1). The complete typed schema is the `Style`, `Text`, `Spec`, `Fixture`, `Suite` declarations in `zenit.zig`; unknown fields fail parsing. JS preflight validates IDs, sizing tags, dimensions, field names and bounded grid/isolation inputs; Zig's typed parser additionally validates field payloads and enums.

Sizing uses one tagged object: `{"px":40}`, `{"percent":50}`, `{"grow":{"min":0,"max":100}}`, `{"fit":{}}`. Omitted max is infinity; JSON Infinity is forbidden. `flex_basis` accepts nonnegative pixel numbers, `"auto"` (default) and `"content"`. Native `FlexBasis.auto`/`.content` are f32 keyword constants; explicit 0 stays distinct. A missing minimum is automatic; an explicit 0 disables the content floor. `padding`/`margin` are four-edge objects, missing edges zero; `margin_auto_mask` bits are top=1,right=2,bottom=4,left=8. `inset` edges use `"auto"`, `{"px":10}`, `{"percent":50}`. `sticky_insets` edges use numbers or null.

`grid` contains `columns`, optional `rows`, `column_gap`, `row_gap`; tracks are `{"px":40}`, `{"fr":1}`, `"auto"`, or `{"minmax":{"min":{"px":0},"max":{"fr":1}}}` (omitted min/max default to auto). At most 16 explicit tracks each axis; implicit row limit fixtures stay inside the public config type. `grid_placement` contains `col_start,row_start` (0=auto), `col_span,row_span` (default1). `border` follows the native struct including `width` and `side_widths` (top/right/bottom/left, -1 inherits width).

Optional `text` contains `content`, `font_size` (16 or32), `line_height` (default1.4), `wrap` (`none/word/char/newline_only/word_break/break_all/keep_all`), `overflow_wrap` (`normal/break_word/anywhere`), `word_break` (`normal/break_all/keep_all`), `max_lines`, `text_overflow` (`clip/ellipsis/ellipsis_smart`), `fade_right`. Font is always the existing Lora fixture at weight400. Full original text is preserved in DOM. Rectangles can detect intrinsic/wrap/baseline layout changes, but do **not** verify rendered ellipsis/suffix/mask pixels. Sticky is sampled at scroll0. Rotation/scaling, hit testing, paint clipping and scrolling are outside v1's measurements and explicitly marked unmeasured in the mapping.

By default the command reports differences. With `--enforce`, any unqualified
difference in a fixture marked `must_match` fails the command. With
`--require-all`, every selected engine must be available.


A fixture may contain `"known_engine_deviation":{"webkit":"Measured reason + https://spec-or-bug-reference"}` (supported keys: `chromium`, `firefox`, `webkit`). The five macOS WebKit qualifications are the four `grow-min` directions (275/25 rather than the specified 250/50 freeze/re-distribution) and `column-text-auto-min` (132px rather than Chromium 134.34px / Firefox 134.4px with the bundled font). Their references and observed values are kept in the fixture data. The policy is the specification plus two agreeing engines, rather than majority behavior overriding the specification.

An annotation qualifies a difference only when the same run measures two other distinct engines matching Zenit and each other at the existing 0.5px tolerance. Otherwise it remains `DIFF` and fails `--enforce` for `must_match`. Qualified differences are listed separately under **Known engine deviations / 已知偏差**, excluded from the failure count, and retained with all raw rectangles/deltas and `match:false` in JSON. Matching annotated fixtures still count as matches. Missing nodes, non-finite geometry, browser measurement errors and unavailable engines cannot be excused by an annotation. Report-only engine disagreements require `must_match:false` and an explanatory `note`; the tolerance is unchanged. Property summaries show known deviations separately and retain raw differing-node counts.

`fit-parent-basis-zero` covers a fit-width row whose fixed-width child explicitly specifies `flex_basis:0` and `min_width:0`: both the fit parent and child must resolve to width 0. The real-tree Zig test checks both rectangles, so intrinsic measurement and final flex resolution must preserve the same explicit-zero meaning.

## Text controls and baseline

Every text node explicitly sets `font-kerning:normal`,
`font-feature-settings:normal`,
`font-variant-ligatures:common-ligatures contextual no-discretionary-ligatures no-historical-ligatures`,
`letter-spacing:0px`, `word-spacing:0px`, `text-rendering:optimizeLegibility`,
`font-synthesis:none`, `font-optical-sizing:none`, and
`-webkit-text-size-adjust:100%`. These are measurement controls, not fixture-specific
compensation. The static bundled Lora face has no optical-size axis.

Zenit and the browsers use the bundled Lora face with standard kerning and
ligatures. Layout and paint share the resolved face metrics and half-leading.
Use `TextProps.baseline_ratio` to supply an explicit baseline ratio.

The pinned WebKit fixture reports
`column-text-auto-min` at 132px versus Zenit/Firefox 134.4px and Chromium
134.34375px: six lines times floor(22.4px). This matches
[WebKit 261463](https://bugs.webkit.org/show_bug.cgi?id=261463), fixed on ToT in
February 2026; pinned Playwright 1.56.1 uses WebKit 26.0 revision 2215. Similar
fractional-height losses are documented individually in baseline/wrapped-text
fixtures; only cases with two complete agreeing controls qualify. This is an old-engine qualification, not a claim about current Safari.

Pinned Firefox's baseline measurements are consistent with ceil ascent/descent
and fractional half-leading: Lora's hhea/OS2 values are 1006/-274 per 1000 units;
16px metrics become 17/5, and 32px become 33/9. First baselines are 17.2/34.4px
rather than the measured Chromium/WebKit 17/33px. CSS2 §10.8.1 defines the
half-leading formula; exact font-metric rounding remains an engine difference.
Fixture notes distinguish baseline positions from independent WebKit height loss.

Overflow distribution keeps Zenit's **flex-start** fallback, including reverse
axes. [CSSWG #11937](https://github.com/w3c/csswg-drafts/issues/11937) and its
[January 2026 edit](https://github.com/w3c/csswg-drafts/commit/0400daae18e8b47744240d6b3fc71b3c54689854)
address reversed safe alignment and scroll containers, including space-between;
they do not directly settle around/evenly in these non-scroll fixtures. Pinned
Chromium/Firefox use physical start; WebKit agrees with Zenit. The six fixtures
are report-only disagreements, with exact values and the choice explained in
notes. Conversely, wrap-reverse space-between uses cross-start in
Zenit/Chromium/WebKit; pinned Firefox's physical-start result qualifies separately.
WebKit's negative-margin baseline
case is also separate: it has no text and cannot be explained by line-height
truncation. Tolerance (0.5px) and fixture membership are unchanged. The two baseline /
first-baseline wrap-reverse fixtures remain report-only: b.y is 59.2/58/60
in Chromium/Firefox/WebKit, and metric rounding plus fractional line-height
propagation leave no pair of independent agreeing controls. Their notes retain
the exact values and specification basis, following the LC3A three-way policy.

`align_content` maps to CSS `align-content` (default `normal`, behaving as stretch
for flex). `AlignItems.first_baseline` maps to `first baseline`; `baseline` is its
alias in the supported horizontal writing mode. The corpus covers individual
align-self overrides, stretch bounds, cross auto margins, per-line grow/shrink,
line packing, reversed axes, text/nested/synthesized baselines, negative justify,
and 257 lines. Short line-height and negative margins can place a baseline outside
its outer box: baseline-group distances stay signed, with only the resulting line
size bounded at zero. Dedicated nowrap/wrap/reverse fixtures prevent 19px replacing
the required 17px line for Lora at line-height:.5.
Native rendering, GUI input and screenshot acceptance remain separate.

## Qualifying independent engine differences

Raw rectangles and the 0.5px comparison tolerance remain unchanged. Engine
disagreements are explicitly marked report-only, as described below.
Each qualified fixture needs two other distinct measured engines agreeing with
Zenit and with each other over every rectangle at the existing 0.5px tolerance.
Orthogonal differences cannot provide complete agreeing controls. A specification
citation or numeric contract cannot replace either browser measurement.

Reverse around/evenly overflow has measured engine disagreement: Chromium/Firefox
use physical start, WebKit/Zenit use flex-start. The six affected fixtures use
`must_match:false` plus notes with exact measurements and the limited scope of
CSSWG #11937 / the January 2026 edit. Nine text baseline fixtures also lack two
complete agreeing controls (two were already report-only); their notes retain
all engine measurements and explanations. None carries a known-deviation waiver.
New engine disagreements use explicit `must_match:false` with a nonempty `note`
(validated when present); older unsupported report-only controls may omit notes. The native regressions
still require Zenit's chosen reverse fallback geometry at 0.01px, independently
of browser metadata. Crash, timeout, leak and missing-case checks remain required.

## Box model, positioning, ratio, Grid and long words

Borders now consume layout space inside the existing border-box width/height
contract. Padding plus resolved border widths form the content inset and size
floor. `border.overlay:true` is an explicit decorative extension: the rectangle
oracle omits CSS border widths for it; a real Web renderer must draw an inset
shadow or independent pseudo-element. It is not the default border behavior.
Relative insets offset the flow result; `position:"static"` skips a containing
block, and a tree with no positioned ancestor uses the fixture viewport.

The ratio corpus covers both derivation directions, nowrap/wrap/reverse, definite
percent preservation, bounds and transferred flex automatic minima. Grid adds
standard fr floors/freezing, sub-unit factors, auto tracks, positive single-axis
placement/span and dynamic implicit tracks. `minmax` uses
`{"minmax":{"min":{"px":0},"max":{"fr":1}}}`; minimum supports px/auto,
maximum px/fr/auto. `"auto"` works both as a track and as a minmax breadth.
The explicit config still has 16 slots per axis; implicit rows/columns no longer
use the old fixed tables. Full intrinsic/indefinite Grid sizing, intrinsic
track keywords, complex span competition and additional flow modes remain
residuals, as documented in the mapping.

Text accepts `overflow_wrap:normal|break_word|anywhere` and
`word_break:normal|break_all|keep_all`. Normal `.word` no longer emergency-breaks
an unbreakable word. Anywhere and break-all lower min-content; break-word keeps
the unbroken minimum. A separate explicit-min=0 fixture reaches break-word's
actual emergency line-breaking path. `.char` maps to anywhere; `.word_break`
is the explicit legacy emergency-wrap shorthand. Fixed-font rectangle evidence
does not verify mixed-script shaping or pixels.

The fixture regression checks that required cases remain present. Browser
comparisons use a 0.5px tolerance.

Explicit `normal` control values retain the native wrap shorthand default (for example `wrap:char` still maps to `overflow-wrap:anywhere`). Use `wrap:word` for ordinary word wrapping. Non-default control/alias combinations and keep-all emergency combinations remain subject to the mapping residuals.

CSS Grid [§12.5 step 4](https://www.w3.org/TR/css-grid-2/#algo-spanning-flex-items)
uses flex-factor proportions for spanning flexible tracks. The default sparse
[§8.5 row-locked placement](https://www.w3.org/TR/css-grid-2/#auto-placement-algo)
stays past earlier items placed by that step; it only fills an initial hole before
any row-locked item has passed it. Dense backfilling is outside the supported subset.
The fixtures distinguish these cases; neither behavior is a browser-deviation waiver.

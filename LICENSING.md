# Licensing

Copyright (C) 2026 zy <zongyi.xzy@gmail.com>. All rights reserved except as
granted below.

zenit is **dual-licensed**. You may use it under **either** of the following,
at your choice:

1. **GNU General Public License, version 3 only** (`GPL-3.0-only`): the full
   text is in [`LICENSE`](LICENSE).
2. **A commercial license** from the copyright holder.

SPDX expression for zenit's own source:
`GPL-3.0-only OR LicenseRef-zenit-Commercial`

## Which one do I need?

| Your situation | License |
|---|---|
| Open-source project released under GPL-3.0 (or a GPL-3.0-compatible license, distributed as a whole under GPL-3.0) | GPL-3.0, free |
| Personal study, evaluation, internal experiments that are never distributed | GPL-3.0, free |
| Closed-source / proprietary application, SDK or product that links zenit | **Commercial license required** |
| You want to ship an app built on zenit without publishing its full source under GPL-3.0 | **Commercial license required** |
| You want to modify zenit and keep the modifications private while distributing them | **Commercial license required** |

zenit is a library that is compiled and statically linked into your
application. Under GPL-3.0, distributing an application that includes zenit
means distributing the **whole application** under GPL-3.0, with its complete
corresponding source code. If you cannot or do not want to do that, you need a
commercial license.

This table is a summary for convenience. The terms of the GPL-3.0 text in
[`LICENSE`](LICENSE) and of any signed commercial agreement are what govern.

## Commercial license

The commercial license lets you use, modify and distribute zenit as part of
proprietary products without the GPL-3.0 obligations. Terms (scope, number of
products or seats, support, pricing) are agreed individually.

Contact: **zongyi.xzy@gmail.com** (subject: `zenit commercial license`).

## Exceptions: templates and examples

To let you start a project from our scaffolding without legal friction, the
contents of these directories are additionally released under the
**BSD Zero Clause License** (`0BSD`, see [`templates/LICENSE`](templates/LICENSE)
and [`examples/LICENSE`](examples/LICENSE)):

- `templates/`
- `examples/`

You may copy code out of them into your own project with no attribution or
copyleft obligation. Note this does not change the license of zenit itself:
an application that links zenit is still subject to GPL-3.0 unless you hold a
commercial license.

## Third-party components

The dual license above covers zenit's own source. The following vendored
components are licensed separately by their respective authors, and
redistributing zenit means redistributing them under their own terms:

```
  src/ui/icons_oss/*.svg
  src/ui/icons_common/*.svg
                          Lucide icon set, ISC License.
                          Copyright (c) for the Lucide icons and contributors.
                          Full text: src/ui/icons_oss/LICENSE
                          (Some Lucide icons derive from the Feather project,
                          MIT licensed; that notice is included in the same
                          file.)
                          This is the set used for open-source builds.

  private/zenit-icons-untitled/icons/*.svg
                          Untitled UI icon set, used under a PAID license
                          that does NOT permit redistribution of the raw SVG
                          files. This optional internal build profile and its
                          generated module MUST NOT be published in a public
                          repository or distributed package. Public builds
                          default to Lucide, but source-tree exclusion is still
                          required. See the private package README.

  vendor/unicode/         Unicode Character Database, Unicode License V3.
                          Copyright (c) Unicode, Inc.
                          Full text: vendor/unicode/LICENSE.txt
```

ISC, MIT and the Unicode License are all compatible with both GPL-3.0 and the
commercial license.

## Contributions

Because zenit is dual-licensed, every external contribution must be covered by
the [Contributor License Agreement](CLA.md). See
[`CONTRIBUTING.md`](CONTRIBUTING.md#license).

## Trademark

"zenit" and its logo are not licensed under GPL-3.0 or `0BSD`. Forks must not
present themselves as the official zenit project.

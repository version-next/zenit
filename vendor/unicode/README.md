# Vendored Unicode data

Zenit pins Unicode Character Database **17.0.0** for extended grapheme cluster
segmentation and the Unicode Bidirectional Algorithm. The source files in
`17.0.0/` are unmodified members of Unicode's 17.0.0 UCD distribution. The
large conformance files were extracted from the official `UCD.zip`; every
artifact is pinned in `17.0.0/SHA256SUMS`. `LICENSE.txt` contains the Unicode
Data Files and Software License.

The bidi inputs are:

- `DerivedBidiClass.txt`, `BidiBrackets.txt`, and `BidiMirroring.txt` for
  generated runtime properties;
- complete `BidiTest.txt` (490,846 type sequences / 770,241 paragraph-direction
  evaluations) and `BidiCharacterTest.txt` (91,707 character sequences) for
  conformance through UAX #9 rule L2.

Regenerate the checked-in Zig lookup tables from the repository root:

```sh
python3 tools/generate_grapheme_data.py
python3 tools/generate_grapheme_data.py --check
```

The generated implementation is verified against every case in the vendored
`GraphemeBreakTest.txt` by `zig build test-text-core`.

Regenerate and verify the bidi property table without network access:

```sh
python3 tools/generate_bidi_data.py
python3 tools/generate_bidi_data.py --check
(cd vendor/unicode/17.0.0 && shasum -a 256 -c SHA256SUMS)
zig build test-bidi-conformance
```

The last command executes both complete official bidi conformance files. It is
also part of `zig build test-headless`.

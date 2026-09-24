The width table uses Unicode 17.0.0's Wide and Fullwidth properties.
The source is [EastAsianWidth.txt](https://www.unicode.org/Public/17.0.0/ucd/EastAsianWidth.txt),
redistributed under [Unicode License v3](LICENSE.txt).

Regenerate with `python3 tools/generate_widths.py`; check with
`python3 tools/generate_widths.py --check`. The generator verifies the
source's SHA-256 and requires no network access. Review the source and
checksum together when upgrading Unicode.

The generated table is part of the Zig package. Python is needed only
for maintenance and CI. Combining-mark handling remains in `cell.zig`;
grapheme-cluster segmentation is outside the library's scope.

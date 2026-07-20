#!/usr/bin/env python3
"""Assert every icon the plugin asks for exists in a font KOReader bundles.

A codepoint no bundled font carries renders as a .notdef box on the device, and nothing in Lua,
in the .po files, or in any other check complains -- the only symptom is a box a human has to
notice. Two shipped that way: U+F0013 on the author line and U+1F5D8 on "Reset to defaults",
both plausible-looking Private Use codepoints that simply are not in the fonts.

KOReader resolves a glyph through Font.fallbacks (frontend/ui/font.lua), so "covered" means
present in ANY bundled face, not just the one the widget asks for.

Covered means mapped to a real glyph. A cmap can list a codepoint inside a segment and still
resolve it to glyph 0, which is .notdef -- the box itself. An earlier version of this parser
read only the start and end of each format-4 segment and ignored idDelta/idRangeOffset, so it
counted those as covered: the one bug a coverage checker must not have.

usage: python3 glyph_coverage_check.py <plugin-root> <koreader-root>
"""
import glob
import os
import re
import struct
import sys


def _u16(data, off):
    return struct.unpack_from(">H", data, off)[0]


def _parse_format4(data, sub):
    """Format 4: segmented mapping. Returns codepoints resolving to a non-zero glyph id."""
    out = set()
    seg_x2 = _u16(data, sub + 6)
    seg = seg_x2 // 2
    end_off = sub + 14
    start_off = end_off + seg_x2 + 2          # +2 skips reservedPad
    delta_off = start_off + seg_x2
    range_off = delta_off + seg_x2

    for i in range(seg):
        end = _u16(data, end_off + i * 2)
        start = _u16(data, start_off + i * 2)
        delta = _u16(data, delta_off + i * 2)
        range_offset = _u16(data, range_off + i * 2)
        if start > end or start == 0xFFFF:
            continue
        for c in range(start, min(end, 0xFFFE) + 1):
            if range_offset == 0:
                gid = (c + delta) & 0xFFFF
            else:
                # The offset is measured from the idRangeOffset slot itself, which is why the
                # segment's own position is added back in.
                addr = range_off + i * 2 + range_offset + (c - start) * 2
                if addr + 1 >= len(data):
                    continue
                gid = _u16(data, addr)
                if gid != 0:
                    gid = (gid + delta) & 0xFFFF
            if gid != 0:
                out.add(c)
    return out


def _parse_format12(data, sub):
    """Format 12: segmented coverage reaching beyond the BMP."""
    out = set()
    ngroups = struct.unpack_from(">I", data, sub + 12)[0]
    for g in range(ngroups):
        go = sub + 16 + g * 12
        start, end, start_gid = struct.unpack_from(">III", data, go)
        if start_gid == 0 or end < start or end - start > 0x20000:
            continue
        out.update(range(start, end + 1))
    return out


def font_codepoints(path):
    """Codepoints a font maps to a real glyph. Handles cmap formats 4 and 12, and .ttc."""
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return set()
    try:
        off = struct.unpack_from(">I", data, 12)[0] if data[:4] == b"ttcf" else 0
        num = _u16(data, off + 4)
        cmap_off = None
        for i in range(num):
            o = off + 12 + i * 16
            if data[o:o + 4] == b"cmap":
                cmap_off = struct.unpack_from(">I", data, o + 8)[0]
        if cmap_off is None:
            return set()

        out = set()
        for i in range(_u16(data, cmap_off + 2)):
            rec = cmap_off + 4 + i * 8
            sub = cmap_off + struct.unpack_from(">I", data, rec + 4)[0]
            fmt = _u16(data, sub)
            if fmt == 4:
                out |= _parse_format4(data, sub)
            elif fmt == 12:
                out |= _parse_format12(data, sub)
        return out
    except (struct.error, IndexError):
        return set()


# Not glyphs: KOReader's "poor text formatting" markers, which textboxwidget consumes as control
# codes and never draws (frontend/ui/widget/textboxwidget.lua:128-130).
CONTROL = {0xFFF1: "PTF_HEADER", 0xFFF2: "PTF_BOLD_START", 0xFFF3: "PTF_BOLD_END"}

ESCAPE = re.compile(r"\\u\{([0-9A-Fa-f]+)\}")


def plugin_codepoints(plugin_root):
    """Every non-ASCII codepoint the plugin can put on screen from Lua -- \\u{...} escapes and
    literal UTF-8 alike, since an icon pasted in directly is just as capable of being a box."""
    wanted = []
    for lua in sorted(glob.glob(os.path.join(plugin_root, "**/*.lua"), recursive=True)):
        if os.path.basename(lua) == "zlibrary_credentials.lua" or os.sep + "test" + os.sep in lua:
            continue
        rel = os.path.relpath(lua, plugin_root)
        with open(lua, encoding="utf-8", errors="replace") as fh:
            for lineno, line in enumerate(fh, 1):
                for m in ESCAPE.finditer(line):
                    cp = int(m.group(1), 16)
                    if cp >= 0x80 and cp not in CONTROL:
                        wanted.append((rel, lineno, cp, "escape"))
                for ch in line:
                    cp = ord(ch)
                    if cp >= 0x80 and cp not in CONTROL:
                        wanted.append((rel, lineno, cp, "literal"))
    return wanted


def main(plugin_root, koreader_root):
    fonts = {}
    for pat in ("resources/fonts/**/*.ttf", "resources/fonts/**/*.ttc", "resources/fonts/**/*.otf"):
        for p in glob.glob(os.path.join(koreader_root, pat), recursive=True):
            fonts[os.path.basename(p)] = font_codepoints(p)
    if not fonts:
        print(f"  no fonts under {koreader_root}/resources/fonts")
        print("  a fresh KOReader clone needs its submodules: git submodule update --init")
        return 2
    covered = set().union(*fonts.values())
    print(f"  {len(fonts)} bundled fonts, {len(covered)} codepoints mapped to a real glyph\n")

    wanted = plugin_codepoints(plugin_root)
    if not wanted:
        # The plugin has always had icons. Finding none means the scan broke, not that the
        # problem went away, and reporting success would be a lie.
        print("  FAIL: no non-ASCII codepoints found at all -- the scan itself is broken")
        return 1

    missing, seen = [], set()
    for rel, lineno, cp, kind in wanted:
        if cp in covered:
            continue
        missing.append((rel, lineno, cp, kind))
        key = (rel, lineno, cp)
        if key not in seen:
            seen.add(key)
            print(f"  MISSING  U+{cp:04X}  ({kind})  {rel}:{lineno}")

    print(f"\n  {len(wanted) - len(missing)}/{len(wanted)} codepoints covered by a bundled font")
    return 1 if missing else 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: python3 glyph_coverage_check.py <plugin-root> <koreader-root>")
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))

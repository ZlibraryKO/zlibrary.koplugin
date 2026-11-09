#!/usr/bin/env python3
"""Assert every locale ships a catalogue KOReader can actually load.

A contributor's Portuguese (Portugal) locale shipped two defects that a green build never
caught, because both fail silently at runtime on the device, not at compile time:

  1. The file was named `pt-PT.po`, but KOReader loads `l10n/<lang>/koreader.mo` (its textdomain
     is "koreader", see frontend/gettext.lua). A differently-named file is never read, and there
     was no compiled .mo at all -- so the locale simply never loaded.

  2. The catalogue had no `Plural-Forms` header. KOReader's parse_headers does
     `plural_forms = headers:match("Plural-Forms: (.*)")` and then, on the very next line,
     `plural_forms:match("nplurals=...")` -- which throws "index a nil value" when the header is
     absent (frontend/gettext.lua:187-188). The plugin's gettext shim wraps changeLang in pcall,
     so the throw is swallowed: the ENTIRE locale fails to load and silently falls back to
     KOReader's global catalogue. The visible symptom is maddening -- shared words (Cancel,
     Search) translate because KOReader's own catalogue has them, but plugin-only strings
     (Recommended, My books) show English.

So a locale can be 100% translated, pass msgfmt, and still be dead on the device. This check
pins the three things that must hold for a catalogue to load at all.

usage: python3 po_catalogue_check.py <plugin-root> [<koreader-root>]
"""
import gettext
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile


def header_block(po_text):
    """The metadata entry: the msgstr of the empty msgid, at the top of the file."""
    # The header is the first `msgid ""` / `msgstr ""` followed by "..." continuation lines.
    m = re.search(r'\nmsgid ""\nmsgstr ""\n((?:"(?:[^"\\]|\\.)*"\n)*)', "\n" + po_text)
    if not m:
        return None
    # join the quoted continuation lines into the actual header string
    return "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1)))


def po_translations(po_text):
    """Single-line msgid/msgstr pairs that msgfmt would compile, skipping fuzzy and retired ones."""
    def unescape(text):
        return text.replace("\\n", "\n").replace("\\t", "\t").replace('\\"', '"').replace("\\\\", "\\")

    pairs = {}
    fuzzy = False
    lines = po_text.split("\n")
    for i, line in enumerate(lines):
        if line.startswith("#,") and "fuzzy" in line:
            fuzzy = True
        if line == "":
            fuzzy = False
        msgid = re.match(r'^msgid "(.+)"$', line)
        if msgid and i + 1 < len(lines) and not fuzzy:
            msgstr = re.match(r'^msgstr "(.+)"$', lines[i + 1])
            continued = i + 2 < len(lines) and lines[i + 2].startswith('"')
            if msgstr and not continued:
                pairs[unescape(msgid.group(1))] = unescape(msgstr.group(1))
    return pairs


def compiled_failures(locale_dirs):
    """msgfmt is what the release runs: a file it rejects is not compiled, and ships out of date."""
    if shutil.which("msgfmt") is None:
        print("  SKIP: msgfmt not found, so the catalogues were not compiled")
        return []
    failures = []
    for d in locale_dirs:
        loc = os.path.basename(d)
        po = os.path.join(d, "koreader.po")
        mo = os.path.join(d, "koreader.mo")
        if not (os.path.isfile(po) and os.path.isfile(mo)):
            continue  # already reported
        with tempfile.NamedTemporaryFile(suffix=".mo") as out:
            done = subprocess.run(["msgfmt", "--check-format", "-o", out.name, po],
                                  capture_output=True, text=True)
        if done.returncode != 0:
            first = done.stderr.strip().split("\n")[0]
            failures.append("%s: msgfmt rejects koreader.po: %s" % (loc, first))
            continue
        with open(po, encoding="utf-8") as fh:
            wanted = po_translations(fh.read())
        with open(mo, "rb") as fh:
            have = gettext.GNUTranslations(fh)._catalog
        stale = sorted(k for k, v in wanted.items() if have.get(k) != v)
        if stale:
            failures.append('%s: koreader.mo is out of date for %d string(s), e.g. "%s" (run msgfmt)'
                            % (loc, len(stale), stale[0]))
    return failures


def main(plugin_root, _koreader_root=None):
    l10n = os.path.join(plugin_root, "l10n")
    if not os.path.isdir(l10n):
        print("  no l10n directory")
        return 2

    # A locale directory is one that holds any .po file.
    locale_dirs = sorted(
        d for d in glob.glob(os.path.join(l10n, "*"))
        if os.path.isdir(d) and glob.glob(os.path.join(d, "*.po"))
    )
    if not locale_dirs:
        print("  FAIL: no locale directories found -- the scan is broken")
        return 1

    failures = []
    for d in locale_dirs:
        loc = os.path.basename(d)
        po = os.path.join(d, "koreader.po")
        mo = os.path.join(d, "koreader.mo")

        # 1. The file must be named koreader.po -- anything else is never loaded.
        stray = [os.path.basename(p) for p in glob.glob(os.path.join(d, "*.po"))
                 if os.path.basename(p) != "koreader.po"]
        if stray:
            failures.append("%s: found %s -- KOReader only loads koreader.mo, so rename to "
                            "koreader.po" % (loc, ", ".join(stray)))
        if not os.path.isfile(po):
            failures.append("%s: no koreader.po (KOReader loads l10n/%s/koreader.mo)" % (loc, loc))
            continue

        # 2. A compiled koreader.mo must exist -- the .po is not what loads on the device.
        if not os.path.isfile(mo):
            failures.append("%s: no compiled koreader.mo (run msgfmt)" % loc)

        # 3. The header must carry a Plural-Forms KOReader can parse, or changeLang throws and the
        #    whole locale falls back to English for plugin-only strings.
        with open(po, encoding="utf-8", errors="replace") as fh:
            header = header_block(fh.read())
        if header is None:
            failures.append("%s: could not locate the catalogue header" % loc)
            continue
        if "Plural-Forms:" not in header:
            failures.append("%s: koreader.po has no Plural-Forms header -- KOReader's parse_headers "
                            "throws on a nil match and the locale silently falls back to English" % loc)
        elif not re.search(r"plural=.*;", header):
            failures.append("%s: Plural-Forms header has no `plural=...;` clause -- parse_headers "
                            "leaves the plural expression nil and throws" % loc)

    failures.extend(compiled_failures(locale_dirs))

    for f in failures:
        print("  [FAIL] %s" % f)
    if failures:
        print("\n  %d failed" % len(failures))
        return 1

    print("  %d locales: each has koreader.po + koreader.mo with a parseable Plural-Forms header"
          % len(locale_dirs))
    print("\n  %d passed, 0 failed" % (len(locale_dirs)))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(*sys.argv[1:3]))

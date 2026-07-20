# Changelog

Notable changes per release, from a user's point of view. Anything that only moved code around
is summarised rather than listed; the commit history has the detail.

The version number is set by the release workflow, which bumps the patch version on every push
to `main` — so the top section is the one about to ship.

## 1.0.40

### Fixed

**Sign-in and search failing with `HTTP Error: 307`.** The plugin only followed a redirect when
it pointed at a different host as a full absolute URL. Anything else — a relative `Location`, or
the same host over `https` instead of `http` — was refused and the raw status shown as an error.
Redirects are now resolved properly, `308` is understood, and a chain of several hops is followed
rather than only the first.

**Mirrors behind a browser check now say so.** Some servers answer the API with a "verifying your
browser" page instead of data. That produced a bare status code with nothing to act on. The
plugin now reports which server is refusing it and offers **Auto-discover base URL** alongside
Retry, since another mirror is the only thing that helps. Note this does not make such a mirror
usable — those checks cannot be passed by a plugin — but it stops the failure being a mystery.

**Redirect loops no longer hammer the server.** A mirror redirecting to itself was followed
repeatedly before giving up, taking several seconds and several requests. It now stops at the
first repeat.

**Cookies set during a redirect are returned**, so a mirror that only wants a cookie to be echoed
back now works.

**A download interrupted by a redirect no longer sends an empty request.** Retried sign-ins and
searches were re-sent without their body while still claiming to have one.

**The Telugu language name rendered as empty boxes** in the search-language list. No bundled
KOReader font covers Telugu script, so it now reads `Telugu`.

**Timeouts are shown in each language's own units.** The budget in the retry dialog and the
timeout settings were hard-coded to `15s` everywhere; Korean now shows `15초`, Japanese `15秒`,
Russian `15 с`.

### Added

**A search button on the results page.** Starting a different search meant closing the results,
finding the menu and beginning again. The magnifying glass in the title bar reopens the search
box, filled in with the query you already ran.

**Hold a result to download it.** Holding a row in the search results, or in the browse lists,
offers a download without opening the book first. It still asks before starting, since a download
counts against your quota.

**"Ask to open after download" can be switched off.** Found beside *Set download directory*. On
by default. With it off, a finished download shows a brief notice instead of a dialog, and Wi-Fi
is left alone — the "turn off Wi-Fi after closing this dialog" option belongs to the dialog, so
it does not act when no dialog appears.

### Changed

**The download prompt no longer repeats the filename.** It read
`"Long Title - Author.epub" downloaded successfully. Open it now?`; it now reads
`Book downloaded successfully. Open it now?`.

**`1lib.sk` is kept in the mirror list** with a note. It is behind a browser check at the moment
and auto-discovery skips it, but that is a setting the operator can change, and removing the entry
would mean nobody ever tried it again.

### Internal

Test harnesses covering the HTTP transport, the retry dialog, the gettext shim and font coverage
are now in the repository under `test/`, runnable with `./test/run.sh`. Two circular and
duplicated pieces of the code were untangled: `config` and `cache` no longer require each other,
and the twelve hand-written copies of the API header block are now one.

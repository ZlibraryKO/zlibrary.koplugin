# Harnesses

Regression tests for the parts of the plugin that are awkward to check by hand: the HTTP
transport, the retry dialog, the gettext shim, and the glyphs the UI asks fonts for. They run
offline against a scripted server, so they need no z-library account, no network, and no device.

```sh
./test/run.sh              # everything
./test/run.sh redirect     # only harnesses whose name matches
```

Exits non-zero if anything fails, so it works as a pre-push check.

## Requirements

A **built KOReader checkout**. The plugin targets KOReader's LuaJIT, which is Lua 5.1, and the
harnesses themselves use `loadstring` and `setfenv` to compile file-local functions out of the
source — neither exists in a system Lua 5.4, so running there produces failures that say nothing
about the plugin. The harnesses also borrow KOReader's LuaSocket for real URL parsing and its
bundled fonts for the glyph check.

Point `run.sh` at yours in whichever way suits. It takes the first that applies:

1. `KOREADER_DIR` in the environment, for a one-off:
   ```sh
   KOREADER_DIR=/path/to/koreader ./test/run.sh
   ```
2. `scripts/test-env.sh`, for a path you do not want to keep retyping:
   ```sh
   echo 'KOREADER_DIR="$HOME/src/koreader"' > scripts/test-env.sh
   ```
   `scripts/` is gitignored, so this stays on your machine and out of the repository. The file
   is sourced by `run.sh`, so it is shell, not a config format.
3. Failing both, it looks in `~/Documents/Dev/koreader-git`, `~/koreader`, and beside this
   repository.

If none of those find a build, `run.sh` says so and exits 2 rather than failing obscurely.

## What each one covers

| Harness | Covers |
| --- | --- |
| `redirect_resolve_harness.lua` | Which `Location` shapes resolve, and to what. Relative, root-relative, protocol-relative, same-host, cross-host, 301/302/303/307/308. Also that `real_url_base` — the signal that pins a new base URL — is set only for a genuine cross-host move. |
| `redirect_follow_harness.lua` | What `makeHttpRequest` does with them: multi-hop chains, POST body replay, method conversion per RFC, loop termination, cookie handling, and that `onRedirect` still owns mirror moves. |
| `bot_challenge_harness.lua` | Recognising a "verifying your browser" interstitial, and — as importantly — not mistaking a JSON API error, an nginx error page, or a book description for one. |
| `retry_message_harness.lua` | That the dialog classifies a failure from the raw error string, opens for the kinds it should, offers auto-discovery only where switching mirrors would help, and says something true and distinct for each. |
| `getplural_harness.lua` | That loading the plugin's catalogue leaves KOReader's own gettext globals as it found them. |
| `timeout_keys_harness.lua` | That every `operation_key` at a call site resolves to a real timeout getter. A typo yields no hint rather than an error, which is invisible at runtime. |
| `glyph_coverage_check.py` | That every non-ASCII codepoint the plugin can display — `\u{...}` escapes and literal UTF-8 alike — maps to a real glyph in some bundled font. Excludes U+FFF1–FFF3, which are `textboxwidget` control markers rather than glyphs. |

## Conventions

Each `*_harness.lua` is invoked as `luajit <harness> <plugin-root> <luasocket-src>` and each
`*_check.py` as `python3 <check> <plugin-root> <koreader-root>`. Drop a new file matching either
pattern into this directory and `run.sh` picks it up.

`support.lua` holds the shared pieces: the pass/fail reporter, the KOReader module stubs, and
`extract_function` / `extract_block`.

Those last two are the important convention. Several of the functions under test are file-local
and cannot be required, so the harnesses **pull them out of the source and compile them** rather
than working from a copy. A copied function keeps passing after the original changes, which is
the failure mode that matters most here — a green suite that is no longer testing the shipped
code.

## Why these exist

Each was written against a real bug, and each fails against the commit before its fix:

- Two users reported `HTTP Error: 307` on sign-in. Only absolute cross-host redirects were
  followed, so an ordinary `http` → `https` hop on the same host was refused.
- Fixing that introduced a worse bug: a mirror redirecting to itself was chased five times,
  taking seconds and five requests against a free service, where the old code failed in one.
- A POST replayed across a redirect sent an empty body while still advertising the original
  `Content-Length` — the server would have seen a blank sign-in with nothing in any log to say
  why.
- The api layer produced a correct, actionable error for a walled mirror and the dialog
  discarded it, telling users the failure was "temporary" when it was permanent. The redirect
  harnesses could not catch that: it lived one layer up, in `ui.lua`.
- Two icons pointed at codepoints no bundled font carries and drew as empty boxes. A third
  turned up when this check was widened to literal UTF-8: the Telugu language name in the
  search-language list, which no bundled font covers at all.
- A walled mirror was reported as a bare `HTTP Error: 513` instead of a message naming the host
  and pointing at another server.
- Loading the plugin's catalogue left KOReader's own gettext globals altered: its plural
  selector kept running the rule from the plugin's `.mo` for the rest of the session.

## Not covered

Known gaps, listed so the suite is not mistaken for more than it is:

- **A live mirror.** The network is stubbed throughout, so nothing here shows the plugin works
  against a real server. That still needs a device and an account.
- **`retry_on_stall`.** The retry-once-on-a-silent-server path in `makeHttpRequest` has no
  coverage; every guard in it could be deleted with the suite still green.
- **The redirect-target cache** in `config.lua` (`setCacheRealUrl`, `clearCacheRealUrlIfPinned`,
  the TTL). The harnesses stub it, so only the fact that pinning is *called* is checked, not
  that it stores or expires correctly.
- **A caller-supplied `options.source`.** Bodies are replayed correctly when passed as
  `options.body`; a caller passing a raw ltn12 source would still have it drained on the first
  attempt and send an empty body on a retry. Nothing currently does, and nothing stops it.
- **CI.** These do not run there, as the runner needs a built KOReader checkout.

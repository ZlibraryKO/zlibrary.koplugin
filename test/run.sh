#!/bin/sh
# Run every harness in this directory.
#
# These need KOReader's own LuaJIT. The plugin targets Lua 5.1 semantics, and the harnesses
# themselves use loadstring and setfenv to compile file-local functions out of the source --
# neither exists in a system Lua 5.4, so running there produces failures that say nothing
# about the plugin. Point KOREADER_DIR at a built KOReader checkout, or let this find one.
#
#   ./test/run.sh                    run everything
#   ./test/run.sh redirect           run harnesses whose name matches
#   KOREADER_DIR=/path ./test/run.sh use a specific checkout
#
# Exits non-zero if any harness fails, so it is usable as a pre-push check.

set -eu

PLUGIN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FILTER=${1:-}

# ---------------------------------------------------------------- locate KOReader
# Machine-local settings first. scripts/ is gitignored, so it is the place for a path that
# belongs to one machine and has no business being committed. The file is sourced, so it can
# set anything, but KOREADER_DIR is the only thing read here.
if [ -z "${KOREADER_DIR:-}" ] && [ -f "$PLUGIN_DIR/scripts/test-env.sh" ]; then
    # shellcheck source=/dev/null
    . "$PLUGIN_DIR/scripts/test-env.sh"
fi

if [ -z "${KOREADER_DIR:-}" ]; then
    for candidate in \
        "${HOME:-}/Documents/Dev/koreader-git" \
        "${HOME:-}/koreader" \
        "$PLUGIN_DIR/../koreader-git" \
        "$PLUGIN_DIR/../koreader" \
        "$PLUGIN_DIR/../.."
    do
        if [ -d "$candidate/base/build" ]; then
            KOREADER_DIR=$candidate
            break
        fi
    done
fi

if [ -z "${KOREADER_DIR:-}" ] || [ ! -d "$KOREADER_DIR/base/build" ]; then
    cat >&2 <<EOF
Could not find a built KOReader checkout.

These harnesses run against KOReader's LuaJIT and its bundled LuaSocket and fonts, so they
need one. Clone and build KOReader, then point this at it in any of these ways:

    echo 'KOREADER_DIR=/path/to/koreader' > scripts/test-env.sh   # local, not committed
    KOREADER_DIR=/path/to/koreader ./test/run.sh                  # one-off
    ...or place the checkout beside this repository.
EOF
    exit 2
fi

LUAJIT=$(find "$KOREADER_DIR/base/build" -maxdepth 2 -name luajit -type f -perm -u+x 2>/dev/null | head -1)
LUASOCKET=$(find "$KOREADER_DIR/base/build" -maxdepth 5 -type d -path '*luasocket/source/src' 2>/dev/null | head -1)

if [ -z "$LUAJIT" ]; then
    echo "No luajit under $KOREADER_DIR/base/build -- is the checkout built?" >&2
    exit 2
fi
# base/build may hold several target triples, including cross-compiled device builds that
# cannot execute here. Take the first that actually runs.
if ! "$LUAJIT" -e 'os.exit(0)' >/dev/null 2>&1; then
    LUAJIT=$(find "$KOREADER_DIR/base/build" -maxdepth 2 -name luajit -type f -perm -u+x 2>/dev/null \
        | while read -r candidate; do
              if "$candidate" -e 'os.exit(0)' >/dev/null 2>&1; then echo "$candidate"; break; fi
          done)
    if [ -z "$LUAJIT" ]; then
        echo "No runnable luajit under $KOREADER_DIR/base/build (device build only?)" >&2
        exit 2
    fi
fi
if [ -z "$LUASOCKET" ]; then
    echo "No LuaSocket source under $KOREADER_DIR/base/build -- is the checkout built?" >&2
    exit 2
fi

echo "  koreader:  $KOREADER_DIR"
echo "  luajit:    $LUAJIT"
echo ""

failed=0
ran=0

# ---------------------------------------------------------------- syntax first
# A syntax error anywhere makes every behavioural result meaningless, so check it up front.
#
# The failures are collected in a file rather than a variable: the loop reading find's output
# runs in a subshell, so a flag set inside it is discarded when the pipeline ends. An earlier
# version did exactly that and reported "clean" directly underneath the file it had just
# printed a FAIL for.
if [ -z "$FILTER" ]; then
    printf '== lua syntax ==\n'
    syntax_log=$(mktemp)
    find "$PLUGIN_DIR" -name '*.lua' ! -name 'zlibrary_credentials.lua' ! -path '*/test/*' \
        | sort | while read -r f; do
            # The path is passed as data. Building Lua source around it meant a directory
            # containing an apostrophe terminated the string literal and every file in the repo
            # was reported broken.
            ZL_FILE="$f" "$LUAJIT" -e 'local p = os.getenv("ZL_FILE") assert(loadfile(p))' \
                >/dev/null 2>&1 || echo "$f" >> "$syntax_log"
        done
    if [ -s "$syntax_log" ]; then
        while read -r f; do echo "  FAIL $f"; done < "$syntax_log"
        failed=$((failed + 1))
        ran=$((ran + 1))
    else
        echo "  clean"
    fi
    rm -f "$syntax_log"
    echo ""
fi

# ---------------------------------------------------------------- harnesses

for harness in "$PLUGIN_DIR"/test/*_harness.lua; do
    [ -e "$harness" ] || continue
    name=$(basename "$harness" .lua)
    case "$name" in
        *"$FILTER"*) ;;
        *) continue ;;
    esac
    ran=$((ran + 1))
    printf '== %s ==\n' "$name"
    if "$LUAJIT" "$harness" "$PLUGIN_DIR" "$LUASOCKET"; then
        :
    else
        failed=$((failed + 1))
    fi
    echo ""
done

have_python3=0
command -v python3 >/dev/null 2>&1 && have_python3=1

for checker in "$PLUGIN_DIR"/test/*_check.py; do
    [ -e "$checker" ] || continue
    if [ "$have_python3" -eq 0 ]; then
        printf '== %s ==\n  SKIP: python3 not found\n\n' "$(basename "$checker" .py)"
        continue
    fi
    name=$(basename "$checker" .py)
    case "$name" in
        *"$FILTER"*) ;;
        *) continue ;;
    esac
    ran=$((ran + 1))
    printf '== %s ==\n' "$name"
    if python3 "$checker" "$PLUGIN_DIR" "$KOREADER_DIR"; then
        :
    else
        failed=$((failed + 1))
    fi
    echo ""
done

if [ "$ran" -eq 0 ]; then
    echo "No harness matched '${FILTER}'." >&2
    exit 2
fi

if [ "$failed" -eq 0 ]; then
    echo "All $ran harnesses passed."
else
    echo "$failed of $ran harnesses FAILED." >&2
fi
exit $([ "$failed" -eq 0 ] && echo 0 || echo 1)

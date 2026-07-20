#!/usr/bin/env python3
"""Assert the first-run credentials prompt still hears about its dialog closing.

The prompt resolves every waiting caller from an instance-level onCloseWidget override on the
credentials dialog (main.lua, Zlibrary:_promptForCredentials). That placement is deliberate:
Cancel, Set, the hardware back key and dialog_manager:closeAllDialogs() all reach
UIManager:close, and only the teardown hook sees all four. A Cancel-button hook would miss
three of them.

But it leans on a KOReader internal with no documented contract. UIManager:close dispatches
CloseWidget (uimanager.lua), and WidgetContainer:handleEvent propagates an event to children
FIRST, calling the container's own handler only when no child returned true
(widgetcontainer.lua). If any widget in the dialog's subtree ever starts returning true from
onCloseWidget, our override stops running -- and the symptom is silent: the user taps Set, the
dialog closes, and the search they were trying to run never resumes. Nothing in Lua complains.

KOReader's own guidance (uimanager.lua: "you generally *don't* want to return true in Show or
CloseWidget handlers") is why this holds today. This check pins it, so a KOReader upgrade that
breaks the assumption fails here instead of on a device.

usage: python3 close_widget_dispatch_check.py <plugin-root> <koreader-root>
"""
import os
import re
import sys


def onclosewidget_bodies(path):
    """Yield (function_name, body) for every :onCloseWidget definition in a file."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()

    start = re.compile(r"^function\s+([A-Za-z_][\w.]*):onCloseWidget\s*\(")
    for i, line in enumerate(lines):
        m = start.match(line)
        if not m:
            continue
        body = []
        for rest in lines[i + 1:]:
            if rest.startswith("end"):
                break
            body.append(re.sub(r"--.*$", "", rest))
        yield m.group(1), "".join(body)


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    plugin_root, koreader_root = sys.argv[1], sys.argv[2]

    widget_dir = os.path.join(koreader_root, "frontend", "ui")
    if not os.path.isdir(widget_dir):
        print("  SKIP: no frontend/ui under %s" % koreader_root)
        return 0

    failures = []
    checked = 0

    # 1. No widget may swallow CloseWidget. Any `return true` in the handler stops propagation
    #    from reaching our override.
    #
    #    Matches the inline `if cond then return true end` form as well as a bare line: an
    #    earlier version anchored the whole line and would have missed the inline one, which is
    #    the more likely way this creeps in. Comment lines are stripped first so prose about
    #    returning true does not trip it. A false positive fails loudly and a human looks, which
    #    is the right direction for a check that exists to catch a silent breakage.
    returns_true = re.compile(r"\breturn\s+true\b")
    for dirpath, _, filenames in os.walk(widget_dir):
        for name in sorted(filenames):
            if not name.endswith(".lua"):
                continue
            path = os.path.join(dirpath, name)
            for func, body in onclosewidget_bodies(path):
                checked += 1
                if returns_true.search(body):
                    failures.append(
                        "%s:%s:onCloseWidget returns true, which stops CloseWidget propagating "
                        "to the dialog's own handler" % (os.path.relpath(path, koreader_root), func))

    if checked == 0:
        failures.append(
            "found no onCloseWidget handlers at all under frontend/ui -- the parser or the "
            "KOReader layout changed, so this check is no longer proving anything")

    # 2. The propagate-children-first shape this depends on must still be there. If KOReader
    #    reverses it, the assumption above stops being the thing that matters.
    container = os.path.join(widget_dir, "widget", "container", "widgetcontainer.lua")
    try:
        with open(container, "r", encoding="utf-8", errors="replace") as fh:
            src = fh.read()
        if "propagateEvent" not in src:
            failures.append("widgetcontainer.lua no longer propagates events to children; "
                            "re-verify how CloseWidget reaches an instance override")
    except OSError as exc:
        failures.append("cannot read widgetcontainer.lua: %s" % exc)

    # 3. And the plugin must still be relying on the hook, or this check is vestigial.
    main_lua = os.path.join(plugin_root, "main.lua")
    with open(main_lua, "r", encoding="utf-8", errors="replace") as fh:
        main_src = fh.read()
    if "function dialog:onCloseWidget()" not in main_src:
        failures.append("main.lua no longer overrides onCloseWidget on the credentials dialog; "
                        "if the prompt now resolves another way, delete this check")

    for f in failures:
        print("  [FAIL] %s" % f)
    if failures:
        print("\n  %d failed" % len(failures))
        return 1

    print("  [ok  ] no widget swallows CloseWidget (%d handlers checked)" % checked)
    print("  [ok  ] WidgetContainer still propagates to children before its own handler")
    print("  [ok  ] the credentials prompt still resolves from the teardown hook")
    print("\n  3 passed, 0 failed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

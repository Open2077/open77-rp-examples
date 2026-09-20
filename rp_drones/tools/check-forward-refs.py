#!/usr/bin/env python3
"""Find Lua forward references that `luac -p` cannot see.

WHY THIS EXISTS. `local function helper() end` binds `helper` at the line it
appears on. A call to `helper()` written ABOVE that line does not resolve to it:
it compiles as a lookup of the GLOBAL `helper`, which is nil, and the file
parses perfectly. `luac -p` reports nothing. The failure arrives at run time, on
the first call, as:

    attempt to call a nil value (global 'helper')

That has bitten this resource twice. The second time it killed an
eighty-eight-drone show outright, in front of an audience, after every syntax
check had passed. Syntax checking is not the same as checking the code, and
this is the gap between them.

THE FIX for a real forward reference is a forward DECLARATION:

    local helper                 -- declared here, visible below
    local function caller() return helper() end
    function helper() end        -- assigns the local, not a global

which this checker understands and accepts.

USAGE
    python tools/check-forward-refs.py                 # every .lua in the resource
    python tools/check-forward-refs.py server/main.lua

Exits non-zero when it finds one, so it can sit in front of a deploy.

WHAT IT CANNOT DO. It is a line-ordering check over a single file, not a Lua
parser: it does not model scope, blocks or upvalues, and it will not notice a
name shadowed in an inner block. It is deliberately noisy in one direction --
it would rather name something harmless than miss the class of bug it was
written for.
"""

from __future__ import annotations

import os
import re
import sys

# `local function name(`
LOCAL_FUNCTION = re.compile(r"^\s*local\s+function\s+([A-Za-z_]\w*)\s*\(")
# `function name(` -- assigns whatever `name` resolves to, local or global
PLAIN_FUNCTION = re.compile(r"^\s*function\s+([A-Za-z_]\w*)\s*\(")
# `local name` / `local a, b` with no `=` and no `function`: a forward declaration
FORWARD_DECL = re.compile(r"^\s*local\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*$")
# `local name = ...`
LOCAL_ASSIGN = re.compile(r"^\s*local\s+([A-Za-z_]\w*)\s*=")


def strip_noise(line: str) -> str:
    """Remove string literals and comments, so neither can fake a call.

    STRINGS FIRST, and that order is load-bearing. Stripping comments first
    truncates any line whose STRING contains a Lua comment marker, and what is
    left of it then looks like code. This checker's own first run reported a
    call to `free` in a line whose format string ended in "... is free (%s
    flying) -- ", because the marker inside the message had eaten the closing
    quote. A tool that cries wolf gets switched off, which is worse than not
    having one.
    """
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    line = re.sub(r"'(?:[^'\\]|\\.)*'", "''", line)
    line = re.sub(r"--\[\[.*?\]\]", " ", line)
    line = re.sub(r"--.*$", "", line)
    return line


def scan(path: str) -> list[str]:
    with open(path, encoding="utf-8") as handle:
        raw = handle.readlines()
    code = [strip_noise(line) for line in raw]

    defined_at: dict[str, int] = {}
    declared_at: dict[str, int] = {}

    for index, line in enumerate(code):
        match = LOCAL_FUNCTION.match(line) or PLAIN_FUNCTION.match(line)
        if match and match.group(1) not in defined_at:
            defined_at[match.group(1)] = index
        match = LOCAL_ASSIGN.match(line)
        if match and match.group(1) not in defined_at:
            defined_at[match.group(1)] = index
        match = FORWARD_DECL.match(line)
        if match:
            for name in (part.strip() for part in match.group(1).split(",")):
                declared_at.setdefault(name, index)

    problems: list[str] = []
    for name, definition in sorted(defined_at.items(), key=lambda item: item[1]):
        # A forward declaration above the call site is the supported pattern.
        declaration = declared_at.get(name)
        visible_from = declaration if declaration is not None else definition
        call = re.compile(r"(?<![\w.:])" + re.escape(name) + r"\s*\(")
        for index, line in enumerate(code):
            if index >= visible_from:
                continue
            # The definition line itself is not a call.
            if LOCAL_FUNCTION.match(line) or PLAIN_FUNCTION.match(line):
                continue
            if call.search(line):
                problems.append(
                    "%s:%d: calls `%s` but it is only defined at line %d -- "
                    "this resolves as a global and is nil at run time; add "
                    "`local %s` above the call, or move the definition up"
                    % (path, index + 1, name, definition + 1, name)
                )
    return problems


def main(argv: list[str]) -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if argv:
        targets = [
            path if os.path.isabs(path) else os.path.join(root, path) for path in argv
        ]
    else:
        targets = []
        for folder, _, files in os.walk(root):
            if "tools" in folder.split(os.sep):
                continue
            targets += [
                os.path.join(folder, name) for name in sorted(files) if name.endswith(".lua")
            ]

    problems: list[str] = []
    for path in targets:
        if not os.path.isfile(path):
            print("no such file: %s" % path, file=sys.stderr)
            return 2
        problems += scan(path)

    if problems:
        print("forward references that luac -p cannot see:\n")
        for problem in problems:
            print("  " + problem)
        print("\n%d found." % len(problems))
        return 1

    print("checked %d file(s): no forward references." % len(targets))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Run Diag.lua for real, under stubbed Roblox globals and a virtual clock.

    Tests/check_diag_runtime.py

Every other check in this folder either reads Lua source or reads captured artifacts.
Neither can answer the one question that matters about a recorder: when a run goes
wrong, does it produce the right verdict? This one executes the actual file.

The luau CLI has no `io` library and gives each file its own globals, so the harness
and the two production files are concatenated into a single chunk first. The
production sources are spliced in VERBATIM -- no rewriting, no test-only variants --
because a harness that edits the code under test proves nothing about the code that
ships.

Requires: brew install luau
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent


def wrap(name: str) -> str:
    """Wrap a production file so its top-level `return` stays legal inside the chunk."""
    source = (ROOT / name).read_text(encoding="utf-8")
    return f"local {name.split('.')[0]} = (function()\n{source}\nend)()"


def main() -> int:
    if not shutil.which("luau"):
        print("luau not found. Install it with:  brew install luau", file=sys.stderr)
        return 127

    harness = (ROOT / "Tests" / "check_diag_runtime.lua").read_text(encoding="utf-8")
    assert "--@@INJECT_CONFIG@@" in harness and "--@@INJECT_DIAG@@" in harness
    harness = harness.replace("--@@INJECT_CONFIG@@", wrap("Config.lua"))
    harness = harness.replace("--@@INJECT_DIAG@@", wrap("Diag.lua"))

    with tempfile.TemporaryDirectory() as workdir:
        combined = pathlib.Path(workdir) / "diag_runtime.lua"
        combined.write_text(harness, encoding="utf-8")
        result = subprocess.run(["luau", str(combined)], capture_output=True, text=True)

    # The harness hands its in-memory filesystem back on stdout. Strip it by default;
    # with --emit, write it out so the analyzer can be exercised against real recorder
    # output instead of a sample hand-written to match what the analyzer expects.
    emit_dir = None
    if "--emit" in sys.argv:
        emit_dir = pathlib.Path(sys.argv[sys.argv.index("--emit") + 1]).expanduser()

    reported = None
    current, buffer = None, []
    for line in result.stdout.splitlines():
        if line.startswith("@@RESULT "):
            reported = int(line.split()[1])
        elif line.startswith("@@FILE "):
            current, buffer = line[len("@@FILE "):], []
        elif line.startswith("@@DATA ") and current is not None:
            buffer.append(line[len("@@DATA "):])
        elif line == "@@END" and current is not None:
            if emit_dir:
                target = emit_dir / current
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("\n".join(buffer).rstrip("\n") + "\n", encoding="utf-8")
                print(f"  emitted {target}")
            current = None
        else:
            print(line)
    if result.stderr.strip():
        # A Luau runtime error names a line in the assembled chunk, which is useless on
        # its own; say so rather than letting it read as a line in a real file.
        sys.stderr.write(result.stderr)
        sys.stderr.write("\n(line numbers above refer to the assembled harness, "
                         "not to Config.lua or Diag.lua)\n")

    if reported is None:
        # The harness did not reach its own last line, so the checks that printed "ok"
        # above prove nothing about the ones that never ran.
        print("\n[DiagRuntime] the harness did not run to completion", file=sys.stderr)
        return result.returncode or 1
    return 1 if reported else 0


if __name__ == "__main__":
    sys.exit(main())

# /// script
# requires-python = ">=3.10"
# dependencies = ["tiktoken==0.14.0"]
# ///
"""Check committed agent guidance, recursively, including monorepo projects.

Run: uv run --no-config --script scripts/check-agent-guidance.py [--ref HEAD]
The 400-token budget uses the org's o200k_base x 1.5 convention, rounded up.
Missing guidance is fine; a CLAUDE.md needs a tracked sibling AGENTS.md.
"""

import argparse
import json
import os
import subprocess
import sys

LIMIT = 400
MAX_BYTES = 1_000_000
NAMES = {"agents.md": "AGENTS.md", "claude.md": "CLAUDE.md"}
REASON = """Keep repository instructions small and specific to this repository.
Strongly prefer user-level agent instructions for rules likely to apply to many
repositories. As a guiding heuristic, if a rule is not important enough for
user-level instructions, consider not writing it down anywhere; genuine
repository-specific constraints are the exception.
Documentation must not purport to describe the current code, repository layout,
or structure. Read the code instead. Record reasons for decisions and important
constraints that the code cannot explain. Plans and specs are dated snapshots
of intent, never authoritative descriptions of the current system: later user
instructions and discoveries can supersede them. Do not maintain them as a
second source of truth for the implementation.
Move broadly applicable rules to user-level instructions, remove code narration,
and keep only essential repository-specific guidance in AGENTS.md.
CLAUDE.md must contain only @AGENTS.md (an optional final newline is allowed).
There are no baseline or exemption files for this check."""


def git(*args: str) -> bytes:
    return subprocess.check_output(
        ["git", *args], env={**os.environ, "GIT_NO_REPLACE_OBJECTS": "1"}
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default="HEAD", help="committed revision to check (default: HEAD)")
    args = parser.parse_args()
    tree = git("rev-parse", "--verify", "--end-of-options", f"{args.ref}^{{tree}}")
    rows = git("ls-tree", "-r", "-z", "--full-tree", tree.decode().strip())
    files = {}
    for row in rows.split(b"\0"):
        if not row:
            continue
        metadata, path = row.split(b"\t", 1)
        mode, kind, oid = metadata.split()
        name = path.rsplit(b"/", 1)[-1].lower()
        if name in (b"agents.md", b"claude.md"):
            files[path] = (mode, kind, oid)

    failures = 0

    def fail(path: bytes, message: str) -> None:
        nonlocal failures
        failures += 1
        # Quote control characters so a path cannot forge log lines or annotations.
        label = json.dumps(os.fsdecode(path), ensure_ascii=True)
        print(f"[FAIL] {label}: {message}")

    encoder = None
    for path, (mode, kind, oid) in sorted(files.items()):
        name = path.rsplit(b"/", 1)[-1].decode("ascii")
        expected = NAMES[name.lower()]
        if name != expected:
            fail(path, f"use the canonical filename {expected}")
        if mode not in (b"100644", b"100755") or kind != b"blob":
            fail(path, "guidance must be a regular tracked file, not a symlink or submodule")
            continue
        size = int(git("cat-file", "-s", oid.decode()))
        if size > MAX_BYTES:
            fail(path, "guidance exceeds 1 MB; shorten it before measuring tokens")
            continue
        data = git("cat-file", "blob", oid.decode())
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            fail(path, "guidance must be UTF-8 text")
            continue
        if expected == "CLAUDE.md":
            if text.replace("\r\n", "\n") not in ("@AGENTS.md", "@AGENTS.md\n"):
                fail(path, "must contain only @AGENTS.md, with an optional final newline")
            sibling = path.rsplit(b"/", 1)[0] + b"/AGENTS.md" if b"/" in path else b"AGENTS.md"
            if sibling not in files:
                fail(path, "the imported sibling AGENTS.md must be tracked")
            continue
        if encoder is None:
            import tiktoken

            encoder = tiktoken.get_encoding("o200k_base")
        raw = len(encoder.encode_ordinary(text))
        count = (raw * 3 + 1) // 2
        label = json.dumps(os.fsdecode(path), ensure_ascii=True)
        print(f"agent-guidance: {label}: {count}/{LIMIT} tokens")
        if count > LIMIT:
            fail(path, f"{count} tokens exceeds {LIMIT} (tiktoken o200k_base x 1.5, rounded up)")

    print(f"agent-guidance: {len(files)} guidance file(s) checked recursively, {failures} failure(s)")
    if failures:
        print("\n" + REASON)
        return 1
    print("agent-guidance: ok")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"agent-guidance: could not complete the check: {error}", file=sys.stderr)
        sys.exit(2)

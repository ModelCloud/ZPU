#!/usr/bin/env python3
# Copyright 2026 ModelCloud
# SPDX-License-Identifier: Apache-2.0

"""Apply Apache-2.0 SPDX headers to first-party repository text files.

The script intentionally skips formats that do not permit comments (JSON) and
third-party/generated Vulkan registry snapshots under api/registry/. Existing
SPDX headers are never replaced.
"""

from __future__ import annotations

import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
COPYRIGHT = "Copyright 2026 ModelCloud"
SPDX = "SPDX-License-Identifier: Apache-2.0"

LINE_HASH = {".sh", ".py", ".yml", ".yaml", ".toml", ".gitignore", ".gitattributes"}
LINE_SLASH = {".zig", ".zon", ".c", ".h", ".cc", ".cpp", ".hpp", ".rs", ".js", ".ts"}
HTML_COMMENT = {".md", ".html", ".svg"}
XML_COMMENT = {".xml"}
PLAIN_HASH_NAMES = {"Smolfile", "Dockerfile", "Makefile"}
SKIP_NAMES = {"LICENSE", "NOTICE"}
SKIP_PREFIXES = ("api/registry/", ".git/")


def tracked_files() -> list[pathlib.Path]:
    output = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT)
    return [ROOT / p.decode() for p in output.split(b"\0") if p]


def header_for(path: pathlib.Path) -> str | None:
    rel = path.relative_to(ROOT).as_posix()
    if path.name in SKIP_NAMES or rel.startswith(SKIP_PREFIXES):
        return None
    suffix = path.suffix.lower()
    if suffix == ".json":
        return None
    if suffix in LINE_HASH or path.name in PLAIN_HASH_NAMES:
        return f"# {COPYRIGHT}\n# {SPDX}\n"
    if suffix in LINE_SLASH:
        return f"// {COPYRIGHT}\n// {SPDX}\n"
    if suffix in HTML_COMMENT:
        return f"<!-- {COPYRIGHT} -->\n<!-- {SPDX} -->\n"
    if suffix in XML_COMMENT:
        return f"<!-- {COPYRIGHT} -->\n<!-- {SPDX} -->\n"
    return None


def insert_header(text: str, header: str, path: pathlib.Path) -> str:
    if SPDX in text:
        return text

    # Shebangs must remain byte zero / first line.
    if text.startswith("#!"):
        first, sep, rest = text.partition("\n")
        return first + sep + header + "\n" + rest

    # XML declarations must remain first when present.
    if path.suffix.lower() == ".xml" and text.startswith("<?xml"):
        first, sep, rest = text.partition("\n")
        return first + sep + header + "\n" + rest

    return header + "\n" + text


def main() -> int:
    changed: list[str] = []
    skipped: list[str] = []

    for path in tracked_files():
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT).as_posix()
        header = header_for(path)
        if header is None:
            skipped.append(rel)
            continue
        try:
            raw = path.read_bytes()
            text = raw.decode("utf-8")
        except (UnicodeDecodeError, OSError):
            skipped.append(rel)
            continue
        new_text = insert_header(text, header, path)
        if new_text != text:
            path.write_text(new_text, encoding="utf-8", newline="")
            changed.append(rel)

    print(f"license headers: changed={len(changed)} skipped={len(skipped)}")
    for rel in changed:
        print(f"  + {rel}")
    if skipped:
        print("Skipped non-commentable, generated, third-party, binary, or unknown-format files:")
        for rel in skipped:
            print(f"  - {rel}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

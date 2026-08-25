#!/usr/bin/env python3
import pathlib
import sys
import tomllib

path = pathlib.Path(sys.argv[1])
try:
    document = tomllib.loads(path.read_text())
except (OSError, tomllib.TOMLDecodeError) as error:
    raise SystemExit(f"invalid Smolfile {path}: {error}")

forbidden = {"image", "network", "net"}

def visit(value, location=""):
    if not isinstance(value, dict):
        return
    for key, child in value.items():
        qualified = f"{location}.{key}" if location else key
        if key.lower() in forbidden:
            raise SystemExit(f"Smolfile may not define launcher-owned field: {qualified}")
        visit(child, qualified)

visit(document)

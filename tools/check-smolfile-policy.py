#!/usr/bin/env python3
import pathlib
import sys

try:
    import tomllib
    decode = tomllib.loads
    DecodeError = tomllib.TOMLDecodeError
except ImportError:
    import toml
    decode = toml.loads
    DecodeError = toml.decoder.TomlDecodeError

if len(sys.argv) != 2:
    raise SystemExit("usage: check-smolfile-policy.py <Smolfile>")

path = pathlib.Path(sys.argv[1])
if not path.exists():
    raise SystemExit(f"Smolfile path does not exist: {path}")
if not path.is_file():
    raise SystemExit(f"Smolfile path is not a regular file: {path}")
try:
    document = decode(path.read_text())
except (OSError, UnicodeError, DecodeError) as error:
    raise SystemExit(f"invalid Smolfile {path}: {error}")

forbidden = {"image", "network", "net"}

def visit(value, location=""):
    if isinstance(value, list):
        for index, child in enumerate(value):
            visit(child, f"{location}[{index}]")
        return
    if isinstance(value, dict):
        for key, child in value.items():
            qualified = f"{location}.{key}" if location else key
            if key.lower() in forbidden:
                raise SystemExit(f"Smolfile may not define launcher-owned field: {qualified}")
            visit(child, qualified)

visit(document)

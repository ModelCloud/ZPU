#!/usr/bin/env python3
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

"""Report or gate ZPU's Metal ABI coverage against an Apple SDK.

Linux can validate the checked-in native ABI and mapping manifest, but only an
Apple SDK supplies the authoritative public Metal headers. On macOS, pass an
SDK root (or let xcrun resolve macosx) to inventory protocols, classes,
enumerations, structs, C entry points, and Objective-C selectors. A strict
run fails closed until the manifest explicitly reaches complete coverage.
"""

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "api/metal-abi.json"
SOURCE_ROOT = ROOT / "src/metal"


class InventoryError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise InventoryError(message)


def load_manifest():
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise InventoryError(f"cannot read api/metal-abi.json: {error}") from error
    require(data.get("schema_version") == 1, "unsupported Metal ABI manifest schema")
    coverage = data.get("coverage", {})
    require(coverage.get("status") == "wip", "Metal coverage status must remain explicit")
    policy = data.get("mapping_policy", {})
    direct = policy.get("direct_vulkan", [])
    native = policy.get("native_metal", [])
    require(direct and native, "mapping policy must contain direct and native entries")
    require(not set(direct) & set(native), "mapping policy entry appears in both direct and native sets")
    implemented = data.get("implemented_native_abi", [])
    missing = data.get("known_unimplemented_surface", [])
    require(implemented and missing, "WIP manifest must name implemented and missing surface")
    require(len(implemented) == len(set(implemented)), "duplicate implemented Metal ABI entry")
    require(len(missing) == len(set(missing)), "duplicate unimplemented Metal ABI entry")
    return data


def sdk_headers(sdk):
    if sdk is None:
        xcrun = shutil.which("xcrun")
        if not xcrun:
            return None
        try:
            sdk = subprocess.check_output(
                [xcrun, "--sdk", "macosx", "--show-sdk-path"], text=True, stderr=subprocess.DEVNULL
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            return None
    root = pathlib.Path(sdk)
    candidates = [
        root / "System/Library/Frameworks/Metal.framework/Headers",
        root / "Metal.framework/Headers",
        root,
    ]
    for candidate in candidates:
        if (candidate / "Metal.h").is_file():
            return candidate
    raise InventoryError(f"Metal.framework/Headers/Metal.h not found below {root}")


def inventory(headers):
    text = "\n".join(path.read_text(encoding="utf-8", errors="ignore") for path in sorted(headers.rglob("*.h")))
    names = set(re.findall(r"@(?:protocol|interface)\s+(MTL(?:4)?[A-Za-z0-9_]+)", text))
    names.update(re.findall(r"}\s*(MTL(?:4)?[A-Za-z0-9_]+)\s*;", text))
    selectors = set(re.findall(r"^[ \t]*[-+]\s*\([^)]*\)\s*([A-Za-z_][A-Za-z0-9_]*)", text, re.MULTILINE))
    c_functions = set(re.findall(r"\b(MTL[A-Za-z0-9_]+)\s*\([^;{}]*\)\s*;", text))
    return {
        "headers": len(list(headers.rglob("*.h"))),
        "types": len(names),
        "selectors": len(selectors),
        "c_functions": len(c_functions),
        "has_metal4": "MTL4" in text,
    }


def source_symbol_count(manifest):
    source = "\n".join(path.read_text(encoding="utf-8") for path in SOURCE_ROOT.rglob("*.zig"))
    symbols = {entry.rsplit(".", 1)[-1] for entry in manifest["implemented_native_abi"]}
    return sum(1 for symbol in symbols if re.search(rf"\b{re.escape(symbol)}\b", source))


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", type=pathlib.Path, help="Apple SDK root or Metal.framework/Headers path")
    parser.add_argument("--require-complete", action="store_true", help="fail unless SDK-backed coverage is complete")
    args = parser.parse_args(argv)
    try:
        manifest = load_manifest()
        source_count = source_symbol_count(manifest)
        require(source_count == len(manifest["implemented_native_abi"]), "manifest contains an unimplemented native ABI symbol")
        headers = sdk_headers(args.sdk)
        if headers is None:
            if args.require_complete:
                raise InventoryError("Apple SDK unavailable; run strict coverage on macOS with the target SDK")
            print(f"metal-abi: SDK unavailable; native manifest validated ({source_count} implemented entries)")
            print("metal-abi: coverage remains WIP and is not claimed complete")
            return 0
        report = inventory(headers)
        print(
            "metal-abi: SDK headers={headers} types={types} selectors={selectors} "
            "c_functions={c_functions} metal4={has_metal4}".format(**report)
        )
        if args.require_complete and (not manifest["coverage"].get("complete") or manifest["known_unimplemented_surface"]):
            raise InventoryError("manifest still has known unimplemented Metal surface")
        print("metal-abi: SDK inventory completed; semantic coverage remains manifest-driven")
        return 0
    except InventoryError as error:
        print(f"metal-abi: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

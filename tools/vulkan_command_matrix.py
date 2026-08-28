#!/usr/bin/env python3
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

"""Generate the strict Vulkan core command implementation matrix."""

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "api/vulkan-1.4.360.json"
IMPLEMENTATION = ROOT / "api/command-implementation.json"
DRIVER = ROOT / "src/vulkan/driver.zig"
OUTPUT = ROOT / "docs/vulkan-command-matrix.md"
HEADER = "<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->\n<!-- SPDX-License-Identifier: Apache-2.0 -->\n\n"


def words(name: str) -> str:
    value = name[2:] if name.startswith("vk") else name
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", value)
    value = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", value)
    return value.replace("  ", " ")


def description(command: str) -> str:
    stem = command[2:]
    patterns = (
        ("Cmd", "Record {value} in a command buffer."),
        ("Create", "Create {value}."),
        ("Destroy", "Destroy {value}."),
        ("Enumerate", "Enumerate {value}."),
        ("Get", "Query {value}."),
        ("Allocate", "Allocate {value}."),
        ("Free", "Free {value}."),
        ("Bind", "Bind {value}."),
        ("Begin", "Begin {value}."),
        ("End", "End {value}."),
        ("Reset", "Reset {value}."),
        ("Wait", "Wait for {value}."),
        ("Signal", "Signal {value}."),
        ("Map", "Map {value}."),
        ("Unmap", "Unmap {value}."),
        ("Flush", "Flush {value}."),
        ("Invalidate", "Invalidate {value}."),
        ("Update", "Update {value}."),
        ("Merge", "Merge {value}."),
        ("Queue", "Perform {value} on a queue."),
        ("Device", "Perform the device operation {value}."),
        ("Set", "Set {value}."),
        ("Copy", "Copy {value}."),
        ("Transition", "Transition {value}."),
    )
    for prefix, template in patterns:
        if stem.startswith(prefix):
            return template.format(value=words("vk" + stem[len(prefix):]).lower())
    return f"Perform {words(command).lower()}."


def render() -> str:
    inventory = json.loads(INVENTORY.read_text())
    policy = json.loads(IMPLEMENTATION.read_text())
    if policy["target_api_version"] != inventory["target_api_version"]:
        raise SystemExit("command implementation target does not match inventory")
    introduced = inventory["mandatory_cumulative_core"]["introduced_by_version"]
    all_commands = set(inventory["mandatory_cumulative_core"]["all_through_1_4"]["commands"])
    implemented = policy["implemented_commands"]
    unknown = sorted(set(implemented) - all_commands)
    if unknown:
        raise SystemExit("unknown implemented commands: " + ", ".join(unknown))
    source = DRIVER.read_text()
    dispatched = set(re.findall(r'"(vk[A-Z][A-Za-z0-9]+)"', source)) & all_commands
    rows = []
    for version, group in introduced.items():
        short = version.removeprefix("VK_VERSION_").replace("_", ".")
        for command in sorted(group["commands"]):
            rows.append(
                f"| {short} | `{command}` | {description(command)} | "
                f"{'Yes' if command in dispatched else 'No'} | "
                f"{'Yes' if command in implemented else 'No'} |"
            )
    return HEADER + "\n".join((
        "# Vulkan 1.0–1.4 core command matrix",
        "",
        f"Generated from the pinned Vulkan {inventory['target_api_version']} inventory. Do not edit by hand; run `python3 tools/vulkan_command_matrix.py --write`.",
        "",
        "`Dispatched` means a command name is exposed by a ZPU lookup table. `Implemented` means the command has an evidence-backed entry in the policy for ZPU's currently advertised narrow profile; it is not a claim of complete Vulkan 1.4 feature or CTS conformance. The command-level ABI result is tracked in [`docs/vulkan-abi.md`](vulkan-abi.md). A narrow path, stub, opaque placeholder, or unaudited behavior should remain `No` until its advertised contract is explicit.",
        "",
        f"Current totals: **{len(rows)} core commands**, **{len(dispatched)} dispatched**, **{len(implemented)} narrow-profile evidence entries**.",
        "",
        "| Core | Command | Description | Dispatched | Implemented |",
        "| --- | --- | --- | --- | --- |",
        *rows,
        "",
    ))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    generated = render()
    if args.write:
        OUTPUT.write_text(generated)
        return
    if not OUTPUT.exists() or OUTPUT.read_text() != generated:
        raise SystemExit("Vulkan command matrix is stale; run with --write")
    print("vulkan-command-matrix: generated table is current")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

"""Generate and validate ZPU's pinned, non-advertised Vulkan target inventory."""

import argparse
import hashlib
import json
import pathlib
import sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
POLICY = ROOT / "api/inventory-policy.json"
VK_XML = ROOT / "api/registry/vk.xml"
PROFILE_JSON = ROOT / "api/registry/VP_KHR_roadmap.json"
OUTPUT = ROOT / "api/vulkan-1.4.360.json"

EXPECTED = {
    "target_api_version": "1.4.360",
    "registry_commit": "0b7f383797fa7be53ae28213e001ae60668ee511",
    "registry_sha256": "65d829561fa4b9e01a15e1327d9e6744f66b025b08c5c7ad13636bf0a8b15c62",
    "profile_commit": "6c1d0b544b1a432bc33d7fb4c8a6a0a71c01dcfd",
    "profile_sha256": "41d8e5b2421bcd78e36d346de18933f5e8ac8e13a82bbcb197bed3fb7fec066d",
    "profile": "VP_KHR_roadmap_2026",
}


class InventoryError(Exception):
    pass


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise InventoryError(f"cannot read {path.relative_to(ROOT)}: {error}") from error


def digest(path):
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as error:
        raise InventoryError(f"cannot read {path.relative_to(ROOT)}: {error}") from error


def require(condition, message):
    if not condition:
        raise InventoryError(message)


def validate_pin(policy):
    registry = policy.get("registry", {})
    profiles = policy.get("profile_registry", {})
    checks = (
        (policy.get("target_api_version"), EXPECTED["target_api_version"], "target revision"),
        (registry.get("commit"), EXPECTED["registry_commit"], "registry commit"),
        (registry.get("sha256"), EXPECTED["registry_sha256"], "registry source hash"),
        (profiles.get("commit"), EXPECTED["profile_commit"], "profile commit"),
        (profiles.get("sha256"), EXPECTED["profile_sha256"], "profile source hash"),
        (profiles.get("profile"), EXPECTED["profile"], "profile name"),
    )
    for actual, expected, label in checks:
        require(actual == expected, f"wrong {label}: expected {expected}, got {actual}")
    require(digest(VK_XML) == registry["sha256"], "wrong registry source hash for api/registry/vk.xml")
    require(digest(PROFILE_JSON) == profiles["sha256"], "wrong profile source hash for api/registry/VP_KHR_roadmap.json")


def registry_index(root):
    commands = {}
    for node in root.findall("./commands/command"):
        name = node.get("name") or node.findtext("proto/name")
        if name:
            commands[name] = node.get("alias")
    types = {}
    for node in root.findall("./types/type"):
        name = node.get("name") or node.findtext("name") or node.findtext("proto/name")
        if name:
            types[name] = node.get("alias")
    extensions = {}
    for node in root.findall("./extensions/extension"):
        name = node.get("name")
        if name:
            extensions[name] = node
    enums = {}
    enum_nodes = root.findall("./enums/enum") + root.findall("./feature/require/enum") + root.findall("./extensions/extension/require/enum")
    for node in enum_nodes:
        name = node.get("name")
        if name and name not in enums:
            enums[name] = node.get("alias")
    return commands, types, enums, extensions


def core_inventory(root, commands, types, enums):
    versions = {}
    expected_versions = ["VK_VERSION_1_0", "VK_VERSION_1_1", "VK_VERSION_1_2", "VK_VERSION_1_3", "VK_VERSION_1_4"]
    expected_classes = {"BASE", "COMPUTE", "GRAPHICS", "VERSION"}
    seen_classes = {name: set() for name in expected_versions}
    for feature in root.findall("./feature"):
        name = feature.get("name")
        number = feature.get("number", "").replace(".", "_")
        version_name = f"VK_VERSION_{number}"
        if version_name not in expected_versions or "vulkan" not in feature.get("api", "vulkan").split(","):
            continue
        feature_class = "VERSION" if name == version_name else name.removeprefix("VK_").removesuffix(f"_VERSION_{number}")
        require(feature_class in expected_classes, f"unknown core feature class: {name}")
        require(feature_class not in seen_classes[version_name], f"duplicate core feature class: {name}")
        seen_classes[version_name].add(feature_class)
        buckets = versions.setdefault(version_name, {"commands": set(), "types": set(), "enums": set()})
        for require_node in feature.findall("require"):
            if require_node.get("api") is not None and "vulkan" not in require_node.get("api").split(","):
                continue
            for kind in buckets:
                singular = kind[:-1] if kind != "enums" else "enum"
                for item in require_node.findall(singular):
                    item_name = item.get("name")
                    if item_name:
                        buckets[kind].add(item_name)
    require(list(versions) == expected_versions, "missing cumulative core version block")
    for name in expected_versions:
        require(seen_classes[name] == expected_classes, f"missing core feature class for {name}")
        require(all(versions[name][kind] for kind in versions[name]), f"empty core surface for {name}")
        versions[name]["commands"] = canonical_names(versions[name]["commands"], commands, "core command")
        versions[name]["types"] = canonical_names(versions[name]["types"], types, "core type")
        versions[name]["enums"] = canonical_names(versions[name]["enums"], enums, "core enum")
    introduced = {name: {kind: sorted(values) for kind, values in versions[name].items()} for name in expected_versions}
    cumulative = {
        kind: sorted(set().union(*(versions[name][kind] for name in expected_versions)))
        for kind in ("commands", "types", "enums")
    }
    return {"introduced_by_version": introduced, "all_through_1_4": cumulative}


def canonical_names(names, index, label):
    result = set()
    for original in names:
        require(original in index, f"missing {label} definition: {original}")
        name = original
        seen = set()
        while index[name] is not None:
            require(name not in seen, f"cyclic alias for {label}: {original}")
            seen.add(name)
            name = index[name]
            require(name in index, f"alias target missing for {label}: {original}")
        result.add(name)
    reject_alias_names(result, index, label)
    return result


def reject_alias_names(names, index, label):
    for name in names:
        require(name in index, f"missing {label} definition: {name}")
        require(index[name] is None, f"alias-only {label} classification: {name}")


def extension_inventory(policy, extensions):
    required = policy.get("chromium_required_extensions", [])
    deferred = policy.get("deferred_optional_extensions", [])
    all_names = [item.get("name") for item in required + deferred]
    require(None not in all_names, "extension entry is missing a name")
    require(len(all_names) == len(set(all_names)), "duplicate extension classification")
    for item in required:
        require(item.get("justification", "").strip(), f"unjustified optional entry: {item['name']}")
        require(item.get("source", "").strip(), f"unjustified optional entry has no source: {item['name']}")
    for item in deferred:
        require(item.get("reason", "").strip(), f"deferred optional entry has no reason: {item['name']}")
    for item in required + deferred:
        name = item["name"]
        require(name in extensions, f"unknown extension: {name}")
        node = extensions[name]
        require(node.get("alias") is None, f"alias-only extension classification: {name}")
        expected_scope = "instance" if node.get("type") == "instance" else "device"
        require(item.get("scope") == expected_scope, f"wrong extension scope for {name}: expected {expected_scope}")
        require("vulkan" in node.get("supported", "").split(","), f"extension is not Vulkan-supported: {name}")
    return sorted(required, key=lambda item: item["name"]), sorted(deferred, key=lambda item: item["name"])


def profile_inventory(profile_data, profile_name):
    profiles = profile_data.get("profiles", {})
    require(profile_name in profiles, f"missing profile: {profile_name}")
    profile = profiles[profile_name]
    capabilities = profile_data.get("capabilities", {})
    required_names = []
    for entry in profile.get("capabilities", []):
        required_names.extend(entry if isinstance(entry, list) else [entry])
    optional_names = list(profile.get("optionals", []))
    for name in required_names + optional_names:
        require(name in capabilities, f"profile references missing capability: {name}")
    require(len(required_names) == len(set(required_names)), "duplicate required profile capability")
    require(len(optional_names) == len(set(optional_names)), "duplicate optional profile capability")
    require(not set(required_names) & set(optional_names), "profile capability is both required and optional")
    return {
        "name": profile_name,
        "api_version": profile.get("api-version"),
        "required_capabilities": {name: capabilities[name] for name in sorted(required_names)},
        "deferred_optional_capabilities": {name: capabilities[name] for name in sorted(optional_names)},
    }


def generate(policy):
    validate_pin(policy)
    try:
        root = ET.parse(VK_XML).getroot()
    except (OSError, ET.ParseError) as error:
        raise InventoryError(f"cannot parse api/registry/vk.xml: {error}") from error
    commands, types, enums, extensions = registry_index(root)
    required, deferred = extension_inventory(policy, extensions)
    profile = profile_inventory(load_json(PROFILE_JSON), policy["profile_registry"]["profile"])
    return {
        "schema_version": 1,
        "notice": "Target inventory only; this file does not describe or change ZPU runtime advertising.",
        "target_api_version": policy["target_api_version"],
        "sources": {"registry": policy["registry"], "profile_registry": policy["profile_registry"]},
        "mandatory_cumulative_core": core_inventory(root, commands, types, enums),
        "roadmap_profile": profile,
        "chromium_required_extensions": required,
        "deferred_optional_extensions": deferred,
    }


def encoded(value):
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="replace the generated inventory")
    parser.add_argument("--policy", type=pathlib.Path, default=POLICY, help=argparse.SUPPRESS)
    parser.add_argument("--output", type=pathlib.Path, default=OUTPUT, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        result = encoded(generate(load_json(args.policy)))
        if args.write:
            args.output.write_text(result, encoding="utf-8")
            return 0
        try:
            current = args.output.read_text(encoding="utf-8")
        except OSError as error:
            raise InventoryError(f"missing generated inventory: {error}") from error
        require(current == result, "stale generated output: run tools/api_inventory.py --write")
        print("api-inventory: Vulkan 1.4.360 registry, profile, classifications, and generated output valid")
        return 0
    except InventoryError as error:
        print(f"api-inventory: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

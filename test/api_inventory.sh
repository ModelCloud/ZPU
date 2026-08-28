#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

root=$(cd "$(dirname "$0")/.." && pwd)
tool="$root/tools/api_inventory.py"
policy="$root/api/inventory-policy.json"
generated="$root/api/vulkan-1.4.360.json"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

expect_failure() {
    local label=$1 pattern=$2
    shift 2
    if "$@" >"$tmp/out" 2>"$tmp/err"; then
        echo "fixture unexpectedly passed: $label" >&2
        exit 1
    fi
    if ! grep -F "$pattern" "$tmp/err" >/dev/null; then
        echo "fixture emitted the wrong failure: $label" >&2
        cat "$tmp/err" >&2
        exit 1
    fi
}

mutate_policy() {
    local expression=$1 output=$2
    python3 - "$policy" "$output" "$expression" <<'PY'
import json, sys
source, output, expression = sys.argv[1:]
data = json.load(open(source, encoding="utf-8"))
exec(expression, {"data": data})
json.dump(data, open(output, "w", encoding="utf-8"), indent=2)
PY
}

mutate_policy "data['registry']['sha256'] = '0' * 64" "$tmp/wrong-hash.json"
expect_failure wrong-hash "wrong registry source hash" python3 "$tool" --policy "$tmp/wrong-hash.json" --output "$generated"

mutate_policy "data['registry']['commit'] = '0' * 40" "$tmp/wrong-revision.json"
expect_failure wrong-revision "wrong registry commit" python3 "$tool" --policy "$tmp/wrong-revision.json" --output "$generated"

mutate_policy "data['chromium_required_extensions'].append(dict(data['chromium_required_extensions'][0]))" "$tmp/duplicate.json"
expect_failure duplicate "duplicate extension classification" python3 "$tool" --policy "$tmp/duplicate.json" --output "$generated"

mutate_policy "data['chromium_required_extensions'][0]['scope'] = 'device'" "$tmp/wrong-class.json"
expect_failure wrong-class "wrong extension scope" python3 "$tool" --policy "$tmp/wrong-class.json" --output "$generated"

mutate_policy "data['chromium_required_extensions'][0]['justification'] = ''" "$tmp/unjustified.json"
expect_failure unjustified "unjustified optional entry" python3 "$tool" --policy "$tmp/unjustified.json" --output "$generated"

mutate_policy "data['chromium_required_extensions'][0]['name'] = 'VK_DOES_NOT_EXIST'" "$tmp/missing.json"
expect_failure missing "unknown extension" python3 "$tool" --policy "$tmp/missing.json" --output "$generated"

expect_failure alias-only "alias-only core command classification" python3 - "$tool" <<'PY'
import importlib.util, pathlib, sys, xml.etree.ElementTree as ET
spec = importlib.util.spec_from_file_location("api_inventory", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = ET.fromstring(pathlib.Path("test/fixtures/api_inventory/alias-command.xml").read_text())
commands, unused_types, unused_enums, unused_extensions = module.registry_index(root)
try:
    module.reject_alias_names({"vkAlias"}, commands, "core command")
except module.InventoryError as error:
    print(f"api-inventory: {error}", file=sys.stderr)
    raise SystemExit(1)
raise SystemExit(0)
PY

cp "$generated" "$tmp/stale.json"
printf ' ' >>"$tmp/stale.json"
expect_failure stale "stale generated output" python3 "$tool" --output "$tmp/stale.json"

python3 "$tool"
echo "api-inventory fixtures: all expected failures observed"

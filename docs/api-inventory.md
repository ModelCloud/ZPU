<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Vulkan target inventory contract

`api/vulkan-1.4.360.json` is the generated, reviewable inventory for ZPU's
future target. It separates:

- every command, type, and enumerant introduced by each Vulkan core version
  from 1.0 through 1.4, plus their exact cumulative union through 1.4;
- the required capabilities of `VP_KHR_roadmap_2026`, with that profile's
  optional capability block explicitly deferred;
- extension names required by the current Chromium ozone/headless consumer,
  each tied to the justification in `chromium_compat.md`; and
- Chromium's useful but non-required extension paths, explicitly deferred with
  a reason.

`api/inventory-policy.json` is the hand-maintained classification and source
pin. The two unmodified files in `api/registry/` are the authoritative inputs
from the Vulkan-Headers and Vulkan-Profiles `v1.4.360` release tags. Their exact
commits and SHA-256 hashes are part of the gate; see `api/registry/README.md`.

Run the contract through the repository limiter:

```sh
tools/limited-cpus.sh zig build api-inventory
```

To intentionally refresh generated output after a separately reviewed policy
or upstream-pin change, run `python3 tools/api_inventory.py --write`, then run
the limited build step. Validation is offline and deterministic: CI never
downloads a moving registry. The gate rejects a wrong revision/hash, missing
registry items, duplicates, alias-only core items, wrong extension scope,
unknown extension names, missing consumer justification or deferral reason,
and stale generated output. Negative fixtures exercise each failure class.

The command subset of this inventory is paired with the generated
[`docs/vulkan-abi.md`](vulkan-abi.md) page. That page proves that all 234
cumulative core command names have dispatch, implementation-contract, and
regression-evidence rows; it is the authoritative documentation for ZPU's
100% command-level Vulkan 1.4 ABI result. The inventory remains broader than
that command claim: its 603 types and 390 enums describe the future
field-by-field conformance target and do not imply that every optional feature
is enabled. ZPU continues to advertise and accept only its truthful Vulkan
1.0 runtime surface as documented in `docs/api-policy.md`.

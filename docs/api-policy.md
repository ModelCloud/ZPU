<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# ZPU Vulkan API Policy

Normative policy for the Vulkan API surface ZPU targets, what the driver is
permitted to advertise, and when an advertised version may change.

**MUST**, **MUST NOT**, **SHOULD**, and **MAY** are used in the RFC 2119 sense.

This document is normative about the **target**. It is not a conformance claim
and it does not describe what is implemented today. ZPU is not a conformant
Vulkan implementation; the driver, the ICD manifest, and CI all advertise and
assert Vulkan **1.1.0** right now. See
[Current state versus target](#current-state-versus-target) for the honest
inventory, and treat every statement in sections 1–6 as a requirement on future
work rather than a description of the shipped ICD.

The command-level ABI inventory has since reached **234/234** cumulative core
entry points through Vulkan 1.4.360. [The ABI status page](vulkan-abi.md) lists
each command, its dispatch and contract status, and the unit/regression and
verification gates. This is a complete command/dispatch ABI statement — exact
calling convention, LP64 record handling, pNext/count validation, ownership,
and failure atomicity — and does **not** by itself satisfy the complete-core
advertisement gate below, which also requires every mandatory feature, limit,
format, and independent conformance check.

---

## 1. Pinned core version

ZPU targets Vulkan core version **1.4.360**.

- The pinned target **MUST** be `1.4.360` exactly. Any ABI declaration, limit,
  feature, enumerant, or structure layout added to the driver **MUST** be
  transcribed against that revision of the specification and no other.
- The pin is a single point of truth. A change to it is a change to this
  document, reviewed on its own, never a side effect of another patch.
- The pin says nothing about what the driver reports at runtime. Advertising is
  governed exclusively by [section 6](#6-version-advertisement-gates).

## 2. Full cumulative mandatory core, minimum optional surface

Vulkan 1.4 is cumulative: it subsumes the mandatory core of 1.0, 1.1, 1.2, and
1.3, including every extension promoted into those versions.

- ZPU **MUST** implement the **complete** mandatory core of 1.4.360 — every
  required entry point, structure, feature, limit, and format — before it may
  advertise 1.4. Partial core is not a version.
- There is no "1.1 stop" and no "1.2 stop". Intermediate minor versions are not
  separate destinations and **MUST NOT** be advertised as milestones; they are
  subsets of the single pinned target.
- Optional surface is held to the **minimum**. An optional feature, optional
  limit above the required floor, or an extension beyond the pinned core
  **MUST NOT** be advertised unless a named consumer requires it, and the
  requirement **MUST** be recorded with the source that establishes it — the
  way [chromium_compat.md](../chromium_compat.md) cites Chromium and Dawn
  sources for each item it lists.
- Advertising an optional capability is a commitment that it works. A feature
  bit **MUST NOT** be set to satisfy a caller's check while the machinery behind
  it is absent or partial.

## 3. Profile target: `VP_KHR_roadmap_2026`

ZPU targets the Khronos roadmap profile **`VP_KHR_roadmap_2026`**.

- `VP_KHR_roadmap_2026` is the **target** profile. ZPU **MUST NOT** claim
  support for it, report it, or describe itself as meeting it until every
  requirement of the profile is implemented and independently verified.
- The profile is the tie-breaker for optional surface. Where section 2 forbids
  optional capabilities without a named consumer, capabilities mandated by
  `VP_KHR_roadmap_2026` are in scope by policy and need no separate
  justification.
- Where the profile and a consumer disagree, the union is the target and the
  disagreement **SHOULD** be recorded rather than silently resolved.
- Profile support is not a substitute for conformance. Meeting the profile and
  passing the Vulkan CTS are separate claims and **MUST** be stated separately.

## 4. Loader–ICD interface version

The Khronos loader–driver interface version target is **7, and only 7**.

- This is a **future implementation requirement**, not a description of current
  behavior. `vk_icdNegotiateLoaderICDInterfaceVersion` today clamps to the
  loader's request (`min(requested, 7)`) and therefore still **accepts lower
  interface versions**, which is what the current smoke test and the system
  loader exercise.
- When the requirement is implemented, negotiation **MUST** succeed only at
  interface version 7. A loader that offers a lower version **MUST** be refused
  rather than accommodated, and ZPU **MUST NOT** carry per-version negotiation
  branches, fallbacks, or capability probes for interfaces below 7.
- Because refusing lower interfaces can make ZPU invisible to an older system
  loader, this change is gated like a version bump: it lands only when CI
  demonstrates discovery against a loader that negotiates 7.

## 5. No legacy surface

ZPU is a new implementation with no installed base to preserve. It therefore
carries none of the compatibility surface that a long-lived driver accumulates.

- **No legacy-specific code paths.** ZPU **MUST NOT** contain branches whose
  only purpose is to serve an older API version, older loader, or older client.
- **No compatibility shims.** Emulating a removed behavior, or re-implementing a
  capability the pinned core already provides, **MUST NOT** be done for
  compatibility's sake.
- **No deprecated, vendor, or promoted aliases maintained solely for old
  clients.** Where an extension has been promoted into the pinned core, the core
  entry point is the implementation. The `KHR`/`EXT`/vendor alias
  **MUST NOT** be kept alive purely so that an old client that only knows the
  old name keeps working.
- The narrow exception is a **current** consumer, not an old one. If a
  present-day client that ZPU targets requires a promoted extension to be
  enumerated by name — as Chromium does for
  `VK_KHR_external_memory_capabilities` and
  `VK_KHR_external_semaphore_capabilities`, both promoted to 1.1 core yet still
  passed by name to `vkCreateInstance` — then enumerating that name is a
  requirement of a live consumer and is in scope. It is not a legacy alias, and
  it **MUST** be recorded with its source, per section 2.
- Interfaces **MAY** change incompatibly while the ICD takes shape. Nothing in
  ZPU's history is a compatibility obligation.

## 6. Version advertisement gates

The advertised version is a claim about the implementation, so it moves last.

ZPU **MUST NOT** raise the version reported by any of the following until every
gate below passes:

- `VkPhysicalDeviceProperties::apiVersion` returned by the driver
- the `api_version` field of the ICD manifest
- the maximum `VkApplicationInfo::apiVersion` accepted at instance creation
- any statement in this repository's documentation

**Gates.** All of them, together, for the version being claimed:

1. **Complete mandatory core.** Every mandatory entry point, structure, feature,
   limit, and format of the claimed version is implemented — not stubbed, not
   returning a success code without doing the work.
2. **Behavioral proof.** The behavioral contract (`zig build behavior`) and the
   100% executed-line coverage gate (`zig build coverage`) cover the new surface
   under the same rules as the existing surface.
3. **Independent verification.** A gate that does not share code with the
   implementation asserts the new behavior — the standalone C client
   (`zig build transfer`) and the system-loader discovery gate are the existing
   examples of this shape.
4. **Loader discovery.** The system Vulkan loader discovers ZPU and reports the
   new version, asserted in CI, exactly as the current gate asserts `1.0.0`.
5. **Simultaneous update.** The driver, the manifest, the CI assertion, and the
   documentation change in the same commit. A version claim that is true in one
   of those and false in another is a broken claim.

A version **MUST NOT** be advertised to unlock a client's version check. When a
consumer skips ZPU because the reported version is too low — as Chromium does
today, per [chromium_compat.md](../chromium_compat.md) — the answer is to
implement the version, not to report it.

## Current state versus target

Everything in this column is the honest present state, not an aspiration.

| Subject | Current | Target under this policy |
| --- | --- | --- |
| Cumulative core command ABI | `234/234` command entry points documented, dispatched, and regression-covered; bounded feature policies remain explicit | Complete mandatory core behavior and independent conformance |
| Core version reported by the driver | `1.1.0` | `1.4.360` |
| ICD manifest `api_version` | `1.1.0` | `1.4.360` |
| CI loader-discovery assertion | asserts `apiVersion = 1.1.0` | asserts the pinned version |
| Max `VkApplicationInfo::apiVersion` accepted | Vulkan 1.1 | the pinned version |
| Profile | none claimed | `VP_KHR_roadmap_2026` targeted, not claimed |
| Loader–ICD interface | negotiates `min(requested, 7)`; **accepts lower interfaces** | 7 only |
| Instance extensions | `VK_KHR_surface`, `VK_KHR_xcb_surface`, `VK_EXT_headless_surface`, `VK_KHR_external_memory_capabilities`, `VK_KHR_external_semaphore_capabilities` | minimum surface per sections 2–3 |
| Device extensions | `VK_KHR_swapchain` | minimum surface per sections 2–3 |
| Optional features | none advertised | minimum surface per sections 2–3 |
| Conformance | non-conformant; no CTS run exists in this repository | conformance investigation only after the mandatory core is complete |

ZPU implements a narrow, deliberately non-conformant slice of Vulkan 1.0:
host-visible memory, buffers, linear 2D images in two formats, a small transfer
command set, synchronous fences, one narrow image-barrier form, XCB
presentation, and a vkcube-specific CPU draw path. There is no general SPIR-V
execution. The gap between the two columns above is the entire remaining
project, and this document does not shorten it.

## Changing this policy

The pinned version, the profile target, and the loader-interface target are
changed by editing this document in a dedicated commit that states why. A patch
that changes an advertised version without a corresponding change here — or
without the gates in section 6 — is rejected on that basis alone.

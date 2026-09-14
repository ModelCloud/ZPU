<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

<p align="center">
  <img src="docs/assets/zpu-logo.svg" alt="ZPU logo" width="720">
</p>

# ZPU

> A CPU-native Vulkan driver for agents that need to build, inspect, test, and
> render real graphics stacks—without requiring a physical GPU.

ZPU is an experimental Linux Vulkan ICD written in Zig. It runs Vulkan work in
the application process, using the CPU and ordinary host memory. That makes it
a useful graphics substrate for AI agents: the full stack is inspectable,
reproducible, scriptable, and explicit about what it does and does not support.

<p align="center">
  <img src="docs/assets/zpu-intro.svg" alt="Introducing ZPU" width="100%">
</p>

## Showcase: Chromium, Vulkan, and VP9

ZPU drives the packaged Chromium browser inside a real SmolVM guest using the
ZPU ICD alone. Chromium reports native **Skia Ganesh Vulkan**, GPU compositing,
and rasterization; page and video work flow through ZPU's Mosaic renderer.

<p align="center">
  <img src="docs/assets/zpu-chromium-google.png" alt="google.com rendered by Chromium through ZPU" width="720">
  <br>
  <em>Packaged guest Chromium rendering google.com through ZPU.</em>
</p>

<p align="center">
  <a href="docs/assets/zpu-chromium-vp9-playback.mp4">Download the 15-second Chromium VP9 playback capture (MP4)</a>
  <br>
  <em>Headless Chromium playing an open VP9 fixture through ZPU with two Mosaic lanes. The MP4 is padded to 640×360 for social-video compatibility without changing the capture's aspect ratio.</em>
</p>

The capture is evidence of the browser/video rendering path, not a claim of
60 FPS: its 60 Hz output stream preserves captured frames, while the measured
two-lane playback run presented 37.75 FPS. ZPU is CPU rendering, not hardware
GPU acceleration.

## Why ZPU for agentic work?

Agents can take a graphics task from source change to reproducible evidence in
one environment:

- Build a real Vulkan ICD from source and run it under the system loader.
- Launch a Linux guest, browser, and desktop with scripts rather than opaque
  cloud GPUs or proprietary driver layers.
- Exercise an application with virtual mouse and keyboard devices from Python.
- Inspect validation failures, rendering counters, shader profiles, and exact
  artifacts while keeping unsupported operations fail-closed.

The result is a practical sandbox for browser rendering, UI automation,
graphics debugging, and CPU-first experimentation.

## Mosaic and shader specialization

**Mosaic** is ZPU's cache-local, packetized tile renderer. It gives complex
draw streams a CPU-native path that can use selected worker lanes while keeping
the scalar renderer as the correctness reference.

ZPU also lowers supported SPIR-V into a small render IR and specializes common
work at runtime. That lets it remove dead work, select CPU-safe vector kernels,
and prepare repeated shader state without pretending that every Vulkan feature
or shader is supported. Runtime CPU feature detection selects available ISA
paths such as AVX2 only when the generated code and the running CPU both allow
it.

Read the design notes for [Mosaic](design/mosaic-renderer.md), the
[render IR](design/render-ir.md), and [ISA dispatch](design/isa-tiers.md).

## Quick start

ZPU currently targets x86-64 Linux and Zig 0.16.0.

```sh
zig build
tools/limited-cpus.sh zig build test

# Show the ZPU device through the system Vulkan loader.
VK_DRIVER_FILES="$PWD/zig-out/share/vulkan/icd.d/zpu_icd.x86_64.json" \
  vulkaninfo --summary
```

For the guest browser workflow, use the SmolVM helper scripts. They build,
stage, and launch the packaged Chromium path with a ZPU-only ICD:

```sh
tools/smolvm-zpu.sh create
tools/smolvm-zpu.sh bootstrap
tools/smolvm-zpu.sh build
tools/smolvm-zpu.sh package
tools/smolvm-zpu.sh stage
tools/smolvm-chrome.sh reproduce
```

The workflow requires SmolVM 1.7.1 and its documented host prerequisites. It
does not use SmolVM's virtual GPU option; that keeps the validation path focused
on ZPU rather than virtio/Venus.

## Documentation

Start here for the details kept out of this README:

- [Vulkan API policy](docs/api-policy.md) — the authoritative statement of
  advertised capabilities and boundaries.
- [Vulkan ABI status](docs/vulkan-abi.md) — command-level coverage, distinct
  from feature conformance.
- [Linux userspace driver](docs/linux-userspace-driver.md) — ICD, loader, and
  presentation model.
- [Benchmarking](docs/benchmarking.md) and
  [benchmark history](docs/benchmark-history.md) — methodology and recorded
  results.
- [3D application workloads](docs/3d-app-benchmarks.md) and
  [Vulkan submission benchmarks](docs/vulkan-abi-benchmarks.md).
- [Desktop readiness](docs/desktop-readiness.md) and the
  [SmolVM guest workflow](docs/smolvm-omarchy.md).
- [CPU ML integration boundary](docs/cpu-ml-zml.md) and the optional
  [Metal-shaped ABI](docs/metal-abi.md).

## Scope and status

ZPU is deliberately bounded and experimental. It is a userspace Vulkan ICD,
not a kernel DRM driver, Mesa driver, display server, or physical-GPU driver.
It reports a Vulkan 1.4.360 ABI ceiling, but that is not a Vulkan CTS or
full-feature conformance claim. Features, limits, formats, and shader profiles
are advertised only where ZPU has an implemented and tested path; unsupported
work is rejected rather than silently redirected to another renderer.

This is precisely why ZPU is useful for serious agentic systems work: its
results are inspectable, its boundaries are explicit, and its demonstrations
are reproducible.

## License

ZPU is licensed under the [Apache License 2.0](LICENSE).

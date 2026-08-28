#!/usr/bin/env python3
# Copyright 2026 ModelCloud
# SPDX-License-Identifier: Apache-2.0

"""Insert ZPU branding/benchmark SVGs into README.md without rewriting content."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "README.md"


def insert_after_heading(text: str, heading: str, image: str, alt: str) -> str:
    marker = f'<p align="center"><img src="{image}" alt="{alt}" width="100%"></p>'
    if marker in text:
        return text
    needle = heading + "\n"
    if needle not in text:
        raise SystemExit(f"README heading not found: {heading}")
    return text.replace(needle, needle + "\n" + marker + "\n", 1)


def main() -> int:
    text = README.read_text(encoding="utf-8")

    logo = '<p align="center"><img src="docs/assets/zpu-logo.svg" alt="ZPU logo" width="720"></p>'
    if logo not in text:
        heading = "# ZPU ⚡🧊"
        if heading not in text:
            raise SystemExit("README title not found")
        text = text.replace(heading, logo + "\n\n" + heading, 1)

    intro = '<p align="center"><img src="docs/assets/zpu-intro.svg" alt="Introducing ZPU" width="100%"></p>'
    if intro not in text:
        needle = "## ✨ At a glance"
        if needle not in text:
            raise SystemExit("At-a-glance heading not found")
        text = text.replace(needle, intro + "\n\n" + needle, 1)

    text = insert_after_heading(text, "## 🧭 Linux userspace path", "docs/assets/zpu-pipeline.svg", "ZPU Vulkan userspace pipeline")
    text = insert_after_heading(text, "## ✅ Vulkan 1.4 ABI coverage", "docs/assets/zpu-abi.svg", "ZPU Vulkan ABI coverage")
    text = insert_after_heading(text, "## ⚙️ Zig-native fast path", "docs/assets/zpu-locality.svg", "ZPU locality-first CPU design")
    text = insert_after_heading(text, "## 🎮 Target profiles and frame pacing", "docs/assets/zpu-targets.svg", "ZPU 4K and 8K p99 target profiles")
    text = insert_after_heading(text, "## 📐 3D throughput on two cores", "docs/assets/zpu-benchmark.svg", "ZPU two-core vkcube benchmark")

    if "## 📄 License" not in text:
        text = text.rstrip() + "\n\n## 📄 License\n\nZPU is licensed under the [Apache License 2.0](LICENSE). First-party source, scripts, configuration, and documentation use SPDX headers where the file format permits comments. Non-commentable machine-readable files are covered by the repository license; third-party/generated registry inputs retain their applicable upstream terms.\n"

    README.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

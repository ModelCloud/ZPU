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

# The manifest names the corresponding Metal selector for reviewability. The
# portable ABI uses snake_case C exports, so these aliases let the coverage
# check verify that each claimed selector has a real implementation symbol.
SOURCE_SYMBOL_ALIASES = {
    "MTLDevice.newBuffer": "zpu_metal_device_new_buffer",
    "MTLDevice.newTexture": "zpu_metal_device_new_texture",
    # The source inventory intentionally records overloaded Objective-C
    # selectors by their reviewed manifest name; the SDK spelling is the
    # `newTextureWithDescriptor:iosurface:plane:` overload.
    "MTLDevice.newTextureWithDescriptorIOSurfacePlane": "newTextureWithDescriptor",
    "MTLBuffer.contents": "zpu_metal_buffer_contents",
    "MTLBuffer.length": "zpu_metal_buffer_length",
    "MTLTexture.width": "zpu_metal_texture_width",
    "MTLTexture.height": "zpu_metal_texture_height",
    "MTLTexture.getBytes": "zpu_metal_texture_get_bytes",
    "MTLTexture.replaceRegion": "zpu_metal_texture_replace_region",
    "MTLCommandBuffer.status": "zpu_metal_command_buffer_get_status",
    "MTLCommandBuffer.error": "error",
    "MTLCommandBuffer.waitUntilCompleted": "zpu_metal_command_buffer_wait_until_completed",
    "MTLRenderCommandEncoder.setVertexBuffer": "zpu_metal_render_encoder_set_vertex_buffer",
    "MTLRenderCommandEncoder.setVertexBytes": "zpu_metal_render_encoder_set_vertex_bytes",
    "MTLRenderCommandEncoder.setDepthTexture": "zpu_metal_render_encoder_set_depth_texture",
    "MTLRenderCommandEncoder.drawPrimitivesIndirect": "zpu_metal_render_encoder_draw_primitives_indirect",
    "MTLRenderCommandEncoder.drawIndexedPrimitivesIndirect": "zpu_metal_render_encoder_draw_indexed_primitives_indirect",
    "MTLDevice.newFence": "zpu_metal_device_new_fence",
    "MTLFence.device": "zpu_metal_fence_device",
    "MTLDevice.newSharedEvent": "zpu_metal_device_new_shared_event",
    "MTLDevice.newHeapWithDescriptor": "newHeapWithDescriptor",
    "MTLHeap.size": "zpu_metal_heap_size",
    "MTLHeap.usedSize": "zpu_metal_heap_used_size",
    "MTLHeap.currentAllocatedSize": "zpu_metal_heap_used_size",
    "MTLHeap.maxAvailableSizeWithAlignment": "maxAvailableSizeWithAlignment",
    "MTLHeap.newBufferWithLength": "zpu_metal_heap_new_buffer",
    "MTLHeap.newTextureWithDescriptor": "zpu_metal_heap_new_texture",
    "MTLDevice.newRenderPipelineStateWithDescriptor": "newRenderPipelineStateWithDescriptor",
    "MTLDevice.newDepthStencilStateWithDescriptor": "newDepthStencilStateWithDescriptor",
    "MTLDevice.newSamplerStateWithDescriptor": "newSamplerStateWithDescriptor",
    "MTLDevice.newComputePipelineStateWithFunctionCompletionHandler": "newComputePipelineStateWithFunction",
    "MTLDevice.newComputePipelineStateWithDescriptorCompletionHandler": "newComputePipelineStateWithDescriptor",
    "MTLDevice.newRenderPipelineStateWithDescriptorCompletionHandler": "newRenderPipelineStateWithDescriptor",
    "MTLSharedEvent.signaledValue": "signaledValue",
    "MTLSharedEvent.notifyListener": "notifyListener",
    "MTLSharedEvent.waitUntilSignaledValue": "waitUntilSignaledValue",
    "MTLRenderCommandEncoder.updateFence": "zpu_metal_render_encoder_update_fence",
    "MTLRenderCommandEncoder.waitForFence": "zpu_metal_render_encoder_wait_for_fence",
    "MTLRenderCommandEncoder.setRenderPipelineState": "zpu_metal_render_encoder_set_pipeline_formats",
    "MTLRenderCommandEncoder.setDepthStencilState": "zpu_metal_render_encoder_set_depth_compare_function",
    "MTLRenderCommandEncoder.setBlendColor": "zpu_metal_render_encoder_set_blend_color",
    "MTLBlitCommandEncoder.updateFence": "zpu_metal_blit_encoder_update_fence",
    "MTLBlitCommandEncoder.waitForFence": "zpu_metal_blit_encoder_wait_for_fence",
    "MTLCommandBuffer.parallelRenderCommandEncoder": "parallelRenderCommandEncoderWithDescriptor",
    "MTLTexture.newTextureViewWithPixelFormatLevelsSlices": "newTextureViewWithPixelFormat",
    "MTLRenderCommandEncoder.drawIndexedPrimitives": "zpu_metal_render_encoder_draw_indexed_primitives",
    "MTLRenderCommandEncoder.drawPrimitivesBaseInstance": "baseInstance",
    "MTLRenderCommandEncoder.drawIndexedPrimitivesInstanceCount": "instanceCount",
    "MTLRenderCommandEncoder.drawIndexedPrimitivesBaseVertex": "zpu_metal_render_encoder_draw_indexed_primitives_base_vertex",
    "MTLBlitCommandEncoder.copyFromBuffer": "zpu_metal_blit_encoder_copy_buffer",
    "MTLBlitCommandEncoder.copyFromBufferToTexture": "zpu_metal_blit_encoder_copy_buffer_to_texture",
    "MTLBlitCommandEncoder.copyFromTextureToBuffer": "zpu_metal_blit_encoder_copy_texture_to_buffer",
    "MTLBlitCommandEncoder.copyFromTextureToTexture": "zpu_metal_blit_encoder_copy_texture_to_texture",
    "MTLBlitCommandEncoder.fillBuffer": "zpu_metal_blit_encoder_fill_buffer",
    "MTLBlitCommandEncoder.synchronizeResource": "zpu_metal_blit_encoder_synchronize_resource",
    "MTL4ArgumentTable.setAddressAttributeStride": "setAddress",
    "MTL4CommandQueue.commitWithOptions": "commit",
    "MTL4CommandBuffer.renderCommandEncoderWithDescriptorOptions": "renderCommandEncoderWithDescriptor",
    "MTLTextureViewPool.setTextureViewDescriptor": "setTextureView",
}


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
    portable = data.get("zpu_portable_abi", {})
    entry_points = portable.get("entry_points", [])
    require(implemented and missing, "WIP manifest must name implemented and missing surface")
    require(entry_points and len(entry_points) == len(set(entry_points)), "portable ABI must list unique entry points")
    require(portable.get("apple_adapter_factory") == "ZPUMetalCreateSystemDefaultDevice", "Apple adapter factory must be explicit")
    require(len(implemented) == len(set(implemented)), "duplicate implemented Metal ABI entry")
    require(len(missing) == len(set(missing)), "duplicate unimplemented Metal ABI entry")
    return data


def sdk_headers(sdk, platform="macosx"):
    if sdk is None:
        xcrun = shutil.which("xcrun")
        if not xcrun:
            return None
        try:
            sdk = subprocess.check_output(
                [xcrun, "--sdk", platform, "--show-sdk-path"], text=True, stderr=subprocess.DEVNULL
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
    source = "\n".join(
        path.read_text(encoding="utf-8")
        for path in SOURCE_ROOT.rglob("*")
        if path.suffix in {".zig", ".m"}
    )
    count = 0
    for entry in manifest["implemented_native_abi"]:
        selector = entry.rsplit(".", 1)[-1]
        candidates = (selector, SOURCE_SYMBOL_ALIASES.get(entry, ""))
        if any(candidate and re.search(rf"\b{re.escape(candidate)}\b", source) for candidate in candidates):
            count += 1
    return count


def portable_entry_point_count(manifest):
    source = "\n".join(path.read_text(encoding="utf-8") for path in (ROOT / "src").rglob("*.zig"))
    return sum(
        1
        for symbol in manifest["zpu_portable_abi"]["entry_points"]
        if re.search(rf"\bpub export fn {re.escape(symbol)}\b", source)
    )


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", type=pathlib.Path, help="Apple SDK root or Metal.framework/Headers path")
    parser.add_argument("--platform", choices=("macosx", "iphoneos"), default="macosx")
    parser.add_argument("--all-platforms", action="store_true", help="inventory both macOS and iOS SDKs")
    parser.add_argument("--require-complete", action="store_true", help="fail unless SDK-backed coverage is complete")
    args = parser.parse_args(argv)
    try:
        manifest = load_manifest()
        source_count = source_symbol_count(manifest)
        require(source_count == len(manifest["implemented_native_abi"]), "manifest contains an unimplemented native ABI symbol")
        portable_count = portable_entry_point_count(manifest)
        require(portable_count == len(manifest["zpu_portable_abi"]["entry_points"]), "portable ABI manifest contains an unexported entry point")
        if args.all_platforms and args.sdk is not None:
            raise InventoryError("--sdk cannot be combined with --all-platforms; let xcrun resolve both SDKs")
        platforms = ("macosx", "iphoneos") if args.all_platforms else (args.platform,)
        reports = []
        unavailable = []
        for platform in platforms:
            headers = sdk_headers(args.sdk, platform)
            if headers is None:
                unavailable.append(platform)
                continue
            report = inventory(headers)
            reports.append((platform, report))

        if unavailable and args.require_complete:
            raise InventoryError("Apple SDK unavailable for: " + ", ".join(unavailable))
        if not reports:
            if args.require_complete:
                raise InventoryError("Apple SDK unavailable; run strict coverage on macOS/iOS with the target SDK")
            print(f"metal-abi: SDK unavailable; native manifest validated ({source_count} implemented entries)")
            print("metal-abi: coverage remains WIP and is not claimed complete")
            return 0

        for platform, report in reports:
            print(
                "metal-abi: platform={platform} SDK headers={headers} types={types} selectors={selectors} "
                "c_functions={c_functions} metal4={has_metal4}".format(platform=platform, **report)
            )
        if args.require_complete and (unavailable or not manifest["coverage"].get("complete") or manifest["known_unimplemented_surface"]):
            raise InventoryError("Metal coverage manifest still has known unimplemented surface")
        print("metal-abi: SDK inventory completed; semantic coverage remains manifest-driven")
        return 0
    except InventoryError as error:
        print(f"metal-abi: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

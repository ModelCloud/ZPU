# SPIR-V frontend fixtures

These hand-authored SPIR-V 1.0 assembly fixtures are original ZPU test data
(CC0-1.0). They are deliberately small enough to audit against the binary word
fixtures in `src/vulkan/spirv_frontend.zig`. `vertex_position.spvasm` is the
positive baseline; each file under `negative/` names the profile boundary it
crosses. Binary words are encoded directly in Zig so tests do not depend on an
external assembler or its version.

The deterministic property corpus uses seed `0x5a50554952334431`; failures must
report that seed and the mutated word offset so they can be replayed exactly.

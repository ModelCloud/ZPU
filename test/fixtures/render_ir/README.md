<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Canonical render IR byte fixtures

These lowercase hexadecimal files are static, complete encodings of the four
profile-v1 conformance examples. They were transcribed against the documented
little-endian serialization layout and are deliberately not produced by the
test-only reference serializer. Tests decode these checked-in bytes, compare
every byte, and independently verify their SHA-256 digests.

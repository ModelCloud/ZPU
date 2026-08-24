---
name: zpu-pr-readiness
description: Gate ModelCloud/ZPU pull requests on fresh visual captures, a validated 20-second vkcube video, complete 2D/3D benchmark evidence, and ignored-artifact hygiene.
---

# zpu-pr-readiness — visual and performance evidence

Use this skill before declaring a ModelCloud/ZPU pull request ready. It reports
only `READY` or `BLOCKED`, followed by the evidence checked and any concrete
fixes required. Missing, stale, ambiguous, or failed evidence always blocks.

## Required evidence

Validate all evidence against the exact candidate source commit. A later commit
that only records benchmark Markdown may name that source commit, but the gate
must prove the relationship and reject other intervening changes.

1. **Screenshots**
   - Require the project-designated 2D and vkcube/3D captures beneath the
     worktree's ignored `scratch_tmp/screenshots/` directory.
   - Validate that every required image is readable and nonempty; record its
     dimensions, byte size, SHA-256, capture command, UTC capture time, and
     source commit.
   - Visually inspect the images for the expected scene. A valid PNG header is
     not proof of a successful render.

2. **Twenty-second vkcube video**
   - Require the project-designated video beneath ignored
     `scratch_tmp/video/`. Prefer an open, high-compression codec and container
     such as VP9 in WebM.
   - Prove that the capture used ZPU's ICD and the intended vkcube workload.
   - Validate the file with `ffprobe` or the project's equivalent: exactly one
     decodable video stream, expected dimensions, nonzero frame rate and frame
     count, and duration within the project's narrow tolerance around 20
     seconds. Decode the full stream successfully.
   - Use the project's motion check to reject static, black, clear-only, or
     otherwise failed captures. Record codec/container, dimensions, duration,
     frame rate/count, byte size, SHA-256, commands, UTC time, and source
     commit.

3. **Complete benchmark history**
   - Require the repository's tracked `progress_benchmarks.md` and validate it
     with the project-provided gate rather than manually counting rows.
   - Require every implemented 2D and 3D benchmark metric/backend exactly once
     for the candidate source commit. Each row must include category, workload
     and schema version, resolution, metric, backend, value and unit, FPS when
     applicable, sampling method/count, source commit, UTC date, raw ignored
     artifact reference, and notes.
   - Require versioned raw machine-readable reports, correctness checksums, and
     the project's controlled CPU-affinity fingerprint. Reject placeholder,
     incomparable, duplicate, incomplete, failed, or stale results.
   - Do not treat a visual integration or video frame rate as a substitute for
     a genuine deterministic 3D performance benchmark.

## Hygiene and execution

- Never request GitHub workflow-scoped credentials or modify
  `.github/workflows/` to implement this readiness contract. Keep capture,
  validation, prerequisites, and evidence generation in repository-local
  commands, tests, and documentation that run with ordinary source access.
- Run the project-designated readiness command and its deterministic fixture
  tests. Do not reconstruct its rules with ad hoc shell searches.
- Run benchmark and visual workloads through ZPU's physical-core limiter or
  fanout worker contract.
- Use `git check-ignore`, `git status --short`, and `git ls-files` to prove that
  screenshots, video, logs, and raw benchmark reports are ignored, unstaged,
  and untracked. Only the Markdown summary and source/tooling changes may be
  tracked.
- Report exact commands, exit codes, source and evidence commit IDs, artifact
  paths, and validator output. An implementer's narrative is not evidence.

Return `READY` only when all three evidence groups and repository hygiene pass.
Otherwise return `BLOCKED` and turn each failure into a fix-task for the same
implementer before cross-review continues.

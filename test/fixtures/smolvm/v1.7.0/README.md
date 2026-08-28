<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# SmolVM CLI contract fixture

This strict argv/help/state fixture is a test double transcribed from the published upstream
`smol-machines/smolvm` **v1.7.0** Linux x86-64 release on 2026-08-25.

- release archive: `smolvm-1.7.0-linux-x86_64.tar.gz`
- release URL: `https://github.com/smol-machines/smolvm/releases/download/v1.7.0/smolvm-1.7.0-linux-x86_64.tar.gz`
- `smolvm-bin` SHA-256 (also recorded by the release's `checksums.txt`):
  `1e71774772e5a8684a92841e3b424c6883e4c806b1f8a017ccd5a2dc731c2919`
- captured commands: `smolvm --version`; `smolvm machine create --help`;
  `smolvm machine exec --help`; and `smolvm machine cp`, `stop`, `start`, and
  `update --help`; and `machine ls --help`/`--json`. Synthetic JSON variants
  exercise selection and fail-closed behavior; they are not claimed as captured
  runtime records. The fixture never invokes SmolVM or mutates a real machine.

The relevant published forms are:

```text
smolvm machine create [OPTIONS] [-- <COMMAND>...]
  --mount-socket <HOST_PATH:GUEST_PATH>
  --smolfile <PATH> (alias -s)
smolvm machine exec [OPTIONS] <COMMAND>...
smolvm machine cp <SRC> <DST>
smolvm machine stop --name <NAME>
smolvm machine update --name <NAME> --no-net
smolvm machine start --name <NAME>
```

The repository workflow intentionally uses no create workload, no volume flag,
and no exec `--stream`, even though the v1.7.0 help advertises those features.
The executable fixture rejects any flag outside the smaller audited subset.

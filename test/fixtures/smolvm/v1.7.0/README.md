<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# SmolVM CLI contract fixture

This strict argv/help/state fixture reports the production-pinned
`smol-machines/smolvm` **v1.16.1** version while retaining its historical
directory name so old fixture paths remain stable.

- production pin: `smolvm 1.16.1` (upstream tag `v1.16.1`, commit
  `9504e94e3581a1f52c414247edcbcd6d6b49a71a`)
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
and no exec `--stream`, even though the fixture help advertises those features.
The executable fixture rejects any flag outside the smaller audited subset.

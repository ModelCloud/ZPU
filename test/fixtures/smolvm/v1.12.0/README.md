# Real SmolVM 1.12.0 evidence

This is evidence from the real host binary, separate from the executable
v1.7.0 test double and its synthetic JSON records.

Captured on 2026-08-25 from `/home/ubuntu/.local/bin/smolvm`:

- `smolvm --version`: `smolvm 1.12.0`
- binary SHA-256: `30dced20e6ac5ac65d7713e0ff8986287901a63980d6037878eca07d652366a2`
- `machine create --help`: `--name`, `--image`, `--cpus`, `--mem`,
  `--mount-socket`, and `--smolfile`
- `machine start|stop|exec --help`: `--name`
- `machine update --help`: `--name`, `--net`, and `--no-net`
- `machine cp --help`: `<SRC> <DST>`
- `machine ls --help`: `--json`

The real lifecycle gate also recorded a unique `zpu-omarchy` machine with
`state: stopped`, `network: false`, `gpu: false`, and `mounts: 0`.

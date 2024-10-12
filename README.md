# manymatrix

Rust core library for Matrix clients, with a Dart/Flutter plugin and a CLI.

## Goals

- **Rust core** - Matrix Client-Server API, E2EE, sync, storage, rooms.
- **Flutter plugin** - Dart bindings via cbindgen + ffigen + cargokit.
- **CLI** - terminal client for testing and debugging.

## Layout

```
crates/
  core/         - matrix client library
  cli/          - CLI binary
  ffi/          - C API (cbindgen)
flutter_plugin/ - Dart/Flutter plugin and reference app
testing/        - E2E test harness (embedded, Docker, and Shadow tiers)
docs/           - research and architecture decisions
```

## Testing

- `cargo test -p test-harness` runs the default embedded Tuwunel tier without Docker.
- `cargo test -p test-harness --features docker-tests` re-enables the Docker Synapse and Docker Tuwunel tiers.
- `cargo test -p test-harness --test shadow --features shadow-tests -- --nocapture` runs the Shadow latency scenario.

Shadow requirements:

- Linux only.
- Build and run with dynamically linked `x86_64-unknown-linux-gnu` binaries; the Shadow harness verifies this with `ldd`.
- If you run Shadow inside Docker or another restricted container, use `seccomp=unconfined`.
- The system `shadow` binary must be installed and on `PATH`.

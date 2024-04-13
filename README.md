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
testing/        - E2E test harness (Docker homeservers)
docs/           - research and architecture decisions
```

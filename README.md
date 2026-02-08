# manymatrix

Rust core library for Matrix clients, with a Dart/Flutter plugin and a CLI.

## Goals

- **Rust core**, Matrix Client-Server API, E2EE, sync, storage, rooms.
- **Flutter plugin**, Dart bindings via cbindgen + ffigen + cargokit.
- **CLI**, terminal client for testing and debugging.

## Layout

```
crates/
  core/, matrix client library
  cli/, CLI binary
  ffi/, C API (cbindgen)
flutter_plugin/, Dart/Flutter plugin and reference app
testing/, E2E test harness (embedded, Docker, and Shadow tiers)
docs/, research and architecture decisions
```

## Testing

- `cargo test -p test-harness` runs the default embedded Tuwunel tier without Docker.
- `cargo test -p test-harness --features docker-tests` re-enables the Docker Synapse and Docker Tuwunel tiers.
- `cargo test -p test-harness --test shadow --features shadow-tests -- --nocapture` runs the Shadow latency scenario.

Deterministic compatibility commands are also available through the local wrapper:

- `scripts/compatibility.sh embedded` runs the default embedded tier.
- `scripts/compatibility.sh report` writes the embedded compatibility report to `target/compat/compatibility-report.json`.
- `scripts/compatibility.sh docker` runs the Docker opt-in report tier.
- `scripts/compatibility.sh shadow` runs optional Shadow latency, encrypted-message, and multi-homeserver scenarios.
- `scripts/compatibility.sh all-local` runs embedded plus report only; it intentionally excludes Docker and Shadow.

Shadow requirements:

- Linux only.
- Build and run with dynamically linked `x86_64-unknown-linux-gnu` binaries; the Shadow harness verifies this with `ldd`.
- If you run Shadow inside Docker or another restricted container, use `seccomp=unconfined`.
- The system `shadow` binary must be installed and on `PATH`.

Docker and Shadow are sufficient for local compatibility validation. Public federation is a deployment concern and requires DNS, TLS certificates, and a reverse proxy.

## Flutter Workspace

This project uses a Dart/Flutter workspace at the repository root.

See [docs/LOCAL_CONSUMPTION.md](docs/LOCAL_CONSUMPTION.md) for a guide on how to use the `manymatrix` plugin in your own local app.

### Tools

- **Melos**: For managing multi-package workflows.
- **Flutter Pub Workspace**: For dependency management with a single root lockfile.

### Workflows

| Command | Description | Tool |
|---------|-------------|------|
| `flutter pub get` | Bootstrap workspace and fetch dependencies | Pub |
| `dart run melos run analyze` | Run flutter analyze in all packages | Melos |
| `dart run melos run test` | Run flutter test in all packages | Melos |
| `dart run melos run test:integration` | Run Linux desktop integration smoke for the canonical example app | Melos |
| `dart run melos run build:web` | Build the canonical example app for web | Melos |
| `dart run melos run build:extension` | Build the Chrome extension package from the canonical example app | Melos |
| `dart run melos run codegen` | Run build_runner in all packages | Melos |
| `dart run melos run clean` | Run flutter clean in all packages | Melos |

The canonical example under `flutter_plugin/example/` now owns the web scaffold,
Chrome extension packaging assets, and Linux desktop integration smoke surface.
The plugin package itself remains native-first; browser packaging is restored as
an example-app regression surface rather than a published web plugin contract.

### Rust Workflows

| Command | Description | Tool |
|---------|-------------|------|
| `cargo build` | Build the Rust libraries and CLI | Cargo |
| `cargo test` | Run Rust tests | Cargo |

### Generated Artifact Policy

This project tracks generated artifacts (like FFI bindings and JSON serialization) in Git to ensure consistent behavior for consumers. 
If you modify Rust FFI signatures or models, you **must** update the generated code:

1.  Build Rust to update headers: `cargo build -p manymatrix-ffi`
2.  Run Flutter codegen: `dart run melos run codegen` (or `dart run build_runner build` in `flutter_plugin`)
3.  Commit both source and generated changes.

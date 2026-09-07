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
  web/, wasm-bindgen dispatcher for browser builds
flutter_plugin/, Dart/Flutter plugin and its example app
apps/
  ManyMatrix/, the ManyMatrix client app
  ManyMatrix.com/, the project website
testing/, E2E test harness (embedded, Docker, hosted, and Shadow tiers), web E2E, in-tree Tuwunel
vendor/, locally patched crates referenced from Cargo.toml's [patch] section
scripts/, compatibility, release, and web build wrappers
```

## Testing

- `cargo test -p test-harness` runs the default embedded Tuwunel tier without Docker.
- `cargo test -p test-harness --features docker-tests` re-enables the Docker tiers (Synapse, Tuwunel, Continuwuity, and Dendrite).
- `cargo test -p test-harness --test shadow --no-default-features --features shadow-tests -- --nocapture` runs the Shadow latency scenario.

Deterministic compatibility commands are also available through the local wrapper:

- `scripts/compatibility.sh embedded` runs the default embedded tier.
- `scripts/compatibility.sh report` writes the embedded compatibility report to `target/compat/compatibility-report.json`.
- `scripts/compatibility.sh docker` runs the Docker opt-in report tier.
- `scripts/compatibility.sh shadow` runs optional Shadow latency and encrypted-message scenarios.
- `scripts/compatibility.sh shadow-multi` explicitly runs the ignored Shadow multi-homeserver scenario; expect a long run on some hosts.
- `scripts/compatibility.sh all-local` runs embedded plus report only; it excludes Docker and Shadow.

Shadow requirements:

- Linux only.
- Build and run with dynamically linked `x86_64-unknown-linux-gnu` binaries; the Shadow harness verifies this with `ldd`.
- If you run Shadow inside Docker or another restricted container, use `seccomp=unconfined`.
- The system `shadow` binary must be installed and on `PATH`.

Docker and Shadow are sufficient for local compatibility validation. Public federation is a deployment concern and requires DNS, TLS certificates, and a reverse proxy.

## Consuming manymatrix-core

`manymatrix-core` is not yet published to crates.io, `cargo publish` is blocked on an
upstream `ruma-client-api` fix (see `CHANGELOG.md`). In the
meantime, depend on it directly via `git`:

```toml
[dependencies]
manymatrix-core = { git = "https://github.com/sneurlax/manymatrix", rev = "<commit-sha>" }
```

This works today without any extra patching on the consumer side: the workspace-local
`[patch.crates-io.ruma-client-api]` vendor patch (needed for our own build, which sets
`--cfg ruma_unstable_exhaustive_types` via `.cargo/config.toml`) does not apply to, and
is not needed by, downstream consumers, since that `rustflag` is scoped to this
repository's own build tree. `scripts/verify_git_dependency.sh` regression-tests this
path by scaffolding a scratch crate that depends on `manymatrix-core` via `git` and
running `cargo check` against it.

## Flutter Workspace

This project uses a Dart/Flutter workspace at the repository root.

The ManyMatrix app also resolves `../../../ManyUI` as a sibling checkout. CI
must define `MANYUI_CHECKOUT_TOKEN` as a read-only token that can clone the
private `sneurlax/manyui` repository. The workflows pin the compatible ManyUI
revision directly as a full commit SHA. Push coordinated ManyUI changes first,
then update that workflow pin before running the Matrix Flutter or web E2E
lanes. The jobs check out this repository as `ManyMatrix/` and ManyUI beside it
as `ManyUI/`.

See [flutter_plugin/README.md](flutter_plugin/README.md) for how to use the `manymatrix` plugin as a `path:` dependency in your own app.

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

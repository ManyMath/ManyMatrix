# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
is workspace-wide (all publishable crates share one version, see
`scripts/release.sh`).

## [Unreleased]

- **Fix: key backup restore silently recovered zero room keys.** `matrix-sdk`
  defaults `EncryptionSettings::backup_download_strategy` to `Manual`, so
  `ManyMatrixClient::restore_key_backup` (`client.encryption().recovery().recover()`)
  imported cross-signing secrets but never actually downloaded any room keys
  from the server-side backup, a new device recovering from a recovery key
  would report success while remaining unable to decrypt any pre-existing
  history. This was masked by the existing `key_backup_media.rs` test only
  asserting that `restore_key_backup` didn't error, never checking that the
  restored client could actually decrypt anything (a known "stretch goal"
  gap from Phase 7). Fixed by building every `ManyMatrixClient` with
  `BackupDownloadStrategy::OneShot`, and by adding `wait_for_backup_upload()`
  (wraps `backups().wait_for_steady_state()`) so tests/callers can
  deterministically wait for a just-created room key to finish uploading
  before a second device tries to restore it, instead of racing the
  background upload task via repeated `sync_once` polling. The test now
  asserts the restored client decrypts the original message body.
- Real internet-federation test (COMP-06): `testing/test-harness/tests/hosted_federation.rs`
  creates a public aliased room on one permanently hosted server
  (`synapse.manymatrix.com` or `tuwunel.manymatrix.com`) and joins it by
  full alias from a client on the *other* hosted server, in both
  directions, a cross-domain join and message delivery that only
  succeeds via real server-to-server federation, closing the gap left by
  Shadow's simulated-network federation test. Picked up automatically by
  `scripts/compatibility.sh hosted`; no CI changes needed.
- Multi-host platform check (PLAT-01, partial): `.github/workflows/platform-check.yml`
  runs `cargo check` for `manymatrix-core`/`-cli`/`-ffi` on GitHub-hosted
  `windows-latest` and `macos-latest` runners (plus an `aarch64-apple-ios`
  cross-check), since the project's only self-hosted CI runner is Linux-only.
  Also adds an `android-check` job (GitHub-hosted `ubuntu-latest`, which ships
  a preinstalled Android SDK/NDK) running `cargo ndk -t arm64-v8a check` for
  `manymatrix-core`/`-ffi`, the local sandbox and the self-hosted Gitea
  runner both lack an NDK, confirmed by `cargo check --target
  aarch64-linux-android` failing on `aarch64-linux-android-clang: No such
  file or directory`, so this closes the "Android NDK cross-check" gap noted
  previously. Not yet exercised live — needs a push to the `origin` GitHub
  remote to run for the first time. Real device/simulator verification
  remains open.
- Expanded compatibility matrix (COMP-05): `ServerKind::ContinuwuityDocker`
  adds Continuwuity (actively-maintained conduwuit fork) as a third
  Docker-tier homeserver family alongside Synapse and Tuwunel, wired into
  `scripts/compatibility.sh docker`'s report. CI: new `docker-compat.yml`
  workflow runs the Docker-inclusive compatibility report on push to `dev`.
- Expanded compatibility matrix (COMP-05), cont'd: `ServerKind::DendriteDocker`
  adds Dendrite (Go reference implementation) as a fourth Docker-tier
  homeserver family. Generates a real `dendrite.yaml` + signing key via
  one-shot prep containers before starting the server, and registers users
  through Synapse's shared-secret admin API (which Dendrite also
  implements). All 10 `test-harness` e2e scenarios pass against it.
- Package/release metadata: real `[workspace.package]` fields, dual
  MIT/Apache-2.0 `LICENSE-*` files, this changelog, `scripts/release.sh`.
- Documented git dependency publishing path (PUB-01): `cargo publish` to
  crates.io is still blocked on an upstream `ruma-client-api` fix, but
  `manymatrix-core` can be consumed today via `git = "..."` without any
  extra patching, verified with a new `scripts/verify_git_dependency.sh`
  regression script and documented in a new README "Consuming
  manymatrix-core" section.

## [0.1.0] - pre-release history

Everything up to and including v1.3 shipped under the `0.1.0` workspace
version while the project was still finding its shape:

### v1.3: Hosted Homeservers & Web/Extension E2E (2026-07-02)

- Permanently hosted Synapse and Tuwunel instances (`synapse.manymatrix.com`,
  `tuwunel.manymatrix.com`) with a `hosted-tests` test-harness tier.
- Puppeteer-based web/extension E2E harness covering the push channel
  (`onMessage`/`onReaction`/`onReceipt`) end to end against real homeservers.
- Gitea Actions CI wiring both lanes on push to `dev`.

### Web Bridge Parity (2026-07-02)

- Full native bridge API surfaced on web/WASM, including the event push
  channel (`events.subscribe` -> offscreen document -> `chrome.runtime`
  broadcast -> Dart).

### v1.2: Server Compatibility and Spec Parity (2026-04-15)

- Compatibility baseline/report against Synapse; `matrix-sdk` upgraded to
  0.16.0; capability, authenticated-media, and refresh-token parity;
  deterministic self-hosted CI commands and explicit Shadow multi-homeserver
  coverage.

### v1.1: Embedded Tuwunel Tests (2026-04-08)

- In-process `tuwunel-embed` replacing Docker-based Tuwunel E2E tests as the
  default tier; Docker/Synapse tests gated behind a feature flag; Shadow
  network simulation tests.

### v1.0: MVP (2026-03-29)

- Rust core (`manymatrix-core`) wrapping `matrix-sdk`: auth, sync, rooms,
  all message types, E2EE (SAS, cross-signing, key backup), media, push.
- `manymatrix-cli` terminal client.
- `manymatrix-ffi` C ABI via cbindgen, Flutter plugin via ffigen + cargokit,
  reference Flutter chat app.
- Docker E2E tests against Synapse and Tuwunel.

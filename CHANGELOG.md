# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
is workspace-wide (all publishable crates share one version, see
`scripts/release.sh`).

## [Unreleased]

- Fix: `logout()` left the client reporting a live session: matrix-sdk keeps
  the revoked tokens in memory, so `logged_in()` stayed true and
  `current_session_json()` returned a dead session that a caller persisting
  on teardown would save and fail to restore with `M_UNKNOWN_TOKEN`. The
  client now tracks revocation itself and logs (instead of discarding) a
  failed store removal.
- Fix: thread replies reported their reply target inconsistently. Live
  `on_message` events never set `in_reply_to` for `m.thread` relations, while
  paginated events reported the thread fallback pointer as a real reply.
  Both paths now honour `is_falling_back`.
- Fix: the native FFI bridge had no `login_with_device_id` export, so the Dart
  bridge silently dropped `deviceId` and native re-authentication registered
  a new device against the existing crypto store. Added
  `manymatrix_login_with_device_id` and wired it into `login(deviceId:)`.
- Fix: media downloads leaked the 16-byte `FfiBuffer` box on every call;
  `ffi_free_buffer` now takes the pointer and frees both allocations (C
  header and Dart bindings regenerated).
- Fix: the Dart native bridge freed the Rust client on the main isolate while
  the worker isolate could still be blocked in an FFI call on the same
  handle. The free is now queued on the worker behind in-flight calls.
- Fix: web `auth.logout` never stopped the background sync loop, which kept
  long-polling with the revoked token and emitted a stray failure after
  logout. The web dispatcher also now classifies errors (`SerdeError`,
  `StorageError`) and emits `errorKind`/`errorDetails` on failed sync
  status like the native bridge does.
- Fix: `cancel_verification` could not cancel a request that had not reached
  the SAS stage; the `thread_index` bookkeeping sync no longer flips the
  user's presence to online; the sync message-logging handler is attached
  once per client instead of once per sync restart; `StoredSession::save`
  writes the token file with mode 0600; `ThreadSummary` and
  `PaginatedThreadMessages` are re-exported from `manymatrix-core`.
- Fix: `uploadMedia` on native sent the attachment through the isolate port
  as a boxed `List<int>` and copied it byte by byte; it now passes the
  `Uint8List` and bulk-copies.
- Fix: `manymatrix-cli login -s matrix.org` failed because only full URLs
  were accepted; a bare server name now gets an `https://` prefix.
- Build: dropped the unused `reqwest` 0.11 and `anyhow` dependencies from
  `manymatrix-core` (one fewer HTTP/TLS stack in the FFI cdylib) and cleared
  all clippy warnings in the workspace crates.
- CI: all workflows now trigger on `main` as well as `dev`; `hosted-e2e.yml`
  installs `libclang-dev` before building the embedded `web_e2e_actor`.
- Repo: `vendor/` is no longer listed in `.gitignore` (it is tracked on
  purpose); the superseded `vendor/ruma-client-api-0.22.0` copy is removed;
  README layout, test commands, and the plugin guide link were corrected.

- Fix: `docker-compat.yml`'s registration-retry flake (Continuwuity
  `Connection refused` despite the container already listening) recurred on
  `manytier-ci` even after the prior 90s retry budget, this occurrence
  needed more than 90s. Widened `post_json_with_retry`'s `MAX_ATTEMPTS` from
  90 to 240 (4 min); compiles clean, not yet re-verified live.
- Perf: `[profile.release]` had no size tuning at all, every publishable
  crate (including `manymatrix-ffi`, the cdylib cargokit ships to Flutter
  apps on every platform) built with default codegen settings and no debug
  info stripping, despite "binary size" being a stated project constraint
  since v1.0. Added `lto = true`, `codegen-units = 1`, `strip = "symbols"`.
  `panic` stays `"unwind"` (not `"abort"`, unlike cargokit's own
  `super_native_extensions` example profile) because `crates/web`'s `call()`
  dispatcher uses `catch_unwind()` to turn a panic into an `{err}` envelope
  instead of trapping the whole wasm module. Measured on
  `target/release/libmanymatrix_ffi.so`: 62.9 MiB unstripped (before) -> 37.1
  MiB (after), a 41% reduction; the binary is also now properly `stripped`
  per `file`.
  - Found and fixed a real regression along the way: with LTO enabled, rustc
    lowers large `memcpy`s to wasm bulk-memory ops (`memory.copy`) on
    `wasm32-unknown-unknown`, which the `wasm-opt` binary bundled with
    `wasm-pack` rejects by default (`wasm-validator error ... unexpected
    false: all used features should be allowed`), breaking `wasm-pack build
    --target web --release crates/web`. Fixed via
    `[package.metadata.wasm-pack.profile.release]` in `crates/web/Cargo.toml`
    (`wasm-opt = ["-O", "--enable-bulk-memory",
    "--enable-nontrapping-float-to-int"]`). Verified both locally and on
    `manytier-ci`'s `core-ci.yml` (`wasm-check` job green).
- Fix: `enable_recovery` and `wait_for_backup_upload` were fully implemented
  in `manymatrix-core` and covered by a real end-to-end test
  (`testing/test-harness/tests/key_backup_media.rs`), but had **no FFI
  export at all** (unlike the SAS/whoami gaps found previously, which at
  least had FFI+generated Dart C bindings), so neither the web dispatcher
  nor either Dart bridge could reach them either. Without `enable_recovery`
  there was no way for an app to generate/obtain a recovery key in
  the first place, even though `setupKeyBackup()`/`restoreKeyBackup()` were
  both already exposed; without `wait_for_backup_upload` there was no way to
  know when a freshly-created room key is safely durable in backup before a
  second device tries to restore it. Added
  `manymatrix_enable_recovery`/`manymatrix_wait_for_backup_upload` to
  `crates/ffi/src/crypto.rs` (regenerating `crates/ffi/binding.h` and
  `flutter_plugin/lib/bridge/bindings.dart`), `e2ee.enable_recovery`/
  `e2ee.wait_for_backup_upload` to `crates/web/src/dispatcher.rs`, and
  `enableRecovery()`/`waitForBackupUpload()` to both `native_bridge.dart`
  and `web_bridge.dart`.
- Fix: `start_sas`/`accept_sas`, the two middle steps of the six-step SAS
  device-verification flow (`start_verification` -> `accept_verification` ->
  `start_sas` -> `accept_sas` -> `get_sas_emojis` -> `confirm_sas`), were fully
  implemented in `manymatrix-core`/`manymatrix-ffi` and covered by a real
  end-to-end test (`testing/test-harness/tests/encryption.rs`'s
  `sas_verification`), but were never wired into the web/WASM dispatcher or
  either Dart bridge, a Flutter app following the rest of the exposed
  verification flow would fail at this missing step. Added
  `e2ee.start_sas`/`e2ee.accept_sas` to `crates/web/src/dispatcher.rs` and
  `startSas()`/`acceptSas()` to both `native_bridge.dart` and
  `web_bridge.dart`.
- Fix: `whoami` and `is_room_encrypted` were fully implemented in
  `manymatrix-core`/`manymatrix-ffi` (used by native platforms via the
  auto-generated C bindings) but had no equivalent on web/WASM and no
  wrapper in the Dart `ManyMatrixBridge` API on either platform, a Flutter
  app had no way to ask "who am I logged in as" or "is this room encrypted"
  at all. Added `auth.whoami` / `e2ee.is_encrypted` dispatcher cases to
  `crates/web/src/dispatcher.rs`, and `whoami()` / `isRoomEncrypted()`
  methods to both `native_bridge.dart` and `web_bridge.dart`.
- CI: `manytier-ci` runner environment gaps discovered by pushing
  `dev` for the first time since Phase 26 (previously-unpushed local work
  had never run on real CI). Fixed two: (1) missing `libclang-dev`, needed
  by `bindgen`/`zstd-sys` (pulled in transitively, likely via
  RocksDB/tuwunel-embed), added an install step to `core-ci.yml`'s
  `native-check` and `docker-compat.yml`'s `docker-tier`. (2) the runner's
  default 1024 file-descriptor `ulimit` is too low for the embedded-Tuwunel
  test tier (each instance opens many RocksDB/SQLite file handles), raised
  it in the `cargo test`/`compatibility.sh` steps of `core-ci.yml`,
  `docker-compat.yml`, and defensively in `hosted-e2e.yml`.
- COMP-06 real cross-domain federation test (`hosted_federation.rs`) verified
  live against both hosted servers (`synapse.manymatrix.com` /
  `tuwunel.manymatrix.com`): both directions pass, a public room created on
  one server federates a join-by-alias and a message round-trip to the other.
- `docker-compat.yml` observed failing on `manytier-ci` at commit `900ec6f9`
  (the Continuwuity job: bootstrap-token scrape succeeds, then the
  registration POST gets connection refused) but the identical scenario
  passes reliably run directly on the same box outside the nested Actions job
  container, a CI-environment-specific flake, not reproduced locally.
  Root cause not confirmed (most likely the Continuwuity container dying
  between the readiness probe and the registration POST under whatever makes
  that nested environment different). Hardened `start_continuwuity_docker` to
  attach the container's stdout/stderr tail to the error context on
  registration failure, so the next occurrence is diagnosable instead of a
  bare "connection refused".
- `docker-compat.yml`'s Continuwuity flake reproduced again on `manytier-ci`
  (commit `d8d5ce76`), this time with the log-tail diagnostic attached, which
  confirmed the actual mechanism: Continuwuity's own log showed it started
  and began "Listening on [0.0.0.0:6167]" in under a second, yet every one of
  the registration helper's 20 one-second retries against the mapped host
  port still got `Connection refused`, the container was up, but
  the nested runner's Docker port-publish path hadn't propagated to the job
  container yet. Widened `post_json_with_retry`'s retry budget from 20 to 90
  attempts (20s -> 90s) to absorb that propagation delay; this only affects
  the failure path; the successful registration flow used by every
  homeserver tier is unaffected. All 10 Continuwuity scenarios re-verified
  locally (`cargo test -p test-harness --test e2e --no-default-features
  --features docker-tests continuwuity_docker`).
- `hosted-e2e.yml`'s hosted homeserver tier failed on the same CI run
  (`federated_message_hosted_tuwunel_to_synapse` timed out waiting for a
  message that never arrived). Root cause: the test called
  `bob.sync_once()` exactly once, then waited on a channel with nothing
  left to feed it, if real cross-domain federation delivered the message
  after that single sync round, the event handler never got another chance
  to fire. Replaced with `receive_federated_message_with_retry`, which
  re-syncs between checks instead of syncing once and hoping. Verified live
  against both hosted servers directly: both directions pass in 3.67s.

## [0.2.0] - 2026-07-03

- **Fix: key backup restore silently recovered zero room keys.** `matrix-sdk`
  defaults `EncryptionSettings::backup_download_strategy` to `Manual`, so
  `ManyMatrixClient::restore_key_backup` (`client.encryption().recovery().recover()`)
  imported cross-signing secrets but never downloaded any room keys
  from the server-side backup, a new device recovering from a recovery key
  would report success while remaining unable to decrypt any pre-existing
  history. This was masked by the existing `key_backup_media.rs` test only
  asserting that `restore_key_backup` didn't error, never checking that the
  restored client could decrypt anything (a known "stretch goal"
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
  previously. **Still not exercised live**: the `origin` GitHub remote
  (`sneurlax/manymatrix`) doesn't exist yet, so this workflow has never
  run, creating that repository and pushing to it is a one-time
  manual/account-level step, not something this automation can do for
  itself. Real device/simulator verification remains open regardless.
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

- Full native bridge APId on web/WASM, including the event push
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

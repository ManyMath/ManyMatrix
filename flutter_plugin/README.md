# manymatrix

ManyMatrix Flutter plugin powered by Rust core via FFI.

## Overview

This is the core Flutter plugin package for ManyMatrix. It provides the Dart FFI bridge to the Rust implementation of the Matrix client.

## Supported Platforms

- **Android**: via FFI (Rust shared library)
- **iOS**: via FFI (Rust shared library)
- **Linux**: via FFI (Rust shared library)
- **macOS**: via FFI (Rust shared library)
- **Windows**: via FFI (Rust shared library)

- **Web**: via `lib/src/web_bridge.dart`. Ordinary sites use a dedicated module
  Worker and WASM instance per client. Chrome extensions are capability-detected
  and retain the MV3 offscreen-document transport. The canonical example app at
  `flutter_plugin/example/` owns the extension packaging and E2E regression
  workflow (see `testing/web-e2e/`); `apps/ManyMatrix/tool/build_web.dart`
  packages the ordinary browser release.

Ordinary-site sessions are stored in `sessionStorage`, not `localStorage`, so
they survive reload only within the current tab. Extension sessions use the
extension's isolated storage. `ManyMatrixBridge.close()` is awaitable; account
cleanup waits for Worker acknowledgement before removing the Matrix SDK's
account-scoped IndexedDB databases.
Upgrading from the former single-session extension storage forces one new
sign-in: extension startup removes the legacy global bearer token and its
URL-derived state/crypto/backup databases before opening a Worker. It does not
copy that token into an empty account-scoped crypto store. The offscreen host
and WASM resources are extension-internal and must not be declared as
web-accessible resources.
Cleanup attempts every discovered state/crypto/backup database even if one is
blocked. Browsers without `indexedDB.databases()` cannot enumerate timestamped
SDK backup stores, so they return a retryable cleanup error after deleting all
deterministic stores rather than claiming complete removal.

`MessageEvent.mediaSource` preserves either the plain MXC source or the full
encrypted attachment descriptor. `ManyMatrixBridge.downloadMediaSource()`
passes that descriptor to the Rust core for authenticated, refresh-aware
streaming download and verified decryption on native and web runtimes. The
response stream is capped at 25 MiB before bridge/base64 amplification.
Media RPCs use a five-minute transport deadline across ordinary Worker and MV3
offscreen layers so slow uploads are not reported as failed while continuing in
the background.

## Local Consumption Policy

This package is not currently published to pub.dev (`publish_to: 'none'`), by deliberate choice rather than
a technical blocker, cargokit-based plugins (e.g. `super_native_extensions`) do publish successfully despite
fetching Rust source at build time, so nothing about this plugin's architecture prevents publishing later.
`pubspec.yaml` already carries `homepage`/`repository`/`issue_tracker`/`topics` and a package-local `LICENSE`
(dual MIT/Apache-2.0, matching the Rust workspace) so the package is publish-ready metadata-wise. What remains
before an actual `flutter pub publish` are human decisions: reserving/confirming the `manymatrix` name is free
on pub.dev, deciding whether to sync this package's version scheme with the Rust workspace version instead of
its current independent `1.0.0+1`, and owning the pub.dev publisher account that would perform the (irreversible)
publish. Until those are made, use it as a `path:` dependency in your `pubspec.yaml`:

```yaml
dependencies:
  manymatrix:
    path: ../manymatrix/flutter_plugin
```

## Public API

The primary entrypoint for the plugin is:
```dart
import 'package:manymatrix/manymatrix.dart';
```

Exposed core classes:
- `ManyMatrixBridge`: The main interface to the Rust core.
- Models: `RoomSummary`, `MessageEvent`, `PaginatedMessages`,
  `ThreadSummary`, and `PaginatedThreadMessages`.

Thread APIs are available on native and web bridges:

- `threadIndex()` returns homeserver-authoritative reply aggregates across
  joined rooms. `ThreadSummary.unreadCount == null` means unread-thread state
  could not be established; consumers must not present it as zero.
- `getThreadMessages()` pages a root's recursive relations, including edits.
- `sendThreadReadReceipt()` advances a receipt scoped to the supplied thread
  root rather than the room's main timeline.

Servers may omit `/threads`. Treat a thread-index error as a capability failure;
room timelines and direct `/relations` thread access remain usable.

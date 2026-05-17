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

- **Web / Chrome extension**: via `lib/src/web_bridge.dart` (WASM bridge over an offscreen document +
  `chrome.runtime` broadcast for the event push channel). The canonical example app at
  `flutter_plugin/example/` owns the web scaffold, Linux integration smoke, and MV3 extension packaging
  workflow used for E2E regression verification (see `testing/web-e2e/`).

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
- Models: `RoomSummary`, `MessageEvent`, `PaginatedMessages`, etc.

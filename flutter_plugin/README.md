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

The current v1.5 workspace snapshot is not configured for Flutter web or the
Chrome extension flow as a plugin consumer target. The canonical example app at
`flutter_plugin/example/` owns the restored web scaffold, Linux integration
smoke, and MV3 extension packaging workflow used for Phase 38 regression
verification.

## Local Consumption Policy

This package is intended for **local consumption only**. It is not published to pub.dev. 
To use this plugin in your Flutter app, add it as a `path:` dependency in your `pubspec.yaml`:

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

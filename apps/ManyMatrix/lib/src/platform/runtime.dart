/// Platform-conditional runtime facts for the manymatrix native bridge.
///
/// Native platforms load the Rust FFI library built by cargokit; the web
/// bridge exists but is non-functional at runtime, so the web variant gates
/// the app behind a "coming soon" notice.
library;

export 'runtime_native.dart' if (dart.library.js_interop) 'runtime_web.dart';

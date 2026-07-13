/// Platform-conditional runtime facts for the manymatrix native bridge.
///
/// Native platforms load the Rust FFI library built by cargokit; browsers run
/// the Rust WASM core in a dedicated module Worker.
library;

export 'runtime_native.dart' if (dart.library.js_interop) 'runtime_web.dart';

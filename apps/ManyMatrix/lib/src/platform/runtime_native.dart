import 'dart:io';

/// Whether the manymatrix runtime works on this platform.
const bool matrixRuntimeSupported = true;

/// Human-readable reason shown when [matrixRuntimeSupported] is false.
const String? matrixRuntimeUnsupportedReason = null;

/// Path passed to `ManyMatrixBridge.initialize`.
///
/// Cargokit bundles the Rust library next to the executable (or links it on
/// iOS), so the bare library name resolves through the platform loader.
String defaultLibraryPath() {
  if (Platform.isLinux || Platform.isAndroid) {
    return 'libmanymatrix_ffi.so';
  }
  if (Platform.isMacOS) {
    return 'libmanymatrix_ffi.dylib';
  }
  if (Platform.isWindows) {
    return 'manymatrix_ffi.dll';
  }
  if (Platform.isIOS) {
    return '';
  }
  throw UnsupportedError(
    'manymatrix is not supported on ${Platform.operatingSystem}',
  );
}

/// Directory handed to the Rust SDK for its persistent store.
///
/// TODO(manymatrix): use a real per-app support directory (path_provider's
/// getApplicationSupportDirectory) instead of the system temp dir.
String defaultStorePath() {
  final dir = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}manymatrix_app_store',
  );
  dir.createSync(recursive: true);
  return dir.path;
}

import 'dart:io';

/// Whether the manymatrix runtime works on this platform.
const bool matrixRuntimeSupported = true;

/// Native hosts persist the exported session through the app layer.
const bool matrixBridgeOwnsSessionPersistence = false;

/// Native clients are not subject to browser mixed-content restrictions.
String? homeserverSecurityError(String value) => null;

/// Human-readable reason shown when [matrixRuntimeSupported] is false.
const String? matrixRuntimeUnsupportedReason = null;

/// Path passed to `ManyMatrixBridge.initialize`.
///
/// Cargokit bundles the Rust library next to the executable on Linux/
/// Android/Windows, so the bare library name resolves through the platform
/// loader there. On macOS/iOS the Runner app target force-loads the static
/// lib directly into the executable (see macos/ios Podfile), so the empty
/// path tells native_bridge.dart to use `DynamicLibrary.process()` instead
/// of opening a standalone .dylib that is never produced.
String defaultLibraryPath() {
  if (Platform.isLinux || Platform.isAndroid) {
    return 'libmanymatrix_ffi.so';
  }
  if (Platform.isWindows) {
    return 'manymatrix_ffi.dll';
  }
  if (Platform.isMacOS || Platform.isIOS) {
    return '';
  }
  throw UnsupportedError(
    'manymatrix is not supported on ${Platform.operatingSystem}',
  );
}

/// Directory handed to the Rust SDK for its persistent store.
///
/// Scoped per [accountId] so that multiple accounts never share a store
/// (sharing one path across accounts would corrupt each other's state).
///
/// TODO(manymatrix): use a real per-app support directory (path_provider's
/// getApplicationSupportDirectory) instead of the system temp dir.
String defaultStorePath(String accountId) {
  final safeId = accountId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  final dir = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'manymatrix_app_store${Platform.pathSeparator}$safeId',
  );
  dir.createSync(recursive: true);
  return dir.path;
}

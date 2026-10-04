import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'store_location.dart';

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

final _storeLocator = AccountStoreLocator(
  root: () async => Directory(
    p.join(
      (await getApplicationSupportDirectory()).path,
      accountStoresDirectoryName,
    ),
  ),
  legacyRoot: Directory(
    p.join(Directory.systemTemp.path, accountStoresDirectoryName),
  ),
  onMigrationError: (error, stackTrace) => debugPrint(
    'ManyMatrix could not move a Matrix store out of the temp directory: '
    '$error',
  ),
);

/// Directory handed to the Rust SDK for [accountId]'s persistent store.
///
/// Lives under the application support directory, not a temp or cache
/// directory the OS may clear: the store holds the E2EE device keys and
/// sessions the saved login depends on. Scoped per [accountId] so that
/// multiple accounts never share a store (sharing one path across accounts
/// would corrupt each other's state). Stores left in the system temp
/// directory by earlier builds are moved here on first use.
Future<String> defaultStorePath(String accountId) =>
    _storeLocator.pathFor(accountId);

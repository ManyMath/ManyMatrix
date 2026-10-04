import 'dart:io';

import 'package:manymatrix/manymatrix.dart';

Future<void> initializeExampleBridge() async {
  final String libraryPath;
  if (Platform.isLinux || Platform.isAndroid) {
    libraryPath = 'libmanymatrix_ffi.so';
  } else if (Platform.isWindows) {
    libraryPath = 'manymatrix_ffi.dll';
  } else if (Platform.isMacOS || Platform.isIOS) {
    libraryPath = '';
  } else {
    throw UnsupportedError('Unsupported platform');
  }

  await ManyMatrixBridge.initialize(libraryPath);
}

/// A fresh store directory for each login.
///
/// Logout deletes the store directory recursively, so it must never be the
/// shared temp directory itself. The example never restores a saved session,
/// so every login is a new device and needs an empty store anyway.
String exampleStorePath() =>
    Directory.systemTemp.createTempSync('manymatrix_example_store_').path;

String? exampleRuntimeWarning() => null;

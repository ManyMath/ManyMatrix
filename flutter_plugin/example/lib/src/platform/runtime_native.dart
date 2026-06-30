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

String exampleStorePath() => Directory.systemTemp.path;

String? exampleRuntimeWarning() => null;

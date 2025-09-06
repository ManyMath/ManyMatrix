import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/native_bridge.dart';
import 'src/router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Determine native library path per platform
  final String libraryPath;
  if (Platform.isLinux) {
    libraryPath = 'libmanymatrix_ffi.so';
  } else if (Platform.isAndroid) {
    libraryPath = 'libmanymatrix_ffi.so';
  } else if (Platform.isMacOS) {
    libraryPath = 'libmanymatrix_ffi.dylib';
  } else if (Platform.isWindows) {
    libraryPath = 'manymatrix_ffi.dll';
  } else if (Platform.isIOS) {
    // iOS uses statically linked library -- pass empty string,
    // native_bridge uses DynamicLibrary.process() for iOS
    libraryPath = '';
  } else {
    throw UnsupportedError('Unsupported platform');
  }

  // Initialize spawns the worker isolate -- must await
  await ManyMatrixBridge.initialize(libraryPath);

  runApp(
    const ProviderScope(
      child: ManyMatrixApp(),
    ),
  );
}

/// Root application widget using GoRouter for navigation.
class ManyMatrixApp extends ConsumerWidget {
  const ManyMatrixApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Matrix Client',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      routerConfig: router,
    );
  }
}

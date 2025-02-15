import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'src/platform/runtime.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeExampleBridge();

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

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';
import 'package:manyui_riverpod/manyui_riverpod.dart';

import 'login/login_page.dart';
import 'matrix/account.dart';
import 'matrix/auth.dart';
import 'matrix/providers.dart';
import 'rooms/rooms_page.dart';
import 'theme.dart';

class ManyMatrixApp extends ConsumerWidget {
  const ManyMatrixApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watchMThemeMode(themeModeProvider);
    // This provider loads persisted accounts once at startup. Mutations write
    // durably through AccountsController before publishing provider state.
    ref.watch(accountsLoaderProvider);
    return MWidgetsApp(
      title: 'ManyMatrix',
      theme: manyMatrixLightTheme(),
      darkTheme: manyMatrixDarkTheme(),
      themeMode: mode,
      debugShowCheckedModeBanner: false,
      home: const AuthGate(),
    );
  }
}

/// Routes the shell by authentication state: splash while restoring a
/// persisted session, login when signed out, rooms when signed in.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    return switch (auth) {
      AuthRestoring() => const _RestoringSplash(),
      AuthAuthenticated() => const RoomsPage(),
      AuthUnauthenticated() ||
      AuthAuthenticating() ||
      AuthRecoveryNeeded() => const LoginPage(),
    };
  }
}

class _RestoringSplash extends StatelessWidget {
  const _RestoringSplash();

  @override
  Widget build(BuildContext context) {
    return const MScaffold(
      body: Center(
        child: MLoadingState(
          message: 'Restoring session...',
          semanticLabel: 'Restoring session',
        ),
      ),
    );
  }
}

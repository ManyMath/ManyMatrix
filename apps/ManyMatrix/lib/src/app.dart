import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';

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
    final mode = ref.watch(themeModeProvider);
    // Neither provider holds widget-visible state -- watching just
    // instantiates them: one loads persisted accounts at startup, the other
    // listens for changes and writes them back.
    ref.watch(accountsLoaderProvider);
    ref.watch(accountsPersistenceProvider);
    return MWidgetsApp(
      title: 'ManyMatrix',
      theme: MThemeData.light(),
      darkTheme: MThemeData.dark(),
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
      AuthUnauthenticated() || AuthAuthenticating() => const LoginPage(),
    };
  }
}

class _RestoringSplash extends StatelessWidget {
  const _RestoringSplash();

  @override
  Widget build(BuildContext context) {
    final theme = MTheme.of(context);
    return MScaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const MCircularProgress.indeterminate(
              semanticLabel: 'Restoring session',
            ),
            const SizedBox(height: 16),
            Text(
              'Restoring session…',
              style: theme.typography.bodySmall
                  .copyWith(color: theme.colors.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';
import 'package:manyui_riverpod/manyui_riverpod.dart';

import '../matrix/auth.dart';
import '../matrix/providers.dart';
import '../platform/runtime.dart';
import '../theme.dart';

const _defaultHomeserver = 'https://matrix.org';

/// Landing page: sign in to a Matrix homeserver.
class LoginPage extends HookConsumerWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final homeserver = useState('');
    final username = useState('');
    final password = useState('');

    final auth = ref.watch(authControllerProvider);
    final signingIn = auth is AuthAuthenticating;
    final error = auth is AuthUnauthenticated ? auth.error : null;

    void submit() {
      if (signingIn || !matrixRuntimeSupported) return;
      final server = homeserver.value.trim().isEmpty
          ? _defaultHomeserver
          : homeserver.value.trim();
      if (username.value.trim().isEmpty || password.value.isEmpty) return;
      ref
          .read(authControllerProvider.notifier)
          .signIn(
            homeserverUrl: server,
            username: username.value.trim(),
            password: password.value,
          );
    }

    return MScaffold(
      header: MAppHeader(
        title: 'ManyMatrix',
        actions: <Widget>[
          MButton(
            variant: MButtonVariant.ghost,
            onPressed: () => ref.toggleMThemeMode(themeModeProvider),
            semanticLabel: 'Toggle theme',
            child: MIcon(
              ref.watchMThemeMode(themeModeProvider) == MThemeMode.dark
                  ? MIconData.sun
                  : MIconData.moon,
            ),
          ),
        ],
      ),
      body: Center(
        // Scrollable so short windows (and error states) never clip the card.
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: MCard(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: matrixRuntimeSupported
                    ? _buildForm(
                        homeserver: homeserver,
                        username: username,
                        password: password,
                        signingIn: signingIn,
                        error: error,
                        onSubmit: submit,
                      )
                    : _buildWebGate(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm({
    required ValueNotifier<String> homeserver,
    required ValueNotifier<String> username,
    required ValueNotifier<String> password,
    required bool signingIn,
    required String? error,
    required VoidCallback onSubmit,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const MSectionHeader(
          title: 'Sign in to Matrix',
          description: 'Connect to your homeserver to get started.',
        ),
        const SizedBox(height: 24),
        const MLabel('Homeserver'),
        const SizedBox(height: 8),
        MTextField(
          placeholder: _defaultHomeserver,
          semanticLabel: 'Homeserver',
          enabled: !signingIn,
          onChanged: (value) => homeserver.value = value,
        ),
        const SizedBox(height: 16),
        const MLabel('Username'),
        const SizedBox(height: 8),
        MTextField(
          placeholder: 'Username',
          semanticLabel: 'Username',
          enabled: !signingIn,
          onChanged: (value) => username.value = value,
        ),
        const SizedBox(height: 16),
        const MLabel('Password'),
        const SizedBox(height: 8),
        MTextField(
          obscureText: true,
          placeholder: 'Password',
          semanticLabel: 'Password',
          enabled: !signingIn,
          error: error != null,
          onChanged: (value) => password.value = value,
          onSubmitted: (_) => onSubmit(),
        ),
        if (error != null) ...<Widget>[
          const SizedBox(height: 12),
          MAlert(variant: MAlertVariant.destructive, message: error),
        ],
        const SizedBox(height: 24),
        MButton(
          onPressed: signingIn ? null : onSubmit,
          child: signingIn
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: MCircularProgress.indeterminate(),
                    ),
                    SizedBox(width: 8),
                    Text('Signing in…'),
                  ],
                )
              : const Text('Sign in'),
        ),
      ],
    );
  }

  Widget _buildWebGate() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MSectionHeader(
          title: 'Matrix on web coming soon',
          description:
              matrixRuntimeUnsupportedReason ??
              'This platform cannot run the Matrix bridge yet.',
        ),
      ],
    );
  }
}

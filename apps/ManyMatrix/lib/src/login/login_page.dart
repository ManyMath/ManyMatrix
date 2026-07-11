import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';
import 'package:manyui_riverpod/manyui_riverpod.dart';

import '../accounts/accounts_dialog.dart';
import '../matrix/auth.dart';
import '../matrix/account.dart';
import '../matrix/providers.dart';
import '../platform/runtime.dart';
import '../theme.dart';

const _defaultHomeserver = 'https://matrix.org';

/// Landing page: sign in to a Matrix homeserver.
class LoginPage extends HookConsumerWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final homeserver = useMemoized(() => MController<String>(''));
    final username = useMemoized(() => MController<String>(''));
    final password = useMemoized(() => MController<String>(''));
    useEffect(() {
      return () {
        homeserver.dispose();
        username.dispose();
        password.dispose();
      };
    }, const []);
    final homeserverFocus = useFocusNode();
    final usernameFocus = useFocusNode();
    final passwordFocus = useFocusNode();

    final auth = ref.watch(authControllerProvider);
    final busy = auth is AuthAuthenticating || auth is AuthRestoring;
    final reauth = auth is AuthNeedsReauth ? auth : null;
    final reconnect = auth is AuthNeedsReconnect ? auth : null;
    final recovery = auth is AuthRecoveryNeeded ? auth : null;
    final accounts = ref.watch(accountsProvider);
    final error = auth is AuthUnauthenticated ? auth.error : reauth?.message;

    useEffect(() {
      if (recovery == null) return null;
      homeserver.value = recovery.homeserverUrl;
      username.value = recovery.suggestedUsername;
      return null;
    }, <Object?>[recovery?.accountId, recovery?.homeserverUrl]);

    void submit() {
      if (busy || !matrixRuntimeSupported) return;
      final server = homeserver.value.trim().isEmpty
          ? _defaultHomeserver
          : homeserver.value.trim();
      if (username.value.trim().isEmpty || password.value.isEmpty) return;
      final controller = ref.read(authControllerProvider.notifier);
      if (reauth != null) {
        controller.reauthenticateActive(
          username: username.value.trim(),
          password: password.value,
        );
      } else {
        controller.signIn(
          homeserverUrl: server,
          username: username.value.trim(),
          password: password.value,
        );
      }
    }

    return MScaffold(
      header: MAppHeader(
        title: 'ManyMatrix',
        actions: <Widget>[
          if (accounts.isNotEmpty)
            MButton(
              variant: MButtonVariant.ghost,
              onPressed: () => showAccountsDialog(context),
              child: const Text('Accounts'),
            ),
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
                    ? reconnect == null
                          ? _buildForm(
                              homeserver: homeserver,
                              username: username,
                              password: password,
                              homeserverFocus: homeserverFocus,
                              usernameFocus: usernameFocus,
                              passwordFocus: passwordFocus,
                              signingIn: busy,
                              error: error,
                              recovery: reauth,
                              onSubmit: submit,
                            )
                          : _buildReconnect(
                              reconnect: reconnect,
                              busy: busy,
                              onReconnect: () => ref
                                  .read(authControllerProvider.notifier)
                                  .reconnectActive(),
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
    required MController<String> homeserver,
    required MController<String> username,
    required MController<String> password,
    required FocusNode homeserverFocus,
    required FocusNode usernameFocus,
    required FocusNode passwordFocus,
    required bool signingIn,
    required String? error,
    required AuthNeedsReauth? recovery,
    required VoidCallback onSubmit,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MSectionHeader(
          title: recovery == null ? 'Sign in to Matrix' : 'Sign in again',
          description: recovery == null
              ? 'Connect to your homeserver to get started.'
              : 'Reconnect ${recovery.label} on ${recovery.homeserverUrl}.',
        ),
        const SizedBox(height: 24),
        MField(
          label: 'Homeserver',
          focusNode: homeserverFocus,
          enabled: !signingIn,
          child: MTextField(
            controller: homeserver,
            focusNode: homeserverFocus,
            placeholder: _defaultHomeserver,
            semanticLabel: 'Homeserver',
            enabled: !signingIn,
            readOnly: recovery != null,
          ),
        ),
        const SizedBox(height: 16),
        MField(
          label: 'Username',
          focusNode: usernameFocus,
          enabled: !signingIn,
          child: MTextField(
            controller: username,
            focusNode: usernameFocus,
            placeholder: 'Username',
            semanticLabel: 'Username',
            enabled: !signingIn,
          ),
        ),
        const SizedBox(height: 16),
        MField(
          label: 'Password',
          focusNode: passwordFocus,
          enabled: !signingIn,
          child: MTextField(
            controller: password,
            focusNode: passwordFocus,
            obscureText: true,
            placeholder: 'Password',
            semanticLabel: 'Password',
            enabled: !signingIn,
            error: error != null,
            onSubmitted: (_) => onSubmit(),
          ),
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
                    Text('Signing in...'),
                  ],
                )
              : Text(recovery == null ? 'Sign in' : 'Sign in again'),
        ),
      ],
    );
  }

  Widget _buildReconnect({
    required AuthNeedsReconnect reconnect,
    required bool busy,
    required VoidCallback onReconnect,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MSectionHeader(
          title: 'Reconnect Matrix',
          description: '${reconnect.label} on ${reconnect.homeserverUrl}',
        ),
        const SizedBox(height: 16),
        MAlert(variant: MAlertVariant.destructive, message: reconnect.message),
        const SizedBox(height: 24),
        MButton(
          onPressed: busy ? null : onReconnect,
          child: const Text('Reconnect'),
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

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';
import 'package:manyui_riverpod/manyui_riverpod.dart';

import '../accounts/accounts_dialog.dart';
import '../branding.dart';
import '../matrix/auth.dart';
import '../matrix/account.dart';
import '../matrix/providers.dart';
import '../platform/homeserver_policy.dart';
import '../platform/runtime.dart';
import '../theme.dart';

const _defaultHomeserver = 'https://matrix.org';

/// Landing page: sign in to a Matrix homeserver.
class LoginPage extends HookConsumerWidget {
  const LoginPage({
    this.onCancel,
    this.restorePreviousAccountOnFailure = false,
    super.key,
  });

  final VoidCallback? onCancel;
  final bool restorePreviousAccountOnFailure;

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
    final validationAttempted = useState(false);
    final secondaryAccountError = useState<String?>(null);

    final homeserverValue = useValueListenable(homeserver);
    final usernameValue = useValueListenable(username);
    final passwordValue = useValueListenable(password);

    final auth = ref.watch(authControllerProvider);
    final busy = auth is AuthAuthenticating || auth is AuthRestoring;
    final reauth = auth is AuthNeedsReauth ? auth : null;
    final reconnect = auth is AuthNeedsReconnect ? auth : null;
    final recovery = auth is AuthRecoveryNeeded ? auth : null;
    final accounts = ref.watch(accountsProvider);
    final authError =
        secondaryAccountError.value ??
        (auth is AuthUnauthenticated ? auth.error : reauth?.message);
    final server = homeserverValue.trim().isEmpty
        ? _defaultHomeserver
        : homeserverValue.trim();
    final canonicalServer = canonicalHomeserverUrl(server);
    final serverValid = canonicalServer != null;
    final securityError = serverValid
        ? homeserverSecurityError(canonicalServer)
        : null;
    final homeserverError = validationAttempted.value
        ? !serverValid
              ? 'Enter a complete http:// or https:// homeserver URL.'
              : securityError
        : null;
    final usernameError =
        validationAttempted.value && usernameValue.trim().isEmpty
        ? 'Enter your Matrix username.'
        : null;
    final passwordError = validationAttempted.value && passwordValue.isEmpty
        ? 'Enter your password.'
        : null;
    final formValid =
        serverValid &&
        securityError == null &&
        usernameValue.trim().isNotEmpty &&
        passwordValue.isNotEmpty;

    useEffect(() {
      if (recovery == null) return null;
      homeserver.value = recovery.homeserverUrl;
      username.value = recovery.suggestedUsername;
      return null;
    }, <Object?>[recovery?.accountId, recovery?.homeserverUrl]);

    void submit() {
      if (busy || !matrixRuntimeSupported) return;
      validationAttempted.value = true;
      if (!formValid) {
        if (!serverValid) {
          homeserverFocus.requestFocus();
        } else if (usernameValue.trim().isEmpty) {
          usernameFocus.requestFocus();
        } else {
          passwordFocus.requestFocus();
        }
        return;
      }
      secondaryAccountError.value = null;
      final controller = ref.read(authControllerProvider.notifier);
      if (reauth != null) {
        unawaited(() async {
          await controller.reauthenticateActive(
            username: usernameValue.trim(),
            password: passwordValue,
          );
          if (context.mounted &&
              ref.read(authControllerProvider) is AuthAuthenticated) {
            TextInput.finishAutofillContext();
          }
        }());
      } else {
        unawaited(() async {
          final error = await controller.signIn(
            homeserverUrl: canonicalServer,
            username: usernameValue.trim(),
            password: passwordValue,
            restorePreviousAccountOnFailure: restorePreviousAccountOnFailure,
          );
          if (context.mounted &&
              restorePreviousAccountOnFailure &&
              error != null) {
            secondaryAccountError.value = error;
          }
          if (context.mounted && error == null) {
            TextInput.finishAutofillContext();
          }
        }());
      }
    }

    return MScaffold(
      header: MAppHeader(
        compactBreakpoint: accounts.isEmpty ? 340 : 520,
        title: 'ManyMatrix',
        leading: onCancel == null
            ? const ManyMatrixMark(size: 28)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  MIconButton(
                    icon: MIconData.chevronLeft,
                    label: 'Cancel adding account',
                    onPressed: busy ? null : onCancel,
                  ),
                  const SizedBox(width: 8),
                  const ManyMatrixMark(size: 28),
                ],
              ),
        actions: <Widget>[
          if (accounts.isNotEmpty)
            MButton(
              variant: MButtonVariant.ghost,
              onPressed: busy ? null : () => showAccountsDialog(context),
              child: const Text('Accounts'),
            ),
          MIconButton(
            onPressed: () => ref.toggleMThemeMode(themeModeProvider),
            label: 'Toggle theme',
            icon: ref.watchMThemeMode(themeModeProvider) == MThemeMode.dark
                ? MIconData.sun
                : MIconData.moon,
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: MCard(
              style: const MCardStyleDelta(padding: EdgeInsets.zero),
              child: Padding(
                padding: const EdgeInsets.all(28),
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
                              authError: authError,
                              homeserverError: homeserverError,
                              usernameError: usernameError,
                              passwordError: passwordError,
                              formValid: formValid,
                              validationAttempted: validationAttempted.value,
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
    required String? authError,
    required String? homeserverError,
    required String? usernameError,
    required String? passwordError,
    required bool formValid,
    required bool validationAttempted,
    required AuthNeedsReauth? recovery,
    required VoidCallback onSubmit,
  }) {
    return AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          MSectionHeader(
            title: recovery == null ? 'Sign in to Matrix' : 'Sign in again',
            description: recovery == null
                ? 'Connect to your homeserver to get started.'
                : 'Reconnect ${recovery.label} on ${recovery.homeserverUrl}.',
            leading: const ManyMatrixMark(size: 42),
          ),
          const SizedBox(height: 24),
          MField(
            label: 'Homeserver',
            focusNode: homeserverFocus,
            enabled: !signingIn,
            description: recovery == null
                ? 'Leave blank to use matrix.org.'
                : null,
            errorText: homeserverError,
            child: MTextField(
              controller: homeserver,
              focusNode: homeserverFocus,
              placeholder: _defaultHomeserver,
              semanticLabel: 'Homeserver',
              enabled: !signingIn,
              readOnly: recovery != null,
              error: homeserverError != null,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              autofillHints: const <String>[AutofillHints.url],
              onSubmitted: (_) => usernameFocus.requestFocus(),
            ),
          ),
          const SizedBox(height: 16),
          MField(
            label: 'Username',
            focusNode: usernameFocus,
            enabled: !signingIn,
            errorText: usernameError,
            child: MTextField(
              controller: username,
              focusNode: usernameFocus,
              placeholder: 'Username',
              semanticLabel: 'Username',
              enabled: !signingIn,
              error: usernameError != null,
              textInputAction: TextInputAction.next,
              autofillHints: const <String>[AutofillHints.username],
              onSubmitted: (_) => passwordFocus.requestFocus(),
            ),
          ),
          const SizedBox(height: 16),
          MField(
            label: 'Password',
            focusNode: passwordFocus,
            enabled: !signingIn,
            errorText: passwordError,
            child: MSecretField(
              controller: password,
              focusNode: passwordFocus,
              placeholder: 'Password',
              semanticLabel: 'Password',
              enabled: !signingIn,
              error: passwordError != null || authError != null,
              autofillHints: const <String>[AutofillHints.password],
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          if (authError != null) ...<Widget>[
            const SizedBox(height: 12),
            MAlert(variant: MAlertVariant.destructive, message: authError),
          ],
          const SizedBox(height: 24),
          MButton(
            onPressed: signingIn || (validationAttempted && !formValid)
                ? null
                : onSubmit,
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
      ),
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
          title: 'Desktop app required',
          description:
              matrixRuntimeUnsupportedReason ??
              'This platform cannot run the Matrix bridge yet.',
        ),
      ],
    );
  }
}

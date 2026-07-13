import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';

import '../login/login_page.dart';
import '../matrix/account.dart';
import '../matrix/auth.dart';
import '../matrix/providers.dart';

/// Opens the saved-accounts switcher dialog.
Future<void> showAccountsDialog(BuildContext context) {
  return showMDialog<void>(
    context,
    builder: (BuildContext ctx) => const _AccountsDialogContent(),
  );
}

class _AccountsDialogContent extends ConsumerWidget {
  const _AccountsDialogContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = MTheme.of(context);
    final accounts = ref.watch(accountsProvider);
    final activeId = ref.watch(activeAccountIdProvider);
    final auth = ref.watch(authControllerProvider);
    final busy = auth is AuthAuthenticating || auth is AuthRestoring;

    return MDialogContent(
      title: 'Accounts',
      maxWidth: 420,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (accounts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No saved accounts yet.',
                style: theme.typography.bodySmall.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            )
          else
            for (final SavedAccount a in accounts)
              _AccountRow(account: a, active: a.id == activeId, busy: busy),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: MButton(
              variant: MButtonVariant.outline,
              onPressed: busy ? null : () => _addAccount(context),
              child: const Text('Add account'),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        if (activeId != null)
          MButton(
            variant: MButtonVariant.ghost,
            onPressed: busy ? null : () => _signOut(context, ref),
            child: const Text('Sign out'),
          ),
        MButton(
          variant: MButtonVariant.outline,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  void _addAccount(BuildContext context) {
    Navigator.of(context).pop();
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const _AddAccountRoute(),
      ),
    );
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showMConfirmDialog(
      context,
      title: 'Sign out of this account?',
      message:
          'This removes the saved session from this device. Other saved accounts remain available.',
      confirmLabel: 'Sign out',
      confirmVariant: MButtonVariant.destructive,
    );
    if (!confirmed || !context.mounted) return;
    Navigator.of(context).pop();
    await ref.read(authControllerProvider.notifier).signOut();
  }
}

/// Hosts [LoginPage] as a pushed route (rather than swapping `AuthGate`'s
/// child) so signing in to a second account doesn't disrupt whichever
/// account was already active. Pops itself once sign-in succeeds.
class _AddAccountRoute extends HookConsumerWidget {
  const _AddAccountRoute();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final originalAccountId = useMemoized(
      () => ref.read(activeAccountIdProvider),
      const <Object?>[],
    );
    final auth = ref.watch(authControllerProvider);
    final busy = auth is AuthAuthenticating || auth is AuthRestoring;
    ref.listen<AuthState>(authControllerProvider, (previous, next) {
      if (next is AuthAuthenticated &&
          ref.read(activeAccountIdProvider) != originalAccountId &&
          Navigator.canPop(context)) {
        Navigator.of(context).pop();
      }
    });
    return PopScope(
      canPop: !busy,
      child: LoginPage(
        restorePreviousAccountOnFailure: true,
        onCancel: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}

class _AccountRow extends ConsumerWidget {
  const _AccountRow({
    required this.account,
    required this.active,
    required this.busy,
  });

  final SavedAccount account;
  final bool active;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final auth = ref.watch(authControllerProvider);
    final recovery = auth is AuthRecoveryNeeded ? auth : null;
    final allowForgetActive = auth is AuthUnauthenticated;

    return MListTile(
      title: Text(account.label),
      subtitle: Text(account.homeserverUrl),
      selected: active,
      onTap: active || busy
          ? null
          : () async {
              Navigator.of(context).pop();
              await ref
                  .read(authControllerProvider.notifier)
                  .switchAccount(account.id);
            },
      semanticLabel: 'Switch to ${account.label}',
      trailing: _trailing(context, ref, accounts, recovery, allowForgetActive),
    );
  }

  Widget? _trailing(
    BuildContext context,
    WidgetRef ref,
    List<SavedAccount> accounts,
    AuthRecoveryNeeded? recovery,
    bool allowForgetActive,
  ) {
    final recoveryForThisAccount = active && recovery?.accountId == account.id;
    final showForget =
        accounts.length > 1 ||
        !active ||
        recoveryForThisAccount ||
        (active && allowForgetActive);
    if (!recoveryForThisAccount && !showForget) return null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (recoveryForThisAccount)
          MButton(
            variant: MButtonVariant.outline,
            size: MButtonSize.sm,
            onPressed: busy
                ? null
                : recovery is AuthNeedsReconnect
                ? () {
                    Navigator.of(context).pop();
                    ref.read(authControllerProvider.notifier).reconnectActive();
                  }
                : () => Navigator.of(context).pop(),
            child: Text(
              recovery is AuthNeedsReconnect ? 'Reconnect' : 'Sign in again',
            ),
          ),
        if (recoveryForThisAccount && showForget) const SizedBox(width: 8),
        if (showForget) _forgetButton(context, ref),
      ],
    );
  }

  Widget _forgetButton(BuildContext context, WidgetRef ref) {
    return MButton(
      variant: MButtonVariant.ghost,
      size: MButtonSize.sm,
      semanticLabel: 'Forget ${account.label}',
      onPressed: busy
          ? null
          : () async {
              final confirmed = await showMConfirmDialog(
                context,
                title: 'Forget account?',
                content: Builder(
                  builder: (BuildContext ctx) => Text(
                    account.label,
                    style: MTheme.of(ctx).typography.code,
                  ),
                ),
                confirmLabel: 'Forget',
                confirmVariant: MButtonVariant.destructive,
              );
              if (confirmed) {
                try {
                  if (active) {
                    await ref.read(authControllerProvider.notifier).signOut();
                  } else {
                    await ref
                        .read(accountsControllerProvider)
                        .forget(account.id);
                  }
                } on Object catch (error) {
                  if (!context.mounted) return;
                  await showMDialog<void>(
                    context,
                    builder: (ctx) => MDialogContent(
                      title: 'Forget failed',
                      maxWidth: 380,
                      content: MAlert(
                        variant: MAlertVariant.destructive,
                        message:
                            'Local account data could not be removed. Close other '
                            'ManyMatrix tabs and try again.\n\n$error',
                      ),
                      actions: <Widget>[
                        MButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  );
                }
              }
            },
      child: MIcon(MIconData.close),
    );
  }
}

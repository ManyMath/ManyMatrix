import 'package:flutter/widgets.dart';
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

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Accounts', style: theme.typography.headlineSmall),
          const SizedBox(height: 12),
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
              _AccountRow(account: a, active: a.id == activeId),
          const SizedBox(height: 8),
          MButton(
            variant: MButtonVariant.outline,
            onPressed: () => _addAccount(context),
            child: const Text('Add account'),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              MButton(
                variant: MButtonVariant.ghost,
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        ],
      ),
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
}

/// Hosts [LoginPage] as a pushed route (rather than swapping `AuthGate`'s
/// child) so signing in to a second account doesn't disrupt whichever
/// account was already active. Pops itself once sign-in succeeds.
class _AddAccountRoute extends ConsumerWidget {
  const _AddAccountRoute();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<AuthState>(authControllerProvider, (previous, next) {
      if (next is AuthAuthenticated && Navigator.canPop(context)) {
        Navigator.of(context).pop();
      }
    });
    return const LoginPage();
  }
}

class _AccountRow extends ConsumerWidget {
  const _AccountRow({required this.account, required this.active});

  final SavedAccount account;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);

    return MListTile(
      title: Text(account.label),
      subtitle: Text(account.homeserverUrl),
      selected: active,
      onTap: active
          ? null
          : () => ref
                .read(authControllerProvider.notifier)
                .switchAccount(account.id),
      semanticLabel: 'Switch to ${account.label}',
      trailing: accounts.length > 1 || !active
          ? MButton(
              variant: MButtonVariant.ghost,
              size: MButtonSize.sm,
              semanticLabel: 'Forget ${account.label}',
              onPressed: () async {
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
                  if (active) {
                    await ref.read(authControllerProvider.notifier).signOut();
                  } else {
                    ref.read(accountsControllerProvider).forget(account.id);
                  }
                }
              },
              child: MIcon(MIconData.close),
            )
          : null,
    );
  }
}

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';

import '../matrix/providers.dart';

/// Room-info / member-list screen reachable from the chat header.
///
/// Shows room encryption status plus joined members with kick/ban actions
/// behind confirmation dialogs. Unban and power-level/role management don't
/// exist at the bridge layer yet (see ROADMAP.md's ManyMatrix section) so they
/// are intentionally absent.
class RoomInfoPage extends ConsumerWidget {
  const RoomInfoPage({required this.roomId, required this.roomName, super.key});

  final String roomId;
  final String roomName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = MTheme.of(context);
    final currentUserId = ref.watch(currentUserIdProvider);
    final members = ref.watch(roomMembersProvider(roomId));

    return MScaffold(
      header: MAppHeader(
        title: roomName,
        subtitle: 'Room info',
        leading: MButton(
          variant: MButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
          semanticLabel: 'Back to chat',
          child: const Text('Back'),
        ),
      ),
      body: CustomScrollView(
        slivers: <Widget>[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            sliver: SliverToBoxAdapter(
              child: _EncryptionSection(roomId: roomId),
            ),
          ),
          const SliverPadding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
            sliver: SliverToBoxAdapter(child: MSectionHeader(title: 'Members')),
          ),
          members.when(
            loading: () => const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: MLoadingState(message: 'Loading members')),
            ),
            error: (error, _) => SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: MAlert(
                  variant: MAlertVariant.destructive,
                  message: 'Could not load members: $error',
                  maxWidth: 420,
                ),
              ),
            ),
            data: (userIds) {
              if (userIds.isEmpty) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Text(
                      'No members found',
                      style: theme.typography.body.copyWith(
                        color: theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                );
              }
              return SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final userId = userIds[index];
                  return _MemberTile(
                    roomId: roomId,
                    userId: userId,
                    isSelf: currentUserId != null && userId == currentUserId,
                  );
                }, childCount: userIds.length),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _EncryptionSection extends ConsumerStatefulWidget {
  const _EncryptionSection({required this.roomId});

  final String roomId;

  @override
  ConsumerState<_EncryptionSection> createState() => _EncryptionSectionState();
}

class _EncryptionSectionState extends ConsumerState<_EncryptionSection> {
  bool _enabling = false;
  Object? _enableError;

  @override
  Widget build(BuildContext context) {
    final encryption = ref.watch(roomEncryptionProvider(widget.roomId));

    return MInsetPanel(
      padding: const EdgeInsets.all(12),
      child: encryption.when(
        loading: () => const MSectionHeader(
          title: 'Encryption',
          description: 'Checking room encryption status.',
          status: MBadge(
            variant: MBadgeVariant.outline,
            child: Text('Checking'),
          ),
        ),
        error: (error, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MSectionHeader(
              title: 'Encryption',
              description: 'Room encryption status is unavailable.',
              status: const MBadge(
                variant: MBadgeVariant.destructive,
                child: Text('Error'),
              ),
              actions: <Widget>[
                MButton(
                  variant: MButtonVariant.ghost,
                  onPressed: () =>
                      ref.invalidate(roomEncryptionProvider(widget.roomId)),
                  child: const Text('Retry'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            MAlert(
              variant: MAlertVariant.destructive,
              message: 'Could not check encryption: $error',
            ),
          ],
        ),
        data: _buildEncryptionStatus,
      ),
    );
  }

  Widget _buildEncryptionStatus(bool encrypted) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        MSectionHeader(
          title: 'Encryption',
          description: encrypted
              ? 'New messages in this room are encrypted.'
              : 'Encryption is off for this room. Once enabled, it cannot be turned off.',
          descriptionMaxLines: 4,
          status: MBadge(
            variant: encrypted
                ? MBadgeVariant.secondary
                : MBadgeVariant.outline,
            child: Text(encrypted ? 'Encrypted' : 'Off'),
          ),
          actions: encrypted
              ? const <Widget>[]
              : <Widget>[
                  MButton(
                    onPressed: _enabling ? null : _confirmEnableEncryption,
                    child: Text(
                      _enabling ? 'Enabling...' : 'Enable encryption',
                    ),
                  ),
                ],
        ),
        if (_enableError != null) ...<Widget>[
          const SizedBox(height: 12),
          MAlert(
            variant: MAlertVariant.destructive,
            message: 'Could not enable encryption: $_enableError',
          ),
        ],
      ],
    );
  }

  Future<void> _confirmEnableEncryption() async {
    setState(() => _enableError = null);
    final confirmed = await showMConfirmDialog(
      context,
      title: 'Enable encryption?',
      message:
          'Room encryption cannot be turned off later. New messages will be encrypted once the room state change reaches the server.',
      confirmLabel: 'Enable encryption',
    );
    if (!confirmed || !mounted) return;

    setState(() => _enabling = true);
    try {
      await ref.read(matrixServiceProvider).enableEncryption(widget.roomId);
      ref.invalidate(roomEncryptionProvider(widget.roomId));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _enableError = error);
    } finally {
      if (mounted) {
        setState(() => _enabling = false);
      }
    }
  }
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({
    required this.roomId,
    required this.userId,
    required this.isSelf,
  });

  final String roomId;
  final String userId;
  final bool isSelf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = MTheme.of(context);
    final initial = userId
        .replaceFirst(RegExp(r'^@'), '')
        .substring(0, 1)
        .toUpperCase();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: <Widget>[
          MAvatar(size: 32, fallback: Text(initial), semanticLabel: userId),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              userId,
              style: theme.typography.body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!isSelf) ...<Widget>[
            MButton(
              variant: MButtonVariant.ghost,
              onPressed: () => _confirmModeration(
                context,
                ref,
                action: _ModerationAction.kick,
              ),
              child: const Text('Kick'),
            ),
            const SizedBox(width: 4),
            MButton(
              variant: MButtonVariant.destructive,
              onPressed: () => _confirmModeration(
                context,
                ref,
                action: _ModerationAction.ban,
              ),
              child: const Text('Ban'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmModeration(
    BuildContext context,
    WidgetRef ref, {
    required _ModerationAction action,
  }) async {
    final reasonController = MController<String>('');
    final reasonFocus = FocusNode();
    final verb = action == _ModerationAction.kick ? 'Kick' : 'Ban';

    final confirmed = await showMConfirmDialog(
      context,
      title: '$verb "$userId"?',
      message: action == _ModerationAction.kick
          ? 'This removes them from the room. They can rejoin if the room is '
                'public or they are re-invited.'
          : 'This removes them from the room and prevents them from rejoining '
                'until unbanned.',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          MField(
            label: 'Reason (optional)',
            focusNode: reasonFocus,
            child: MTextField(
              focusNode: reasonFocus,
              controller: reasonController,
              placeholder: 'Reason',
              semanticLabel: 'Reason',
            ),
          ),
        ],
      ),
      confirmLabel: verb,
      confirmVariant: MButtonVariant.destructive,
    );

    final reason = reasonController.value.trim();
    reasonController.dispose();
    reasonFocus.dispose();
    if (!confirmed) return;

    final service = ref.read(matrixServiceProvider);
    try {
      if (action == _ModerationAction.kick) {
        await service.kick(
          roomId,
          userId,
          reason: reason.isEmpty ? null : reason,
        );
      } else {
        await service.ban(
          roomId,
          userId,
          reason: reason.isEmpty ? null : reason,
        );
      }
      ref.invalidate(roomMembersProvider(roomId));
    } on Object catch (error) {
      if (!context.mounted) return;
      await showMDialog<void>(
        context,
        builder: (BuildContext ctx) => MDialogContent(
          title: '$verb failed',
          maxWidth: 380,
          content: MAlert(
            variant: MAlertVariant.destructive,
            message: '$error',
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
}

enum _ModerationAction { kick, ban }

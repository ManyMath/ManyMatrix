import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';

import '../matrix/providers.dart';

/// Room-info / member-list screen reachable from the chat header.
///
/// Minimal: lists joined members and offers kick/ban per member (each behind
/// a confirmation dialog, per the fleet-wide "confirm deliberately" pattern).
/// Unban and power-level/role management don't exist at the bridge layer yet
/// (see ROADMAP.md's ManyMatrix section) so they are intentionally absent.
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
        subtitle: 'Members',
        leading: MButton(
          variant: MButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
          semanticLabel: 'Back to chat',
          child: const Text('Back'),
        ),
      ),
      body: members.when(
        loading: () => const Center(
          child: MCircularProgress.indeterminate(
            semanticLabel: 'Loading members',
          ),
        ),
        error: (error, _) => Center(
          child: MAlert(
            variant: MAlertVariant.destructive,
            message: 'Could not load members: $error',
            maxWidth: 420,
          ),
        ),
        data: (userIds) {
          if (userIds.isEmpty) {
            return Center(
              child: Text(
                'No members found',
                style: theme.typography.body.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: userIds.length,
            itemBuilder: (context, index) {
              final userId = userIds[index];
              return _MemberTile(
                roomId: roomId,
                userId: userId,
                isSelf: currentUserId != null && userId == currentUserId,
              );
            },
          );
        },
      ),
    );
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
    final theme = MTheme.of(context);
    final reasonController = MController<String>('');
    final verb = action == _ModerationAction.kick ? 'Kick' : 'Ban';

    final confirmed = await showMDialog<bool>(
      context,
      builder: (BuildContext ctx) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('$verb "$userId"?', style: theme.typography.title),
            const SizedBox(height: 8),
            Text(
              action == _ModerationAction.kick
                  ? 'This removes them from the room. They can rejoin if the '
                        'room is public or they are re-invited.'
                  : 'This removes them from the room and prevents them from '
                        'rejoining until unbanned.',
              style: theme.typography.bodySmall.copyWith(
                color: theme.colors.mutedForeground,
              ),
            ),
            const SizedBox(height: 16),
            const MLabel('Reason (optional)'),
            const SizedBox(height: 8),
            MTextField(
              controller: reasonController,
              placeholder: 'Reason',
              semanticLabel: 'Reason',
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                MButton(
                  variant: MButtonVariant.ghost,
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                MButton(
                  variant: MButtonVariant.destructive,
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(verb),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    reasonController.dispose();
    if (confirmed != true) return;

    final reason = reasonController.value.trim();
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
        builder: (BuildContext ctx) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('$verb failed', style: theme.typography.title),
              const SizedBox(height: 8),
              Text(
                '$error',
                style: theme.typography.bodySmall.copyWith(
                  color: theme.colors.destructive,
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: MButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }
}

enum _ModerationAction { kick, ban }

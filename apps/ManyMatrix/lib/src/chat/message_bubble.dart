import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';
import 'package:manymatrix/manymatrix.dart';

import '../matrix/providers.dart';

/// One timeline entry: sender + time above a colored bubble, right-aligned
/// for the logged-in user's own messages.
///
/// Own messages get a delete (redact) affordance -- there is no power-level
/// info at the bridge layer yet (see ROADMAP.md's ManyMatrix section), so
/// redacting other users' messages isn't offered here.
class MessageBubble extends ConsumerWidget {
  const MessageBubble({
    required this.message,
    required this.isMine,
    super.key,
  });

  final MessageEvent message;
  final bool isMine;

  static String formatTimestamp(int millisecondsSinceEpoch) {
    final time =
        DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch).toLocal();
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = MTheme.of(context);
    final background = isMine ? theme.colors.primary : theme.colors.muted;
    final foreground =
        isMine ? theme.colors.primaryForeground : theme.colors.foreground;
    final body = message.msgtype == 'm.emote'
        ? '* ${message.sender.split(':').first} ${message.body}'
        : message.body;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            crossAxisAlignment:
                isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '${isMine ? 'You' : message.sender}'
                  '  ${formatTimestamp(message.timestamp)}',
                  style: theme.typography.caption
                      .copyWith(color: theme.colors.mutedForeground),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (isMine)
                    Padding(
                      padding: const EdgeInsets.only(right: 4, top: 4),
                      child: MButton(
                        variant: MButtonVariant.ghost,
                        onPressed: () => _confirmDelete(context, ref),
                        semanticLabel: 'Delete message',
                        child: const Text('×'),
                      ),
                    ),
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: background,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        body,
                        style:
                            theme.typography.body.copyWith(color: foreground),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final theme = MTheme.of(context);
    final confirmed = await showMDialog<bool>(
      context,
      builder: (BuildContext ctx) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Delete this message?', style: theme.typography.title),
            const SizedBox(height: 8),
            Text(
              'This removes the message for everyone in the room. This '
              'cannot be undone.',
              style: theme.typography.bodySmall
                  .copyWith(color: theme.colors.mutedForeground),
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
                  child: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;

    final service = ref.read(matrixServiceProvider);
    try {
      await service.redact(message.roomId, message.eventId);
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
              Text('Delete failed', style: theme.typography.title),
              const SizedBox(height: 8),
              Text(
                '$error',
                style: theme.typography.bodySmall
                    .copyWith(color: theme.colors.destructive),
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

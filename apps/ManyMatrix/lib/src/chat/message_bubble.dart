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
    this.reactions = const <ReactionEvent>[],
    this.receipts = const <ReceiptEvent>[],
    super.key,
  });

  final MessageEvent message;
  final bool isMine;
  final List<ReactionEvent> reactions;
  final List<ReceiptEvent> receipts;

  static String formatTimestamp(int millisecondsSinceEpoch) {
    final time = DateTime.fromMillisecondsSinceEpoch(
      millisecondsSinceEpoch,
    ).toLocal();
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = MTheme.of(context);
    final background = isMine ? theme.colors.primary : theme.colors.muted;
    final foreground = isMine
        ? theme.colors.primaryForeground
        : theme.colors.foreground;
    final body = message.msgtype == 'm.emote'
        ? '* ${message.sender.split(':').first} ${message.body}'
        : message.body;
    final reactionCounts = _reactionCounts(reactions);
    final readReceiptSummary = _readReceiptSummary(receipts);
    final hasMetadata = reactionCounts.isNotEmpty || readReceiptSummary != null;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            crossAxisAlignment: isMine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '${isMine ? 'You' : message.sender}'
                  '  ${formatTimestamp(message.timestamp)}',
                  style: theme.typography.caption.copyWith(
                    color: theme.colors.mutedForeground,
                  ),
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
                        style: theme.typography.body.copyWith(
                          color: foreground,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (hasMetadata)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    alignment: isMine ? WrapAlignment.end : WrapAlignment.start,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    runSpacing: 4,
                    children: <Widget>[
                      for (final entry in reactionCounts.entries)
                        _ReactionCountChip(
                          reactionKey: entry.key,
                          count: entry.value,
                        ),
                      if (readReceiptSummary != null)
                        Text(
                          readReceiptSummary,
                          style: theme.typography.caption.copyWith(
                            color: theme.colors.mutedForeground,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final theme = MTheme.of(context);
    final confirmed = await showMConfirmDialog(
      context,
      title: 'Delete this message?',
      message:
          'This removes the message for everyone in the room. This cannot be '
          'undone.',
      confirmLabel: 'Delete',
      confirmVariant: MButtonVariant.destructive,
    );
    if (!confirmed) return;
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

Map<String, int> _reactionCounts(List<ReactionEvent> reactions) {
  final counts = <String, int>{};
  for (final reaction in reactions) {
    counts[reaction.key] = (counts[reaction.key] ?? 0) + 1;
  }
  return counts;
}

String? _readReceiptSummary(List<ReceiptEvent> receipts) {
  final readers = <String>{};
  for (final receipt in receipts) {
    if (!receipt.receiptType.startsWith('m.read')) continue;
    readers.add(receipt.userId);
  }
  if (readers.isEmpty) return null;
  if (readers.length == 1) return 'Read by ${readers.single}';
  return 'Read by ${readers.length} people';
}

class _ReactionCountChip extends StatelessWidget {
  const _ReactionCountChip({required this.reactionKey, required this.count});

  final String reactionKey;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = MTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colors.muted,
        border: Border.all(color: theme.colors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 160),
        child: Text(
          '$reactionKey $count',
          style: theme.typography.caption.copyWith(
            color: theme.colors.foreground,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

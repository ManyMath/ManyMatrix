import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';
import 'package:manymatrix/manymatrix.dart';

import '../matrix/matrix_display.dart';
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
    this.threadReplyCount = 0,
    this.onReply,
    this.onEdit,
    this.onOpenThread,
    this.onThreadReply,
    super.key,
  });

  final MessageEvent message;
  final bool isMine;
  final List<ReactionEvent> reactions;
  final List<ReceiptEvent> receipts;
  final int threadReplyCount;
  final VoidCallback? onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onOpenThread;
  final VoidCallback? onThreadReply;

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
    final author = isMine ? 'You' : matrixUserDisplayName(message.sender);
    final messageText = _displayBody(message);
    final body = message.msgtype == 'm.emote'
        ? '* $author $messageText'
        : messageText;
    final kindLabel = _messageKindLabel(message.msgtype);
    final reactionCounts = _reactionCounts(reactions);
    final readReceiptSummary = _readReceiptSummary(receipts);
    final hasMetadata = reactionCounts.isNotEmpty || readReceiptSummary != null;
    final isThreadReply = message.threadRoot != null;
    final actions = <Widget>[
      if (onReply != null)
        MButton(
          variant: MButtonVariant.ghost,
          size: MButtonSize.sm,
          style: const MButtonStyleDelta(minHeight: 40),
          onPressed: onReply,
          child: const Text('Reply'),
        ),
      if (onEdit != null)
        MButton(
          variant: MButtonVariant.ghost,
          size: MButtonSize.sm,
          style: const MButtonStyleDelta(minHeight: 40),
          onPressed: onEdit,
          child: const Text('Edit'),
        ),
      if (onOpenThread != null)
        MButton(
          variant: MButtonVariant.ghost,
          size: MButtonSize.sm,
          style: const MButtonStyleDelta(minHeight: 40),
          onPressed: onOpenThread,
          child: Text(
            threadReplyCount > 0
                ? 'Open thread ($threadReplyCount)'
                : 'Open thread',
          ),
        ),
      if (onThreadReply != null)
        MButton(
          variant: MButtonVariant.ghost,
          size: MButtonSize.sm,
          style: const MButtonStyleDelta(minHeight: 40),
          onPressed: onThreadReply,
          child: const Text('Thread'),
        ),
      if (message.inReplyTo != null)
        MButton(
          variant: MButtonVariant.ghost,
          size: MButtonSize.sm,
          style: const MButtonStyleDelta(minHeight: 40),
          onPressed: () => _copyEventLink(context, message.inReplyTo!),
          child: const Text('Copy reply link'),
        ),
      if (message.threadRoot != null)
        MButton(
          variant: MButtonVariant.ghost,
          size: MButtonSize.sm,
          style: const MButtonStyleDelta(minHeight: 40),
          onPressed: () => _copyEventLink(context, message.threadRoot!),
          child: const Text('Copy thread link'),
        ),
      MButton(
        variant: MButtonVariant.ghost,
        size: MButtonSize.sm,
        style: const MButtonStyleDelta(minHeight: 40),
        onPressed: () => _copyEventLink(context, message.eventId),
        child: const Text('Copy link'),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 640.0;
          final maxBubbleWidth = availableWidth < 700
              ? availableWidth * 0.82
              : 560.0;
          final minBubbleWidth = maxBubbleWidth < 112 ? maxBubbleWidth : 112.0;

          final bubbleColumn = ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: minBubbleWidth,
              maxWidth: maxBubbleWidth,
            ),
            child: Column(
              crossAxisAlignment: isMine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '$author  ${formatTimestamp(message.timestamp)}'
                    '${message.editedAt == null ? '' : ' edited'}',
                    style: theme.typography.caption.copyWith(
                      color: theme.colors.mutedForeground,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: background,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (message.inReplyTo != null &&
                          !isThreadReply) ...<Widget>[
                        _MessageContextLine(text: 'Reply', color: foreground),
                        const SizedBox(height: 4),
                      ],
                      if (isThreadReply) ...<Widget>[
                        _MessageContextLine(
                          text: 'Thread reply',
                          color: foreground,
                        ),
                        const SizedBox(height: 4),
                      ],
                      if (kindLabel != null) ...<Widget>[
                        _MessageContextLine(text: kindLabel, color: foreground),
                        const SizedBox(height: 4),
                      ],
                      Text(
                        body,
                        style: theme.typography.body.copyWith(
                          color: foreground,
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasMetadata)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      alignment: isMine
                          ? WrapAlignment.end
                          : WrapAlignment.start,
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
                if (actions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: MActionRow(
                      alignment: isMine
                          ? WrapAlignment.end
                          : WrapAlignment.start,
                      spacing: 4,
                      runSpacing: 4,
                      children: actions,
                    ),
                  ),
              ],
            ),
          );

          return Row(
            mainAxisAlignment: isMine
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (isMine)
                Padding(
                  padding: const EdgeInsets.only(right: 4, top: 20),
                  child: MButton(
                    variant: MButtonVariant.ghost,
                    onPressed: () => _confirmDelete(context, ref),
                    semanticLabel: 'Delete message',
                    child: const Text('×'),
                  ),
                ),
              bubbleColumn,
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
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
        builder: (BuildContext ctx) => MDialogContent(
          title: 'Delete failed',
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

  Future<void> _copyEventLink(BuildContext context, String eventId) async {
    await Clipboard.setData(
      ClipboardData(
        text: matrixEventPermalink(roomId: message.roomId, eventId: eventId),
      ),
    );
    if (!context.mounted) return;
    showMToast(
      context,
      duration: const Duration(seconds: 2),
      semanticLabel: 'Link copied',
      builder: (_) => const Text('Link copied'),
    );
  }
}

String _displayBody(MessageEvent message) {
  final formattedBody = message.formattedBody;
  if (formattedBody != null && formattedBody.trim().isNotEmpty) {
    final plainText = _matrixHtmlToPlainText(formattedBody);
    if (plainText.isNotEmpty) return plainText;
  }
  return message.body;
}

String _matrixHtmlToPlainText(String html) {
  final withLineBreaks = html
      .replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(r'</\s*(p|div|li|blockquote|h[1-6])\s*>', caseSensitive: false),
        '\n',
      );
  final withoutTags = withLineBreaks.replaceAll(RegExp(r'<[^>]+>'), '');
  final decoded = _decodeHtmlEntities(withoutTags);
  return decoded
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}

String _decodeHtmlEntities(String text) {
  return text
      .replaceAllMapped(RegExp(r'&#(x?[0-9a-fA-F]+);'), (match) {
        final value = match.group(1)!;
        final radix = value.startsWith('x') ? 16 : 10;
        final digits = value.startsWith('x') ? value.substring(1) : value;
        final codePoint = int.tryParse(digits, radix: radix);
        if (codePoint == null || codePoint < 0 || codePoint > 0x10ffff) {
          return match.group(0)!;
        }
        return String.fromCharCode(codePoint);
      })
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

String? _messageKindLabel(String msgtype) {
  return switch (msgtype) {
    'm.image' => 'Image attachment',
    'm.file' => 'File attachment',
    'm.video' => 'Video attachment',
    'm.audio' => 'Audio attachment',
    'm.notice' => 'Notice',
    'm.text' || 'm.emote' => null,
    _ => msgtype,
  };
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
  if (readers.length == 1) {
    return 'Read by ${matrixUserDisplayName(readers.single)}';
  }
  return 'Read by ${readers.length} people';
}

class _MessageContextLine extends StatelessWidget {
  const _MessageContextLine({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = MTheme.of(context);
    return Text(
      text,
      style: theme.typography.caption.copyWith(color: color),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
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

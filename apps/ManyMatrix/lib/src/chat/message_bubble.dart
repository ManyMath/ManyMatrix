import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';
import 'package:manymatrix/manymatrix.dart';

import '../matrix/matrix_display.dart';
import '../matrix/providers.dart';
import '../matrix/room_timeline.dart';
import 'attachment_io.dart';

/// One timeline entry: sender + time above a colored bubble, right-aligned
/// for the logged-in user's own messages.
///
/// Own messages get a delete (redact) affordance. The bridge can read room
/// power levels, but this bubble does not consult them yet, so redacting
/// other users' messages isn't offered here.
class MessageBubble extends HookConsumerWidget {
  const MessageBubble({
    required this.message,
    required this.isMine,
    this.reactions = const <ReactionEvent>[],
    this.receipts = const <ReceiptEvent>[],
    this.threadReplyCount = 0,
    this.threadUnreadCount = 0,
    this.threadUnreadKnown = true,
    this.onReply,
    this.onEdit,
    this.onOpenThread,
    this.onThreadReply,
    this.onDownloadAttachment,
    super.key,
  });

  final MessageEvent message;
  final bool isMine;
  final List<ReactionEvent> reactions;
  final List<ReceiptEvent> receipts;
  final int threadReplyCount;
  final int threadUnreadCount;
  final bool threadUnreadKnown;
  final VoidCallback? onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onOpenThread;
  final VoidCallback? onThreadReply;
  final VoidCallback? onDownloadAttachment;

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
    final downloadInProgress = useState(false);
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
    final canDownload = message.mediaSource != null || message.mxcUri != null;
    final downloadAttachment =
        onDownloadAttachment ??
        (canDownload
            ? () {
                if (downloadInProgress.value) return;
                downloadInProgress.value = true;
                unawaited(() async {
                  try {
                    await _downloadAttachment(context, ref);
                  } on Object {
                    // _downloadAttachment reports failures in-app. A route
                    // closing during that report must not leak an async error.
                  } finally {
                    if (context.mounted) downloadInProgress.value = false;
                  }
                }());
              }
            : null);
    final moreActions = <_MessageAction>[
      if (downloadAttachment != null)
        _MessageAction(
          label: 'Download attachment',
          icon: MIconData.arrowDown,
          onPressed: downloadAttachment,
        ),
      if (onEdit != null)
        _MessageAction(label: 'Edit', icon: MIconData.edit, onPressed: onEdit!),
      if (onThreadReply != null)
        _MessageAction(
          label: 'Reply in thread',
          icon: MIconData.message,
          onPressed: onThreadReply!,
        ),
      if (message.inReplyTo != null)
        _MessageAction(
          label: 'Copy reply link',
          icon: MIconData.copy,
          onPressed: () => _copyEventLink(context, message.inReplyTo!),
        ),
      if (message.threadRoot != null)
        _MessageAction(
          label: 'Copy thread link',
          icon: MIconData.copy,
          onPressed: () => _copyEventLink(context, message.threadRoot!),
        ),
      _MessageAction(
        label: 'Copy message link',
        icon: MIconData.copy,
        onPressed: () => _copyEventLink(context, message.eventId),
      ),
      if (isMine)
        _MessageAction(
          label: 'Delete message',
          icon: MIconData.trash,
          destructive: true,
          onPressed: () => _confirmDelete(context, ref),
        ),
    ];
    final threadSemantics = threadReplyCount == 0
        ? 'Open thread, no replies'
              '${threadUnreadKnown ? '' : ', unread status unavailable'}'
        : 'Open thread, $threadReplyCount ${threadReplyCount == 1 ? 'reply' : 'replies'}'
              '${threadUnreadCount == 0 ? '' : ', $threadUnreadCount unread'}'
              '${threadUnreadKnown ? '' : ', unread status unavailable'}';
    final actions = <Widget>[
      if (downloadAttachment != null)
        MIconButton(
          icon: MIconData.arrowDown,
          label: 'Download attachment',
          size: MButtonSize.sm,
          onPressed: downloadInProgress.value ? null : downloadAttachment,
        ),
      if (onReply != null)
        MIconButton(
          icon: MIconData.message,
          label: 'Reply',
          size: MButtonSize.sm,
          onPressed: onReply,
        ),
      if (onOpenThread != null)
        MButton(
          variant: MButtonVariant.ghost,
          size: MButtonSize.sm,
          style: const MButtonStyleDelta(
            minHeight: 40,
            padding: EdgeInsets.symmetric(horizontal: 10),
          ),
          onPressed: onOpenThread,
          semanticLabel: threadSemantics,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const MIcon(MIconData.message, size: 17),
              const SizedBox(width: 5),
              if (threadReplyCount == 0)
                Text('Thread', style: theme.typography.label)
              else
                Text(
                  threadReplyCount > 99 ? '99+' : '$threadReplyCount',
                  style: theme.typography.label.copyWith(
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                    fontWeight: threadUnreadCount > 0
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              if (threadUnreadCount > 0) ...<Widget>[
                const SizedBox(width: 5),
                ExcludeSemantics(
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: theme.colors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      _MessageMoreButton(actions: moreActions, alignToTrailingEdge: isMine),
    ];

    return MContextMenu(
      semanticLabel: 'Message actions',
      items: <MMenuItem>[
        for (var index = 0; index < moreActions.length; index += 1)
          MMenuItem(
            id: 'message-action-$index',
            title: Text(moreActions[index].label),
            onTap: moreActions[index].onPressed,
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 640.0;
            final maxBubbleWidth = availableWidth < 700
                ? availableWidth * 0.82
                : 560.0;
            final minBubbleWidth = maxBubbleWidth < 112
                ? maxBubbleWidth
                : 112.0;

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
                      borderRadius: BorderRadius.circular(8),
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
                          _MessageContextLine(
                            text: kindLabel,
                            color: foreground,
                          ),
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

            return Align(
              alignment: isMine
                  ? AlignmentDirectional.centerEnd
                  : AlignmentDirectional.centerStart,
              child: bubbleColumn,
            );
          },
        ),
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
      if (context.mounted &&
          identical(ref.read(matrixServiceProvider), service)) {
        ref
            .read(roomTimelineProvider(message.roomId).notifier)
            .removeLocal(message.eventId);
      }
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

  Future<void> _downloadAttachment(BuildContext context, WidgetRef ref) async {
    final mxcUri = message.mxcUri;
    final mediaSource = message.mediaSource;
    if (mxcUri == null && mediaSource == null) return;
    try {
      final advertisedSize = message.fileSize;
      if (advertisedSize != null) ensureAttachmentSize(advertisedSize);
      final service = ref.read(matrixServiceProvider);
      final data = mediaSource != null
          ? await service.downloadMediaSource(mediaSource)
          : await service.downloadMedia(mxcUri!);
      if (data == null) {
        throw StateError('The homeserver returned an empty attachment.');
      }
      ensureAttachmentSize(data.length);
      if (!context.mounted) return;
      final filename = _attachmentFilename(message);
      final saved = await ref.read(attachmentSaverProvider)(
        filename,
        mimeTypeForFilename(filename),
        data,
      );
      if (!saved || !context.mounted) return;
      showMToast(
        context,
        duration: const Duration(seconds: 2),
        semanticLabel: 'Attachment downloaded',
        builder: (_) => Text('$filename downloaded'),
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      await showMDialog<void>(
        context,
        builder: (BuildContext ctx) => MDialogContent(
          title: 'Download failed',
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
  return message.body.trim().isEmpty ? 'Empty message' : message.body;
}

String _attachmentFilename(MessageEvent message) {
  final filename = message.filename?.trim();
  if (filename != null && filename.isNotEmpty) return filename;
  final body = message.body.trim();
  return body.isEmpty ? 'attachment' : body;
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

class _MessageAction {
  const _MessageAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
  });

  final String label;
  final MIconData icon;
  final VoidCallback onPressed;
  final bool destructive;
}

class _MessageMoreButton extends StatefulWidget {
  const _MessageMoreButton({
    required this.actions,
    required this.alignToTrailingEdge,
  });

  final List<_MessageAction> actions;
  final bool alignToTrailingEdge;

  @override
  State<_MessageMoreButton> createState() => _MessageMoreButtonState();
}

class _MessageMoreButtonState extends State<_MessageMoreButton> {
  final MPopoverController _controller = MPopoverController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const menuWidth = 196.0;
    const anchorWidth = 32.0;
    final anchorButton = MIconButton(
      icon: MIconData.moreHorizontal,
      label: 'More message actions',
      size: MButtonSize.sm,
      onPressed: _controller.toggle,
    );
    final popover = MPopover(
      controller: _controller,
      semanticLabel: 'More message actions',
      popoverBuilder: (context, close) => SizedBox(
        width: menuWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final action in widget.actions)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: MButton(
                  variant: action.destructive
                      ? MButtonVariant.destructive
                      : MButtonVariant.ghost,
                  size: MButtonSize.sm,
                  onPressed: () {
                    close();
                    action.onPressed();
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      MIcon(action.icon, size: 16),
                      const SizedBox(width: 8),
                      Flexible(child: Text(action.label)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      child: widget.alignToTrailingEdge
          ? SizedBox(
              width: menuWidth,
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: anchorButton,
              ),
            )
          : anchorButton,
    );

    if (!widget.alignToTrailingEdge) return popover;

    return SizedBox.square(
      dimension: anchorWidth,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          PositionedDirectional(end: 0, width: menuWidth, child: popover),
        ],
      ),
    );
  }
}

import 'package:flutter/widgets.dart';
import 'package:manyui/manyui.dart';
import 'package:manymatrix/manymatrix.dart';

/// One timeline entry: sender + time above a colored bubble, right-aligned
/// for the logged-in user's own messages.
class MessageBubble extends StatelessWidget {
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
  Widget build(BuildContext context) {
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
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  body,
                  style: theme.typography.body.copyWith(color: foreground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

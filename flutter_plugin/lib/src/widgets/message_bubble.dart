import 'package:flutter/material.dart';

import '../models/message_event.dart';

/// Chat message bubble widget.
///
/// Aligns right for messages sent by the current user, left for
/// received messages. Uses Material 3 color scheme for styling.
class MessageBubble extends StatelessWidget {
  final MessageEvent message;
  final bool isMe;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bgColor = isMe
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHighest;
    final textColor = isMe
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurface;

    final time = DateTime.fromMillisecondsSinceEpoch(message.timestamp);
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: isMe
                  ? const Radius.circular(16)
                  : const Radius.circular(4),
              bottomRight: isMe
                  ? const Radius.circular(4)
                  : const Radius.circular(16),
            ),
          ),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isMe)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    message.sender,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: colorScheme.primary,
                    ),
                  ),
                ),
              Text(
                message.body,
                style: TextStyle(color: textColor),
              ),
              const SizedBox(height: 2),
              Text(
                timeStr,
                style: TextStyle(
                  fontSize: 11,
                  color: textColor.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

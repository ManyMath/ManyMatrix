import 'package:flutter/widgets.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manyui/manyui.dart';

import '../matrix/matrix_display.dart';

/// One row in the room list: avatar, name, recency, preview, and unread count.
class RoomTile extends StatelessWidget {
  const RoomTile({
    required this.room,
    required this.selected,
    required this.onTap,
    this.currentUserId,
    super.key,
  });

  final RoomSummary room;
  final bool selected;
  final VoidCallback onTap;
  final String? currentUserId;

  String get _initial {
    final name = room.displayName.trim();
    if (name.isEmpty) return '?';
    final letters = name.replaceFirst(RegExp(r'^[#!@]+'), '');
    return (letters.isEmpty ? name : letters).substring(0, 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = MTheme.of(context);
    final preview = room.lastMessage;
    final previewSender = preview == null
        ? null
        : preview.sender == currentUserId
        ? 'You'
        : matrixUserDisplayName(preview.sender);
    final previewText = preview == null
        ? null
        : '$previewSender: ${preview.body.trim().isEmpty ? 'New activity' : preview.body}';
    final timestamp = preview == null
        ? null
        : formatRoomListTimestamp(preview.timestamp);
    final unread = room.unreadCount > 0;
    final semantics = <String>[
      'Open room ${room.displayName}',
      if (unread)
        '${room.unreadCount} unread ${room.unreadCount == 1 ? 'message' : 'messages'}',
      if (previewText != null) previewText,
      if (timestamp != null) timestamp,
    ].join(', ');

    return DecoratedBox(
      decoration: BoxDecoration(
        border: BorderDirectional(
          start: BorderSide(
            color: selected ? theme.colors.primary : const Color(0x00000000),
            width: 3,
          ),
        ),
      ),
      child: MListTile(
        leading: ExcludeSemantics(
          child: MAvatar(size: 40, fallback: Text(_initial)),
        ),
        title: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                room.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.body.copyWith(
                  fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            if (timestamp != null) ...<Widget>[
              const SizedBox(width: 8),
              Text(
                timestamp,
                style: theme.typography.caption.copyWith(
                  color: unread
                      ? theme.colors.primary
                      : theme.colors.mutedForeground,
                ),
              ),
            ],
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            previewText ?? 'No messages yet',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: unread
            ? MBadge(child: Text(_compactUnreadCount(room.unreadCount)))
            : null,
        selected: selected,
        onTap: onTap,
        semanticLabel: semantics,
      ),
    );
  }
}

String _compactUnreadCount(int count) => count > 99 ? '99+' : '$count';

String formatRoomListTimestamp(int milliseconds, {DateTime? now}) {
  final current = (now ?? DateTime.now()).toLocal();
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(time.year, time.month, time.day);
  final difference = today.difference(day).inDays;

  if (difference == 0) {
    final hour = time.hour == 0
        ? 12
        : (time.hour > 12 ? time.hour - 12 : time.hour);
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${time.hour >= 12 ? 'PM' : 'AM'}';
  }
  if (difference == 1) return 'Yesterday';
  if (difference > 1 && difference < 7) {
    const weekdays = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return weekdays[time.weekday - 1];
  }
  if (time.year == current.year) return '${time.month}/${time.day}';
  return '${time.month}/${time.day}/${time.year.toString().substring(2)}';
}

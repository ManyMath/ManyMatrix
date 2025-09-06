import 'package:flutter/material.dart';

import '../models/room_summary.dart';

/// Reusable list tile for displaying a room in a list.
///
/// Shows the room avatar (first letter), display name, last message
/// preview, and unread count badge.
class RoomTile extends StatelessWidget {
  final RoomSummary room;
  final VoidCallback? onTap;

  const RoomTile({
    super.key,
    required this.room,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final initial = room.displayName.isNotEmpty
        ? room.displayName[0].toUpperCase()
        : '?';

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: colorScheme.primaryContainer,
        child: room.displayName.isNotEmpty
            ? Text(initial, style: TextStyle(color: colorScheme.onPrimaryContainer))
            : Icon(Icons.chat, color: colorScheme.onPrimaryContainer),
      ),
      title: Text(
        room.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        room.lastMessage?.body ?? 'No messages yet',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: room.unreadCount > 0
          ? Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: Text(
                room.unreadCount > 99
                    ? '99+'
                    : room.unreadCount.toString(),
                style: TextStyle(
                  color: colorScheme.onPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          : null,
      onTap: onTap,
    );
  }
}

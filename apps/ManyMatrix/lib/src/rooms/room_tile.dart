import 'package:flutter/widgets.dart';
import 'package:manyui/manyui.dart';
import 'package:manymatrix/manymatrix.dart';

/// One row in the room list: avatar initial, name, last-message preview,
/// unread badge.
class RoomTile extends StatelessWidget {
  const RoomTile({
    required this.room,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final RoomSummary room;
  final bool selected;
  final VoidCallback onTap;

  String get _initial {
    final name = room.displayName.trim();
    if (name.isEmpty) return '?';
    // Skip Matrix sigils like # or ! when a raw ID leaks through.
    final letters = name.replaceFirst(RegExp(r'^[#!@]+'), '');
    return (letters.isEmpty ? name : letters).substring(0, 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final preview = room.lastMessage;

    return MListTile(
      leading: MAvatar(
        size: 36,
        fallback: Text(_initial),
        semanticLabel: room.displayName,
      ),
      title: Text(
        room.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: preview != null
          ? Text(
              '${preview.sender.split(':').first}: ${preview.body}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing:
          room.unreadCount > 0 ? MBadge(child: Text('${room.unreadCount}')) : null,
      selected: selected,
      onTap: onTap,
      semanticLabel: 'Open room ${room.displayName}',
    );
  }
}

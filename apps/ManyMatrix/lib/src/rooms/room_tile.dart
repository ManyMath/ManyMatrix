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
    final theme = MTheme.of(context);
    final preview = room.lastMessage;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Semantics(
        button: true,
        selected: selected,
        label: 'Open room ${room.displayName}',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? theme.colors.muted : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: <Widget>[
              MAvatar(
                size: 36,
                fallback: Text(_initial),
                semanticLabel: room.displayName,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      room.displayName,
                      style: theme.typography.body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (preview != null)
                      Text(
                        '${preview.sender.split(':').first}: ${preview.body}',
                        style: theme.typography.bodySmall
                            .copyWith(color: theme.colors.mutedForeground),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (room.unreadCount > 0) ...<Widget>[
                const SizedBox(width: 8),
                MBadge(child: Text('${room.unreadCount}')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

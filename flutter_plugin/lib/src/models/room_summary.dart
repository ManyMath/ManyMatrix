/// Summary of a joined room for display in room lists.
class RoomSummary {
  final String roomId;
  final String displayName;
  final String? avatarUrl;
  final LastMessage? lastMessage;
  final int unreadCount;
  final bool isSynced;

  RoomSummary({
    required this.roomId,
    required this.displayName,
    this.avatarUrl,
    this.lastMessage,
    required this.unreadCount,
    this.isSynced = true,
  });

  factory RoomSummary.fromJson(Map<String, dynamic> json) => RoomSummary(
        roomId: json['room_id'] as String,
        displayName: json['display_name'] as String,
        avatarUrl: json['avatar_url'] as String?,
        lastMessage: json['last_message'] != null
            ? LastMessage.fromJson(json['last_message'] as Map<String, dynamic>)
            : null,
        unreadCount: json['unread_count'] as int,
        isSynced: json['is_synced'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'room_id': roomId,
        'display_name': displayName,
        'avatar_url': avatarUrl,
        'last_message': lastMessage?.toJson(),
        'unread_count': unreadCount,
        'is_synced': isSynced,
      };
}

/// Preview of the most recent message in a room.
class LastMessage {
  final String sender;
  final String body;
  final int timestamp;

  LastMessage({
    required this.sender,
    required this.body,
    required this.timestamp,
  });

  factory LastMessage.fromJson(Map<String, dynamic> json) => LastMessage(
        sender: json['sender'] as String,
        body: json['body'] as String,
        timestamp: json['timestamp'] as int,
      );

  Map<String, dynamic> toJson() => {
        'sender': sender,
        'body': body,
        'timestamp': timestamp,
      };
}

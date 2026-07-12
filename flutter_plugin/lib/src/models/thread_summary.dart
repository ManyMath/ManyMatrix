import 'message_event.dart';

/// One server-aggregated Matrix thread for a cross-room thread index.
class ThreadSummary {
  ThreadSummary({
    required this.roomId,
    required this.roomName,
    required this.root,
    this.latestReply,
    required this.replyCount,
    required this.unreadCount,
    required this.currentUserParticipated,
  });

  final String roomId;
  final String roomName;
  final MessageEvent root;
  final MessageEvent? latestReply;
  final int replyCount;

  /// Null when the homeserver unread-thread aggregate was unavailable.
  final int? unreadCount;
  final bool currentUserParticipated;

  int get lastActivityTimestamp => latestReply?.timestamp ?? root.timestamp;

  ThreadSummary copyWith({int? replyCount, int? unreadCount}) => ThreadSummary(
        roomId: roomId,
        roomName: roomName,
        root: root,
        latestReply: latestReply,
        replyCount: replyCount ?? this.replyCount,
        unreadCount: unreadCount ?? this.unreadCount,
        currentUserParticipated: currentUserParticipated,
      );

  factory ThreadSummary.fromJson(Map<String, dynamic> json) => ThreadSummary(
        roomId: json['room_id'] as String,
        roomName: json['room_name'] as String,
        root: MessageEvent.fromJson(json['root'] as Map<String, dynamic>),
        latestReply: json['latest_reply'] == null
            ? null
            : MessageEvent.fromJson(
                json['latest_reply'] as Map<String, dynamic>,
              ),
        replyCount: json['reply_count'] as int,
        unreadCount: json['unread_count'] as int?,
        currentUserParticipated:
            json['current_user_participated'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'room_id': roomId,
        'room_name': roomName,
        'root': root.toJson(),
        'latest_reply': latestReply?.toJson(),
        'reply_count': replyCount,
        'unread_count': unreadCount,
        'current_user_participated': currentUserParticipated,
      };
}

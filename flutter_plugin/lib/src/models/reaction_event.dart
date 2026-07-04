/// A received Matrix reaction event.
class ReactionEvent {
  final String eventId;
  final String roomId;
  final String sender;
  final String relatesToEventId;
  final String key;
  final int timestamp;

  ReactionEvent({
    required this.eventId,
    required this.roomId,
    required this.sender,
    required this.relatesToEventId,
    required this.key,
    required this.timestamp,
  });

  factory ReactionEvent.fromJson(Map<String, dynamic> json) => ReactionEvent(
        eventId: json['event_id'] as String,
        roomId: json['room_id'] as String,
        sender: json['sender'] as String,
        relatesToEventId: json['relates_to_event_id'] as String,
        key: json['key'] as String,
        timestamp: json['timestamp'] as int,
      );

  Map<String, dynamic> toJson() => {
        'event_id': eventId,
        'room_id': roomId,
        'sender': sender,
        'relates_to_event_id': relatesToEventId,
        'key': key,
        'timestamp': timestamp,
      };
}

/// A received message event from the Matrix server.
class MessageEvent {
  final String eventId;
  final String roomId;
  final String sender;
  final String body;
  final String? formattedBody;
  final String msgtype;
  final int timestamp;
  final String? inReplyTo;
  final String? threadRoot;

  MessageEvent({
    required this.eventId,
    required this.roomId,
    required this.sender,
    required this.body,
    this.formattedBody,
    required this.msgtype,
    required this.timestamp,
    this.inReplyTo,
    this.threadRoot,
  });

  factory MessageEvent.fromJson(Map<String, dynamic> json) => MessageEvent(
    eventId: json['event_id'] as String,
    roomId: json['room_id'] as String,
    sender: json['sender'] as String,
    body: json['body'] as String,
    formattedBody: json['formatted_body'] as String?,
    msgtype: json['msgtype'] as String,
    timestamp: json['timestamp'] as int,
    inReplyTo: json['in_reply_to'] as String?,
    threadRoot: json['thread_root'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'event_id': eventId,
    'room_id': roomId,
    'sender': sender,
    'body': body,
    'formatted_body': formattedBody,
    'msgtype': msgtype,
    'timestamp': timestamp,
    'in_reply_to': inReplyTo,
    'thread_root': threadRoot,
  };
}

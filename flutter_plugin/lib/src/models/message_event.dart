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
  final String? replacesEventId;
  final String? redactsEventId;
  final int? editedAt;
  final String? mxcUri;
  final Map<String, dynamic>? mediaSource;
  final String? filename;
  final int? fileSize;

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
    this.replacesEventId,
    this.redactsEventId,
    this.editedAt,
    this.mxcUri,
    this.mediaSource,
    this.filename,
    this.fileSize,
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
        replacesEventId: json['replaces_event_id'] as String?,
        redactsEventId: json['redacts_event_id'] as String?,
        editedAt: json['edited_at'] as int?,
        mxcUri: json['mxc_uri'] as String?,
        mediaSource: json['media_source'] == null
            ? null
            : Map<String, dynamic>.from(json['media_source'] as Map),
        filename: json['filename'] as String?,
        fileSize: json['file_size'] as int?,
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
        'replaces_event_id': replacesEventId,
        'redacts_event_id': redactsEventId,
        'edited_at': editedAt,
        'mxc_uri': mxcUri,
        'media_source': mediaSource,
        'filename': filename,
        'file_size': fileSize,
      };
}

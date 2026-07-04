/// A received Matrix read-receipt event.
class ReceiptEvent {
  final String roomId;
  final String userId;
  final String eventId;
  final String receiptType;
  final int? timestamp;

  ReceiptEvent({
    required this.roomId,
    required this.userId,
    required this.eventId,
    required this.receiptType,
    this.timestamp,
  });

  factory ReceiptEvent.fromJson(Map<String, dynamic> json) => ReceiptEvent(
        roomId: json['room_id'] as String,
        userId: json['user_id'] as String,
        eventId: json['event_id'] as String,
        receiptType: json['receipt_type'] as String,
        timestamp: json['timestamp'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'room_id': roomId,
        'user_id': userId,
        'event_id': eventId,
        'receipt_type': receiptType,
        'timestamp': timestamp,
      };
}

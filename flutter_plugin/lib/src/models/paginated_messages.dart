import 'message_event.dart';

/// Result of paginating messages in a room.
class PaginatedMessages {
  final List<MessageEvent> messages;
  final String? endToken;

  PaginatedMessages({required this.messages, this.endToken});

  factory PaginatedMessages.fromJson(Map<String, dynamic> json) =>
      PaginatedMessages(
        messages: (json['messages'] as List<dynamic>)
            .map((e) => MessageEvent.fromJson(e as Map<String, dynamic>))
            .toList(),
        endToken: json['end_token'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'messages': messages.map((e) => e.toJson()).toList(),
    'end_token': endToken,
  };
}

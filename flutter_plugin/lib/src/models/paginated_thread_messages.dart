import 'message_event.dart';

/// One page of replies for a Matrix thread, with its root event.
class PaginatedThreadMessages {
  PaginatedThreadMessages({
    required this.root,
    required this.messages,
    this.endToken,
  });

  final MessageEvent root;
  final List<MessageEvent> messages;
  final String? endToken;

  factory PaginatedThreadMessages.fromJson(Map<String, dynamic> json) =>
      PaginatedThreadMessages(
        root: MessageEvent.fromJson(json['root'] as Map<String, dynamic>),
        messages: (json['messages'] as List<dynamic>)
            .map(
              (event) => MessageEvent.fromJson(event as Map<String, dynamic>),
            )
            .toList(),
        endToken: json['end_token'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'root': root.toJson(),
        'messages': messages.map((event) => event.toJson()).toList(),
        'end_token': endToken,
      };
}

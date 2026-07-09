import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manymatrix_app/src/chat/chat_page.dart';
import 'package:manymatrix_app/src/matrix/bridge_service.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';
import 'package:manyui/manyui.dart';

void main() {
  testWidgets('sends the selected message as a reply', (tester) async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(r'$event-1', sender: '@bob:example.org', body: 'Original'),
      ],
    );

    await _pumpChat(tester, service);
    await tester.tap(find.text('Reply'));
    await tester.pump();

    expect(find.text('Replying to @bob:example.org'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'Answer');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(service.replyCalls, <_ReplyCall>[
      const _ReplyCall(roomId: _roomId, eventId: r'$event-1', body: 'Answer'),
    ]);
    expect(find.text('Replying to @bob:example.org'), findsNothing);
    expect(find.text('Answer'), findsOneWidget);
    expect(find.text(r'Reply to $event-1'), findsOneWidget);
  });

  testWidgets('sends thread replies against the thread root', (tester) async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(
          r'$reply-1',
          sender: '@bob:example.org',
          body: 'Existing thread message',
          threadRoot: r'$root-event',
        ),
      ],
    );

    await _pumpChat(tester, service);
    await tester.tap(find.text('Thread'));
    await tester.pump();

    expect(find.text('Thread reply to @bob:example.org'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'Thread answer');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(service.threadCalls, <_ThreadCall>[
      const _ThreadCall(
        roomId: _roomId,
        threadRootId: r'$root-event',
        body: 'Thread answer',
      ),
    ]);
    expect(find.text('Thread reply to @bob:example.org'), findsNothing);
    expect(find.text('Thread answer'), findsOneWidget);
    expect(find.text(r'Reply to $reply-1'), findsOneWidget);
    expect(find.text(r'Thread $root-event'), findsNWidgets(2));
  });
}

const _roomId = '!room:example.org';

Future<void> _pumpChat(WidgetTester tester, _FakeMatrixService service) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[matrixServiceProvider.overrideWithValue(service)],
      child: const MWidgetsApp(
        debugShowCheckedModeBanner: false,
        home: ChatView(roomId: _roomId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

MessageEvent _message(
  String eventId, {
  required String sender,
  required String body,
  String? threadRoot,
}) {
  return MessageEvent(
    eventId: eventId,
    roomId: _roomId,
    sender: sender,
    body: body,
    msgtype: 'm.text',
    timestamp: 1700000000000,
    threadRoot: threadRoot,
  );
}

class _FakeMatrixService implements MatrixService {
  _FakeMatrixService({required this.initialMessages});

  final List<MessageEvent> initialMessages;
  final List<_ReplyCall> replyCalls = <_ReplyCall>[];
  final List<_ThreadCall> threadCalls = <_ThreadCall>[];

  final _messages = StreamController<MessageEvent>.broadcast();
  final _reactions = StreamController<ReactionEvent>.broadcast();
  final _receipts = StreamController<ReceiptEvent>.broadcast();

  @override
  Stream<MessageEvent> get messageEvents => _messages.stream;

  @override
  Stream<ReactionEvent> get reactionEvents => _reactions.stream;

  @override
  Stream<ReceiptEvent> get receiptEvents => _receipts.stream;

  @override
  String? get currentUserId => '@alice:example.org';

  @override
  Future<String?> restoreSession() async => currentUserId;

  @override
  Future<String> login({
    required String homeserverUrl,
    required String username,
    required String password,
  }) async => currentUserId!;

  @override
  Future<void> logout() async {}

  @override
  Future<List<RoomSummary>> joinedRooms() async => const <RoomSummary>[];

  @override
  Future<String> createRoom({String? name, String? topic}) async =>
      '!new:example.org';

  @override
  Future<String> joinRoom(String roomIdOrAlias) async => roomIdOrAlias;

  @override
  Future<void> invite(String roomId, String userId) async {}

  @override
  Future<PaginatedMessages> getMessages(
    String roomId, {
    String? fromToken,
    int limit = 50,
  }) async => PaginatedMessages(messages: initialMessages);

  @override
  Future<String> sendText(String roomId, String body) async => r'$local';

  @override
  Future<String> replyTo(String roomId, String eventId, String body) async {
    replyCalls.add(_ReplyCall(roomId: roomId, eventId: eventId, body: body));
    return r'$reply-local';
  }

  @override
  Future<String> sendThreadReply(
    String roomId,
    String threadRootId,
    String body,
  ) async {
    threadCalls.add(
      _ThreadCall(roomId: roomId, threadRootId: threadRootId, body: body),
    );
    return r'$thread-local';
  }

  @override
  Future<void> sendTyping(String roomId, bool typing) async {}

  @override
  Future<void> sendReadReceipt(String roomId, String eventId) async {}

  @override
  Future<List<String>> roomMembers(String roomId) async => const <String>[];

  @override
  Future<void> kick(String roomId, String userId, {String? reason}) async {}

  @override
  Future<void> ban(String roomId, String userId, {String? reason}) async {}

  @override
  Future<void> redact(String roomId, String eventId, {String? reason}) async {}

  @override
  void dispose() {
    _messages.close();
    _reactions.close();
    _receipts.close();
  }
}

class _ReplyCall {
  const _ReplyCall({
    required this.roomId,
    required this.eventId,
    required this.body,
  });

  final String roomId;
  final String eventId;
  final String body;

  @override
  bool operator ==(Object other) {
    return other is _ReplyCall &&
        other.roomId == roomId &&
        other.eventId == eventId &&
        other.body == body;
  }

  @override
  int get hashCode => Object.hash(roomId, eventId, body);

  @override
  String toString() {
    return '_ReplyCall(roomId: $roomId, eventId: $eventId, body: $body)';
  }
}

class _ThreadCall {
  const _ThreadCall({
    required this.roomId,
    required this.threadRootId,
    required this.body,
  });

  final String roomId;
  final String threadRootId;
  final String body;

  @override
  bool operator ==(Object other) {
    return other is _ThreadCall &&
        other.roomId == roomId &&
        other.threadRootId == threadRootId &&
        other.body == body;
  }

  @override
  int get hashCode => Object.hash(roomId, threadRootId, body);

  @override
  String toString() {
    return '_ThreadCall('
        'roomId: $roomId, '
        'threadRootId: $threadRootId, '
        'body: $body'
        ')';
  }
}

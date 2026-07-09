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

  testWidgets('edits own text messages from the composer', (tester) async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(r'$event-1', sender: '@alice:example.org', body: 'Original'),
      ],
    );

    await _pumpChat(tester, service);
    await tester.tap(find.text('Edit'));
    await tester.pump();

    expect(find.text('Editing @alice:example.org'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'Edited body');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(service.editCalls, <_EditCall>[
      const _EditCall(
        roomId: _roomId,
        eventId: r'$event-1',
        newBody: 'Edited body',
      ),
    ]);
    expect(find.text('Editing @alice:example.org'), findsNothing);
    expect(find.text('Original'), findsNothing);
    expect(find.text('Edited body'), findsOneWidget);
    expect(find.textContaining('edited'), findsOneWidget);
  });

  testWidgets('sends notice messages from the composer mode control', (
    tester,
  ) async {
    final service = _FakeMatrixService(initialMessages: const <MessageEvent>[]);

    await _pumpChat(tester, service);
    await tester.tap(find.text('Notice'));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'Maintenance soon');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(service.noticeCalls, <_MessageCall>[
      const _MessageCall(roomId: _roomId, body: 'Maintenance soon'),
    ]);
    expect(find.text('Notice'), findsWidgets);
    expect(find.text('Maintenance soon'), findsOneWidget);
  });

  testWidgets('sends emote messages from the composer mode control', (
    tester,
  ) async {
    final service = _FakeMatrixService(initialMessages: const <MessageEvent>[]);

    await _pumpChat(tester, service);
    await tester.tap(find.text('Emote'));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'waves');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(service.emoteCalls, <_MessageCall>[
      const _MessageCall(roomId: _roomId, body: 'waves'),
    ]);
    expect(find.text('* @alice waves'), findsOneWidget);
  });

  testWidgets('sends formatted HTML with a plain-text fallback', (
    tester,
  ) async {
    final service = _FakeMatrixService(initialMessages: const <MessageEvent>[]);

    await _pumpChat(tester, service);
    await tester.tap(find.text('HTML'));
    await tester.pump();
    await tester.enterText(
      find.byType(EditableText).first,
      '<strong>Bold</strong>',
    );
    await tester.enterText(find.byType(EditableText).last, 'Bold');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(service.htmlCalls, <_HtmlCall>[
      const _HtmlCall(
        roomId: _roomId,
        body: 'Bold',
        html: '<strong>Bold</strong>',
      ),
    ]);
    expect(find.text('Bold'), findsOneWidget);
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
  final List<_EditCall> editCalls = <_EditCall>[];
  final List<_HtmlCall> htmlCalls = <_HtmlCall>[];
  final List<_MessageCall> noticeCalls = <_MessageCall>[];
  final List<_MessageCall> emoteCalls = <_MessageCall>[];
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
  Future<String> sendHtml(String roomId, String body, String html) async {
    htmlCalls.add(_HtmlCall(roomId: roomId, body: body, html: html));
    return r'$html-local';
  }

  @override
  Future<String> sendNotice(String roomId, String body) async {
    noticeCalls.add(_MessageCall(roomId: roomId, body: body));
    return r'$notice-local';
  }

  @override
  Future<String> sendEmote(String roomId, String body) async {
    emoteCalls.add(_MessageCall(roomId: roomId, body: body));
    return r'$emote-local';
  }

  @override
  Future<void> editMessage(
    String roomId,
    String eventId,
    String newBody,
  ) async {
    editCalls.add(
      _EditCall(roomId: roomId, eventId: eventId, newBody: newBody),
    );
  }

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
  Future<bool> isRoomEncrypted(String roomId) async => false;

  @override
  Future<void> enableEncryption(String roomId) async {}

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

class _MessageCall {
  const _MessageCall({required this.roomId, required this.body});

  final String roomId;
  final String body;

  @override
  bool operator ==(Object other) {
    return other is _MessageCall &&
        other.roomId == roomId &&
        other.body == body;
  }

  @override
  int get hashCode => Object.hash(roomId, body);

  @override
  String toString() {
    return '_MessageCall(roomId: $roomId, body: $body)';
  }
}

class _HtmlCall {
  const _HtmlCall({
    required this.roomId,
    required this.body,
    required this.html,
  });

  final String roomId;
  final String body;
  final String html;

  @override
  bool operator ==(Object other) {
    return other is _HtmlCall &&
        other.roomId == roomId &&
        other.body == body &&
        other.html == html;
  }

  @override
  int get hashCode => Object.hash(roomId, body, html);

  @override
  String toString() {
    return '_HtmlCall(roomId: $roomId, body: $body, html: $html)';
  }
}

class _EditCall {
  const _EditCall({
    required this.roomId,
    required this.eventId,
    required this.newBody,
  });

  final String roomId;
  final String eventId;
  final String newBody;

  @override
  bool operator ==(Object other) {
    return other is _EditCall &&
        other.roomId == roomId &&
        other.eventId == eventId &&
        other.newBody == newBody;
  }

  @override
  int get hashCode => Object.hash(roomId, eventId, newBody);

  @override
  String toString() {
    return '_EditCall(roomId: $roomId, eventId: $eventId, newBody: $newBody)';
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

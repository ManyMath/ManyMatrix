import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manymatrix_app/src/matrix/bridge_service.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';
import 'package:manymatrix_app/src/matrix/room_timeline.dart';

void main() {
  test('initial load sends a read receipt for the newest message', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message('event-1', timestamp: 1),
        _message('event-2', timestamp: 2),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final subscription = container.listen(
      roomTimelineProvider(_roomId),
      (_, __) {},
    );
    addTearDown(subscription.close);

    final timeline = await container.read(roomTimelineProvider(_roomId).future);
    await Future<void>.delayed(Duration.zero);

    expect(timeline.newestFirst.map((m) => m.eventId), <String>[
      'event-2',
      'event-1',
    ]);
    expect(service.readReceipts, <({String roomId, String eventId})>[
      (roomId: _roomId, eventId: 'event-2'),
    ]);
  });

  test('live messages send one receipt and older pages do not', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[_message('event-1')],
      olderMessages: <MessageEvent>[_message('older-1')],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    await container.read(provider.future);
    await Future<void>.delayed(Duration.zero);
    expect(service.readReceipts.map((r) => r.eventId), <String>['event-1']);

    service.emit(_message('event-2', timestamp: 2));
    await Future<void>.delayed(Duration.zero);
    expect(service.readReceipts.map((r) => r.eventId), <String>[
      'event-1',
      'event-2',
    ]);

    service.emit(_message('event-2', timestamp: 2));
    await Future<void>.delayed(Duration.zero);
    expect(
      service.readReceipts.where((r) => r.eventId == 'event-2'),
      hasLength(1),
    );

    await container.read(provider.notifier).loadOlder();
    expect(service.readReceipts.map((r) => r.eventId), <String>[
      'event-1',
      'event-2',
    ]);
  });

  test('receipt failures do not fail timeline loading', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[_message('event-1')],
    )..failReadReceipt = true;
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    final timeline = await container.read(provider.future);
    await Future<void>.delayed(Duration.zero);

    expect(timeline.newestFirst.single.eventId, 'event-1');
    expect(service.readReceipts, isEmpty);
  });

  test('reaction and receipt callbacks attach metadata to messages', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[_message('event-1')],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    await container.read(provider.future);

    service
      ..emitReaction(_reaction('reaction-1', relatesToEventId: 'event-1'))
      ..emitReceipt(_receipt('event-1', userId: '@bob:example.org'));
    await Future<void>.delayed(Duration.zero);

    final timeline = container.read(provider).value!;
    expect(timeline.reactionsFor('event-1').single.key, '+1');
    expect(timeline.receiptsFor('event-1').single.userId, '@bob:example.org');
  });

  test('duplicates reactions and moves receipts by reader', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message('event-1', timestamp: 1),
        _message('event-2', timestamp: 2),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    await container.read(provider.future);

    final reaction = _reaction('reaction-1', relatesToEventId: 'event-1');
    service
      ..emitReaction(reaction)
      ..emitReaction(reaction)
      ..emitReceipt(_receipt('event-1', userId: '@bob:example.org'))
      ..emitReceipt(_receipt('event-2', userId: '@bob:example.org'));
    await Future<void>.delayed(Duration.zero);

    final timeline = container.read(provider).value!;
    expect(timeline.reactionsFor('event-1'), hasLength(1));
    expect(timeline.receiptsFor('event-1'), isEmpty);
    expect(timeline.receiptsFor('event-2').single.userId, '@bob:example.org');
  });
}

const _roomId = '!room:example.org';

ProviderContainer _container(_FakeMatrixService service) {
  return ProviderContainer(
    overrides: <Override>[matrixServiceProvider.overrideWithValue(service)],
  );
}

MessageEvent _message(String eventId, {int timestamp = 0}) {
  return MessageEvent(
    eventId: eventId,
    roomId: _roomId,
    sender: '@alice:example.org',
    body: eventId,
    msgtype: 'm.text',
    timestamp: timestamp,
  );
}

ReactionEvent _reaction(String eventId, {required String relatesToEventId}) {
  return ReactionEvent(
    eventId: eventId,
    roomId: _roomId,
    sender: '@bob:example.org',
    relatesToEventId: relatesToEventId,
    key: '+1',
    timestamp: 3,
  );
}

ReceiptEvent _receipt(String eventId, {required String userId}) {
  return ReceiptEvent(
    roomId: _roomId,
    userId: userId,
    eventId: eventId,
    receiptType: 'm.read',
    timestamp: 4,
  );
}

class _FakeMatrixService implements MatrixService {
  _FakeMatrixService({
    this.initialMessages = const <MessageEvent>[],
    this.olderMessages = const <MessageEvent>[],
  });

  final List<MessageEvent> initialMessages;
  final List<MessageEvent> olderMessages;
  final List<({String roomId, String eventId})> readReceipts =
      <({String roomId, String eventId})>[];
  bool failReadReceipt = false;

  final _messages = StreamController<MessageEvent>.broadcast();
  final _reactions = StreamController<ReactionEvent>.broadcast();
  final _receipts = StreamController<ReceiptEvent>.broadcast();

  void emit(MessageEvent event) {
    _messages.add(event);
  }

  void emitReaction(ReactionEvent event) {
    _reactions.add(event);
  }

  void emitReceipt(ReceiptEvent event) {
    _receipts.add(event);
  }

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
  }) async {
    return PaginatedMessages(
      messages: fromToken == null ? initialMessages : olderMessages,
      endToken: fromToken == null ? 'older' : null,
    );
  }

  @override
  Future<String> sendText(String roomId, String body) async => r'$local';

  @override
  Future<String> replyTo(String roomId, String eventId, String body) async =>
      r'$reply';

  @override
  Future<String> sendThreadReply(
    String roomId,
    String threadRootId,
    String body,
  ) async => r'$thread';

  @override
  Future<void> sendTyping(String roomId, bool typing) async {}

  @override
  Future<void> sendReadReceipt(String roomId, String eventId) async {
    if (failReadReceipt) throw Exception('M_FORBIDDEN');
    readReceipts.add((roomId: roomId, eventId: eventId));
  }

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

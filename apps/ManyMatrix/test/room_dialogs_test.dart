import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manyui/manyui.dart';
import 'package:manymatrix_app/src/app.dart';
import 'package:manymatrix_app/src/matrix/bridge_service.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';

/// Same fake used by login_page_test.dart, extended to track
/// create/join/invite calls for the room-dialogs flows.
class FakeMatrixService implements MatrixService {
  FakeMatrixService({this.failCreateWith, this.failJoinWith});

  final String? failCreateWith;
  final String? failJoinWith;

  List<RoomSummary> rooms = const <RoomSummary>[];
  String? lastCreatedName;
  String? lastCreatedTopic;
  String? lastJoinedTarget;
  final List<({String roomId, String userId})> invited =
      <({String roomId, String userId})>[];

  final _messages = StreamController<MessageEvent>.broadcast();
  String? _userId = '@alice:example.org';

  @override
  Stream<MessageEvent> get messageEvents => _messages.stream;

  @override
  Stream<ReactionEvent> get reactionEvents =>
      const Stream<ReactionEvent>.empty();

  @override
  Stream<ReceiptEvent> get receiptEvents => const Stream<ReceiptEvent>.empty();

  @override
  String? get currentUserId => _userId;

  @override
  Future<String?> restoreSession() async => _userId;

  @override
  Future<String> login({
    required String homeserverUrl,
    required String username,
    required String password,
  }) async {
    _userId = '@$username:example.org';
    return _userId!;
  }

  @override
  Future<void> logout() async {
    _userId = null;
  }

  @override
  Future<List<RoomSummary>> joinedRooms() async => rooms;

  @override
  Future<String> createRoom({String? name, String? topic}) async {
    if (failCreateWith != null) throw Exception(failCreateWith);
    lastCreatedName = name;
    lastCreatedTopic = topic;
    const roomId = '!new:example.org';
    rooms = <RoomSummary>[
      ...rooms,
      RoomSummary(roomId: roomId, displayName: name ?? roomId, unreadCount: 0),
    ];
    return roomId;
  }

  @override
  Future<String> joinRoom(String roomIdOrAlias) async {
    if (failJoinWith != null) throw Exception(failJoinWith);
    lastJoinedTarget = roomIdOrAlias;
    rooms = <RoomSummary>[
      ...rooms,
      RoomSummary(
        roomId: roomIdOrAlias,
        displayName: roomIdOrAlias,
        unreadCount: 0,
      ),
    ];
    return roomIdOrAlias;
  }

  @override
  Future<void> invite(String roomId, String userId) async {
    invited.add((roomId: roomId, userId: userId));
  }

  @override
  Future<PaginatedMessages> getMessages(
    String roomId, {
    String? fromToken,
    int limit = 50,
  }) async => PaginatedMessages(messages: <MessageEvent>[]);

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
  }
}

Widget _app(FakeMatrixService service) {
  return ProviderScope(
    overrides: [matrixServiceProvider.overrideWithValue(service)],
    child: const MWidgetsApp(
      debugShowCheckedModeBanner: false,
      home: AuthGate(),
    ),
  );
}

Future<void> _enterField(WidgetTester tester, Finder field, String text) async {
  final editable = find.descendant(
    of: field,
    matching: find.byType(EditableText),
  );
  await tester.showKeyboard(editable);
  await tester.pump();
  await tester.enterText(editable, text);
  await tester.pump();
}

Future<void> _pumpToRooms(
  WidgetTester tester,
  FakeMatrixService service,
) async {
  await tester.pumpWidget(_app(service));
  // AuthRestoring -> AuthAuthenticated (restoreSession returns a userId
  // immediately) -> rooms list loads.
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

void main() {
  group('create room dialog', () {
    testWidgets('creating a room adds it to the list and selects it', (
      tester,
    ) async {
      final service = FakeMatrixService();
      await _pumpToRooms(tester, service);

      expect(find.text('No rooms yet'), findsOneWidget);

      await tester.tap(find.text('Create room').first);
      await tester.pump();
      expect(find.text('Create room'), findsWidgets);

      await _enterField(tester, find.byType(MTextField).first, 'Test Room');
      await tester.tap(find.widgetWithText(MButton, 'Create'));
      await tester.pump();
      await tester.pump();

      expect(service.lastCreatedName, 'Test Room');
      expect(find.text('Test Room'), findsOneWidget);
      expect(find.text('No rooms yet'), findsNothing);
    });

    testWidgets(
      'a failed create shows an inline error and keeps the dialog open',
      (tester) async {
        final service = FakeMatrixService(failCreateWith: 'M_FORBIDDEN');
        await _pumpToRooms(tester, service);

        await tester.tap(find.text('Create room').first);
        await tester.pump();
        await tester.tap(find.widgetWithText(MButton, 'Create'));
        await tester.pump();
        await tester.pump();

        expect(find.textContaining('Could not create room'), findsOneWidget);
        // Dialog is still open -- Cancel button still present.
        expect(find.widgetWithText(MButton, 'Cancel'), findsOneWidget);
      },
    );
  });

  group('join room dialog', () {
    testWidgets('joining a room adds it to the list', (tester) async {
      final service = FakeMatrixService();
      await _pumpToRooms(tester, service);

      await tester.tap(find.text('Join room').first);
      await tester.pump();

      await _enterField(
        tester,
        find.byType(MTextField).first,
        '#existing:example.org',
      );
      await tester.tap(find.widgetWithText(MButton, 'Join'));
      await tester.pump();
      await tester.pump();

      expect(service.lastJoinedTarget, '#existing:example.org');
      expect(find.text('#existing:example.org'), findsOneWidget);
    });

    testWidgets('a failed join shows an inline error', (tester) async {
      final service = FakeMatrixService(failJoinWith: 'M_NOT_FOUND');
      await _pumpToRooms(tester, service);

      await tester.tap(find.text('Join room').first);
      await tester.pump();
      await _enterField(
        tester,
        find.byType(MTextField).first,
        '#missing:example.org',
      );
      await tester.tap(find.widgetWithText(MButton, 'Join'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Could not join room'), findsOneWidget);
    });
  });
}

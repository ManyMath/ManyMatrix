import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manyui/manyui.dart';
import 'package:manymatrix_app/src/matrix/bridge_service.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';
import 'package:manymatrix_app/src/room_info/room_info_page.dart';

/// Minimal fake for RoomInfoPage's MatrixService calls.
class _FakeModerationService implements MatrixService {
  _FakeModerationService({this.roomEncrypted = false});

  final List<({String userId, String? reason})> kicked =
      <({String userId, String? reason})>[];
  final List<({String userId, String? reason})> banned =
      <({String userId, String? reason})>[];
  bool failNext = false;
  bool roomEncrypted;
  bool failEncryptionStatus = false;
  bool failEnableEncryption = false;
  int enableEncryptionCalls = 0;

  @override
  Future<void> kick(String roomId, String userId, {String? reason}) async {
    if (failNext) throw Exception('M_FORBIDDEN');
    kicked.add((userId: userId, reason: reason));
  }

  @override
  Future<void> ban(String roomId, String userId, {String? reason}) async {
    if (failNext) throw Exception('M_FORBIDDEN');
    banned.add((userId: userId, reason: reason));
  }

  @override
  Stream<MessageEvent> get messageEvents => const Stream<MessageEvent>.empty();
  @override
  Stream<ReactionEvent> get reactionEvents =>
      const Stream<ReactionEvent>.empty();
  @override
  Stream<ReceiptEvent> get receiptEvents => const Stream<ReceiptEvent>.empty();
  @override
  String? get currentUserId => null;
  @override
  Future<String?> restoreSession() async => null;
  @override
  Future<String> login({
    required String homeserverUrl,
    required String username,
    required String password,
  }) async => throw UnimplementedError();
  @override
  Future<void> logout() async {}
  @override
  Future<List<RoomSummary>> joinedRooms() async => const <RoomSummary>[];
  @override
  Future<String> createRoom({String? name, String? topic}) async =>
      throw UnimplementedError();
  @override
  Future<String> joinRoom(String roomIdOrAlias) async =>
      throw UnimplementedError();
  @override
  Future<void> invite(String roomId, String userId) async {}
  @override
  Future<PaginatedMessages> getMessages(
    String roomId, {
    String? fromToken,
    int limit = 50,
  }) async => PaginatedMessages(messages: <MessageEvent>[]);
  @override
  Future<String> sendText(String roomId, String body) async => r'$local';
  @override
  Future<void> editMessage(
    String roomId,
    String eventId,
    String newBody,
  ) async {}
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
  Future<bool> isRoomEncrypted(String roomId) async {
    if (failEncryptionStatus) throw Exception('M_UNKNOWN');
    return roomEncrypted;
  }

  @override
  Future<void> enableEncryption(String roomId) async {
    enableEncryptionCalls += 1;
    if (failEnableEncryption) throw Exception('M_FORBIDDEN');
    roomEncrypted = true;
  }

  @override
  Future<void> redact(String roomId, String eventId, {String? reason}) async {}
  @override
  void dispose() {}
}

Widget _app(
  _FakeModerationService service,
  List<String> members, {
  String? currentUserId,
}) {
  return ProviderScope(
    overrides: [
      matrixServiceProvider.overrideWithValue(service),
      currentUserIdProvider.overrideWithValue(currentUserId),
      roomMembersProvider(
        '!room:example.org',
      ).overrideWith((ref) async => members),
    ],
    child: const MWidgetsApp(
      debugShowCheckedModeBanner: false,
      home: RoomInfoPage(roomId: '!room:example.org', roomName: 'Test Room'),
    ),
  );
}

void main() {
  group('RoomInfoPage encryption status', () {
    testWidgets('shows encrypted rooms as encrypted', (tester) async {
      final service = _FakeModerationService(roomEncrypted: true);
      await tester.pumpWidget(
        _app(service, const [
          '@alice:example.org',
        ], currentUserId: '@alice:example.org'),
      );
      await tester.pump();

      expect(find.text('Encryption'), findsOneWidget);
      expect(find.text('Encrypted'), findsOneWidget);
      expect(find.widgetWithText(MButton, 'Enable encryption'), findsNothing);
    });

    testWidgets('enables encryption after confirmation', (tester) async {
      final service = _FakeModerationService();
      await tester.pumpWidget(
        _app(service, const [
          '@alice:example.org',
        ], currentUserId: '@alice:example.org'),
      );
      await tester.pump();

      expect(find.text('Off'), findsOneWidget);
      await tester.tap(find.widgetWithText(MButton, 'Enable encryption'));
      await tester.pump();
      expect(find.text('Enable encryption?'), findsOneWidget);

      await tester.tap(find.widgetWithText(MButton, 'Enable encryption').last);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(service.enableEncryptionCalls, 1);
      expect(find.text('Encrypted'), findsOneWidget);
      expect(find.widgetWithText(MButton, 'Enable encryption'), findsNothing);
    });

    testWidgets('shows an inline error when checking encryption fails', (
      tester,
    ) async {
      final service = _FakeModerationService()..failEncryptionStatus = true;
      await tester.pumpWidget(
        _app(service, const [
          '@alice:example.org',
        ], currentUserId: '@alice:example.org'),
      );
      await tester.pump();

      expect(find.text('Error'), findsOneWidget);
      expect(find.textContaining('Could not check encryption'), findsOneWidget);
      expect(find.widgetWithText(MButton, 'Retry'), findsOneWidget);
    });

    testWidgets('shows an inline error when enabling encryption fails', (
      tester,
    ) async {
      final service = _FakeModerationService()..failEnableEncryption = true;
      await tester.pumpWidget(
        _app(service, const [
          '@alice:example.org',
        ], currentUserId: '@alice:example.org'),
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(MButton, 'Enable encryption'));
      await tester.pump();
      await tester.tap(find.widgetWithText(MButton, 'Enable encryption').last);
      await tester.pump();
      await tester.pump();

      expect(service.enableEncryptionCalls, 1);
      expect(
        find.textContaining('Could not enable encryption'),
        findsOneWidget,
      );
      expect(find.text('Off'), findsOneWidget);
    });
  });

  group('RoomInfoPage member list', () {
    testWidgets('lists members and hides kick/ban for the current user', (
      tester,
    ) async {
      final service = _FakeModerationService();
      await tester.pumpWidget(
        _app(service, const [
          '@alice:example.org',
          '@bob:example.org',
        ], currentUserId: '@alice:example.org'),
      );
      await tester.pump();

      expect(find.text('@alice:example.org'), findsOneWidget);
      expect(find.text('@bob:example.org'), findsOneWidget);
      // Only one Kick/Ban pair -- for bob, not alice (self).
      expect(find.widgetWithText(MButton, 'Kick'), findsOneWidget);
      expect(find.widgetWithText(MButton, 'Ban'), findsOneWidget);
    });

    testWidgets('kick requires confirmation and calls the service', (
      tester,
    ) async {
      final service = _FakeModerationService();
      await tester.pumpWidget(
        _app(service, const [
          '@bob:example.org',
        ], currentUserId: '@alice:example.org'),
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(MButton, 'Kick'));
      await tester.pump();
      expect(find.textContaining('Kick "@bob:example.org"?'), findsOneWidget);

      await tester.tap(find.widgetWithText(MButton, 'Kick').last);
      await tester.pump();
      await tester.pump();

      expect(service.kicked.single.userId, '@bob:example.org');
    });

    testWidgets('cancelling the confirm dialog does not call the service', (
      tester,
    ) async {
      final service = _FakeModerationService();
      await tester.pumpWidget(
        _app(service, const [
          '@bob:example.org',
        ], currentUserId: '@alice:example.org'),
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(MButton, 'Ban'));
      await tester.pump();
      await tester.tap(find.widgetWithText(MButton, 'Cancel'));
      await tester.pump();

      expect(service.banned, isEmpty);
    });

    testWidgets('a failed ban shows an error dialog', (tester) async {
      final service = _FakeModerationService()..failNext = true;
      await tester.pumpWidget(
        _app(service, const [
          '@bob:example.org',
        ], currentUserId: '@alice:example.org'),
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(MButton, 'Ban'));
      await tester.pump();
      await tester.tap(find.widgetWithText(MButton, 'Ban').last);
      await tester.pump();
      await tester.pump();

      expect(find.text('Ban failed'), findsOneWidget);
      expect(service.banned, isEmpty);
    });
  });
}

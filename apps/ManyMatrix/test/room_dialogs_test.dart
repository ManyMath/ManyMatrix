import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manyui/manyui.dart';
import 'package:manymatrix_app/src/app.dart';
import 'package:manymatrix_app/src/chat/chat_page.dart';
import 'package:manymatrix_app/src/matrix/account.dart';
import 'package:manymatrix_app/src/matrix/bridge_service.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';
import 'package:manymatrix_app/src/rooms/room_tile.dart';

/// Same fake used by login_page_test.dart, extended to track
/// create/join/invite calls for the room-dialogs flows.
class FakeMatrixService implements MatrixService {
  FakeMatrixService({
    this.failCreateWith,
    this.failJoinWith,
    this.createResult,
  });

  final String? failCreateWith;
  final String? failJoinWith;
  final Completer<String>? createResult;

  List<RoomSummary> rooms = const <RoomSummary>[];
  List<RoomInvite> roomInvites = const <RoomInvite>[];
  String? lastCreatedName;
  String? lastCreatedTopic;
  bool hasCreatedRoom = false;
  bool reportCreatedRoomSynced = true;
  bool omitCreatedRoomFromRefresh = false;
  bool hideJoinedRoomUntilSync = false;
  String? lastJoinedTarget;
  final List<String> declinedRooms = <String>[];
  int joinedRoomCalls = 0;
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
  Stream<SessionProblem> get sessionProblems =>
      const Stream<SessionProblem>.empty();

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
  Future<void> clearSavedSession({bool keepHomeserver = true}) async {}

  @override
  Future<List<RoomSummary>> joinedRooms() async {
    joinedRoomCalls += 1;
    if (omitCreatedRoomFromRefresh && joinedRoomCalls == 3) {
      return const <RoomSummary>[];
    }
    final createdName = lastCreatedName;
    if (!hasCreatedRoom || joinedRoomCalls < 2) return rooms;
    return rooms
        .map(
          (room) => RoomSummary(
            roomId: room.roomId,
            displayName: createdName ?? room.displayName,
            avatarUrl: room.avatarUrl,
            lastMessage: room.lastMessage,
            unreadCount: room.unreadCount,
            isSynced: reportCreatedRoomSynced,
          ),
        )
        .toList();
  }

  @override
  Future<List<RoomInvite>> invitedRooms() async => roomInvites;

  @override
  Future<String> createRoom({String? name, String? topic}) async {
    if (failCreateWith != null) throw Exception(failCreateWith);
    lastCreatedName = name;
    lastCreatedTopic = topic;
    hasCreatedRoom = true;
    final roomId = await createResult?.future ?? '!new:example.org';
    rooms = <RoomSummary>[
      ...rooms,
      RoomSummary(
        roomId: roomId,
        displayName: 'Empty Room',
        unreadCount: 0,
        isSynced: false,
      ),
    ];
    return roomId;
  }

  @override
  Future<String> joinRoom(String roomIdOrAlias) async {
    if (failJoinWith != null) throw Exception(failJoinWith);
    lastJoinedTarget = roomIdOrAlias;
    if (!hideJoinedRoomUntilSync) {
      rooms = <RoomSummary>[
        ...rooms,
        RoomSummary(
          roomId: roomIdOrAlias,
          displayName: roomIdOrAlias,
          unreadCount: 0,
        ),
      ];
    }
    roomInvites = roomInvites
        .where((invite) => invite.roomId != roomIdOrAlias)
        .toList();
    return roomIdOrAlias;
  }

  @override
  Future<void> leaveRoom(String roomId) async {
    declinedRooms.add(roomId);
    roomInvites = roomInvites
        .where((invite) => invite.roomId != roomId)
        .toList();
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
  Future<String> sendHtml(String roomId, String body, String html) async =>
      r'$html';

  @override
  Future<String> sendNotice(String roomId, String body) async => r'$notice';

  @override
  Future<String> sendEmote(String roomId, String body) async => r'$emote';

  @override
  Future<String> uploadMedia(
    String roomId,
    String filename,
    String mimeType,
    Uint8List data,
  ) async => r'$media';

  @override
  Future<Uint8List?> downloadMedia(String mxcUri) async => null;

  @override
  Future<Uint8List?> downloadMediaSource(
    Map<String, dynamic> mediaSource,
  ) async => null;

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
    String body, {
    String? inReplyToEventId,
  }) async => r'$thread';

  @override
  Future<void> sendTyping(String roomId, bool typing) async {}

  @override
  Future<void> sendReadReceipt(String roomId, String eventId) async {}

  @override
  Future<List<String>> roomMembers(String roomId) async => const <String>[];

  @override
  Future<RoomDetails> roomDetails(String roomId) async =>
      RoomDetails(roomId: roomId);

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
  }
}

Widget _app(FakeMatrixService service) {
  const account = SavedAccount(
    id: 'test-account',
    label: '@alice:example.org',
    homeserverUrl: 'https://example.org',
    userId: '@alice:example.org',
  );
  return ProviderScope(
    overrides: [
      accountsLoaderProvider.overrideWith((ref) async {}),
      accountsProvider.overrideWith((ref) => const <SavedAccount>[account]),
      activeAccountIdProvider.overrideWith((ref) => account.id),
      matrixServiceProvider.overrideWithValue(service),
    ],
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

Finder _fieldLabeled(String label) {
  return find.ancestor(of: find.text(label), matching: find.byType(MField));
}

void _setViewSize(WidgetTester tester, Size size) {
  final previousSize = tester.view.physicalSize;
  final previousDevicePixelRatio = tester.view.devicePixelRatio;
  addTearDown(() {
    tester.view.physicalSize = previousSize;
    tester.view.devicePixelRatio = previousDevicePixelRatio;
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
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

      await _enterField(tester, _fieldLabeled('Name (optional)'), 'Test Room');
      await tester.tap(find.widgetWithText(MButton, 'Create'));
      await tester.pump();
      await tester.pump();

      expect(service.lastCreatedName, 'Test Room');
      expect(service.rooms.single.displayName, 'Empty Room');
      expect(service.rooms.single.isSynced, isFalse);
      expect(find.text('Test Room'), findsOneWidget);
      expect(find.text('No rooms yet'), findsNothing);
    });

    testWidgets('unnamed room survives a refresh that omits it', (
      tester,
    ) async {
      _setViewSize(tester, const Size(1280, 800));
      final service = FakeMatrixService()..omitCreatedRoomFromRefresh = true;
      await _pumpToRooms(tester, service);

      await tester.tap(find.text('Create room').first);
      await tester.pump();
      await tester.tap(find.widgetWithText(MButton, 'Create'));
      await tester.pumpAndSettle();

      expect(service.lastCreatedName, isNull);
      expect(find.text('!new:example.org'), findsWidgets);
      expect(find.byType(ChatView), findsOneWidget);
      expect(find.text('Choose a conversation'), findsNothing);
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

    testWidgets('created room stays gated until its full state syncs', (
      tester,
    ) async {
      final service = FakeMatrixService()..reportCreatedRoomSynced = false;
      await _pumpToRooms(tester, service);

      await tester.tap(find.text('Create room').first);
      await tester.pump();
      await _enterField(tester, _fieldLabeled('Name (optional)'), 'Sync gate');
      await tester.tap(find.widgetWithText(MButton, 'Create'));
      for (var index = 0; index < 42; index += 1) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      expect(find.textContaining('Waiting for its first sync'), findsOneWidget);
      expect(find.widgetWithText(MButton, 'Check again'), findsOneWidget);
      expect(find.widgetWithText(MButton, 'Close'), findsOneWidget);
      expect(find.widgetWithText(MButton, 'Cancel'), findsNothing);
      expect(service.rooms.single.isSynced, isFalse);

      service.reportCreatedRoomSynced = true;
      await tester.tap(find.widgetWithText(MButton, 'Check again'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(MButton, 'Check again'), findsNothing);
      expect(find.text('Sync gate'), findsOneWidget);
    });

    testWidgets('idle dialogs dismiss with Escape and the scrim', (
      tester,
    ) async {
      final service = FakeMatrixService();
      await _pumpToRooms(tester, service);

      await tester.tap(find.text('Create room').first);
      await tester.pump();
      expect(find.widgetWithText(MButton, 'Cancel'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.widgetWithText(MButton, 'Cancel'), findsNothing);

      await tester.tap(find.text('Create room').first);
      await tester.pump();
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      expect(find.widgetWithText(MButton, 'Cancel'), findsNothing);
    });

    testWidgets('busy dialogs block Escape and scrim dismissal', (
      tester,
    ) async {
      final createResult = Completer<String>();
      final service = FakeMatrixService(createResult: createResult);
      await _pumpToRooms(tester, service);

      await tester.tap(find.text('Create room').first);
      await tester.pump();
      await tester.tap(find.widgetWithText(MButton, 'Create'));
      await tester.pump();
      expect(find.text('Creating...'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      expect(find.text('Creating...'), findsOneWidget);

      createResult.complete('!created:example.org');
      await tester.pumpAndSettle();
      expect(find.text('Creating...'), findsNothing);
    });
  });

  group('join room dialog', () {
    testWidgets('joining a room adds it to the list', (tester) async {
      _setViewSize(tester, const Size(1280, 800));
      final service = FakeMatrixService()..hideJoinedRoomUntilSync = true;
      await _pumpToRooms(tester, service);

      await tester.tap(find.text('Join room').first);
      await tester.pump();

      await _enterField(
        tester,
        _fieldLabeled('Room ID or alias'),
        '#existing:example.org',
      );
      await tester.tap(find.widgetWithText(MButton, 'Join'));
      await tester.pump();
      await tester.pump();

      expect(service.lastJoinedTarget, '#existing:example.org');
      expect(find.text('#existing:example.org'), findsWidgets);
      expect(find.text('No messages yet'), findsWidgets);
      expect(find.byType(ChatView), findsOneWidget);
      expect(find.text('Choose a conversation'), findsNothing);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(RoomTile).first),
      );
      expect(container.read(selectedRoomIdProvider), '#existing:example.org');
      final refreshRooms = find.byWidgetPredicate(
        (widget) => widget is MIconButton && widget.label == 'Refresh rooms',
      );
      await tester.tap(refreshRooms);
      await tester.pump();
      await tester.pump();

      expect(find.byType(ChatView), findsOneWidget);
      expect(container.read(selectedRoomIdProvider), '#existing:example.org');
    });

    testWidgets('a failed join shows an inline error', (tester) async {
      final service = FakeMatrixService(failJoinWith: 'M_NOT_FOUND');
      await _pumpToRooms(tester, service);

      await tester.tap(find.text('Join room').first);
      await tester.pump();
      await _enterField(
        tester,
        _fieldLabeled('Room ID or alias'),
        '#missing:example.org',
      );
      await tester.tap(find.widgetWithText(MButton, 'Join'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Could not join room'), findsOneWidget);
    });
  });

  group('room invitations', () {
    testWidgets('shows pending invites and accepts one', (tester) async {
      _setViewSize(tester, const Size(1280, 800));
      final service = FakeMatrixService()
        ..hideJoinedRoomUntilSync = true
        ..roomInvites = const <RoomInvite>[
          RoomInvite(
            roomId: '!invite:example.org',
            displayName: 'Project Room',
            canonicalAlias: '#project:example.org',
          ),
        ];
      await _pumpToRooms(tester, service);

      expect(find.text('Invitations'), findsOneWidget);
      expect(find.text('Project Room'), findsOneWidget);
      expect(find.text('#project:example.org'), findsOneWidget);

      await tester.tap(find.widgetWithText(MButton, 'Join').last);
      await tester.pump();
      await tester.pump();

      expect(service.lastJoinedTarget, '!invite:example.org');
      expect(find.text('Project Room'), findsWidgets);
      expect(find.text('No messages yet'), findsWidgets);
      expect(find.byType(ChatView), findsOneWidget);
      expect(find.text('Choose a conversation'), findsNothing);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(RoomTile).first),
      );
      expect(container.read(selectedRoomIdProvider), '!invite:example.org');
      final refreshRooms = find.byWidgetPredicate(
        (widget) => widget is MIconButton && widget.label == 'Refresh rooms',
      );
      await tester.tap(refreshRooms);
      await tester.pump();
      await tester.pump();

      expect(find.text('Project Room'), findsWidgets);
      expect(find.text('No messages yet'), findsWidgets);
      expect(find.byType(ChatView), findsOneWidget);
      expect(find.text('Choose a conversation'), findsNothing);
      expect(container.read(selectedRoomIdProvider), '!invite:example.org');
    });

    testWidgets('opens invite details before accepting', (tester) async {
      final service = FakeMatrixService()
        ..roomInvites = const <RoomInvite>[
          RoomInvite(
            roomId: '!invite:example.org',
            displayName: 'Project Room',
            topic: 'Planning and launch work',
            canonicalAlias: '#project:example.org',
            invitedUserId: '@guest:example.org',
            invitedDisplayName: 'Guest',
            inviterUserId: '@alice:example.org',
            inviterDisplayName: 'Alice',
          ),
        ];
      await _pumpToRooms(tester, service);

      await tester.tap(
        find
            .ancestor(
              of: find.text('Project Room'),
              matching: find.byType(MListTile),
            )
            .first,
      );
      await tester.pump();

      expect(find.text('Room invitation'), findsOneWidget);
      expect(find.text('Room ID'), findsOneWidget);
      expect(find.text('!invite:example.org'), findsOneWidget);
      expect(find.text('Aliases'), findsOneWidget);
      expect(find.text('#project:example.org'), findsWidgets);
      expect(find.text('Topic'), findsOneWidget);
      expect(find.text('Planning and launch work'), findsOneWidget);
      expect(find.text('Guest (@guest:example.org)'), findsOneWidget);
      expect(find.text('Alice (@alice:example.org)'), findsOneWidget);
    });

    testWidgets('declines a pending invite', (tester) async {
      final service = FakeMatrixService()
        ..roomInvites = const <RoomInvite>[
          RoomInvite(
            roomId: '!invite:example.org',
            displayName: 'Project Room',
          ),
        ];
      await _pumpToRooms(tester, service);

      await tester.tap(
        find.ancestor(
          of: find.text('Project Room'),
          matching: find.byType(MListTile),
        ),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(MButton, 'Decline'));
      await tester.pump();
      await tester.pump();

      expect(service.declinedRooms, <String>['!invite:example.org']);
    });
  });

  group('room workspace', () {
    testWidgets('sorts by recency and supports search and unread filtering', (
      tester,
    ) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final service = FakeMatrixService()
        ..rooms = <RoomSummary>[
          RoomSummary(
            roomId: '!older:example.org',
            displayName: 'Alpha room',
            unreadCount: 0,
            lastMessage: LastMessage(
              sender: '@bob:example.org',
              body: 'Older update',
              timestamp: now - 60000,
            ),
          ),
          RoomSummary(
            roomId: '!newer:example.org',
            displayName: 'Beta room',
            unreadCount: 3,
            lastMessage: LastMessage(
              sender: '@alice:example.org',
              body: 'Latest update',
              timestamp: now,
            ),
          ),
        ];
      await _pumpToRooms(tester, service);

      expect(
        tester.getTopLeft(find.text('Beta room')).dy,
        lessThan(tester.getTopLeft(find.text('Alpha room')).dy),
      );
      expect(find.text('You: Latest update'), findsOneWidget);

      await _enterField(tester, find.byType(MTextField).first, 'Alpha');
      expect(find.text('Alpha room'), findsOneWidget);
      expect(find.text('Beta room'), findsNothing);

      await _enterField(tester, find.byType(MTextField).first, 'missing');
      expect(find.text('No matching rooms'), findsOneWidget);
      await tester.tap(find.text('Show all rooms'));
      await tester.pump();
      expect(find.text('Alpha room'), findsOneWidget);
      expect(find.text('Beta room'), findsOneWidget);
      expect(
        tester
            .widget<MTextField>(find.byType(MTextField).first)
            .controller
            ?.value,
        isEmpty,
      );

      await tester.tap(find.text('Unread'));
      await tester.pump();
      expect(find.text('Beta room'), findsOneWidget);
      expect(find.text('Alpha room'), findsNothing);
    });

    testWidgets('uses push navigation at compact width without overflow', (
      tester,
    ) async {
      _setViewSize(tester, const Size(390, 760));
      final service = FakeMatrixService()
        ..rooms = <RoomSummary>[
          RoomSummary(
            roomId: '!compact:example.org',
            displayName: 'Compact room',
            unreadCount: 1,
          ),
        ];
      await _pumpToRooms(tester, service);

      await tester.tap(find.text('Compact room'));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Back to rooms'), findsWidgets);
      expect(find.text('No messages yet'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps room and conversation panes visible on desktop', (
      tester,
    ) async {
      _setViewSize(tester, const Size(1280, 800));
      final service = FakeMatrixService()
        ..rooms = <RoomSummary>[
          RoomSummary(
            roomId: '!desktop:example.org',
            displayName: 'Desktop room',
            unreadCount: 0,
          ),
        ];
      await _pumpToRooms(tester, service);

      expect(find.text('Choose a conversation'), findsOneWidget);
      await tester.tap(find.text('Desktop room'));
      await tester.pumpAndSettle();

      expect(find.text('Desktop room'), findsWidgets);
      expect(find.text('No messages yet'), findsWidgets);
      expect(find.bySemanticsLabel('Back to rooms'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('builds only visible keyed rooms in a large room list', (
      tester,
    ) async {
      final service = FakeMatrixService()
        ..rooms = List<RoomSummary>.generate(
          500,
          (index) => RoomSummary(
            roomId: '!room-$index:example.org',
            displayName: 'Room ${index.toString().padLeft(3, '0')}',
            unreadCount: 0,
          ),
        );
      await _pumpToRooms(tester, service);

      expect(find.byKey(const ValueKey('!room-0:example.org')), findsOneWidget);
      expect(find.byKey(const ValueKey('!room-499:example.org')), findsNothing);
      expect(find.byType(RoomTile).evaluate().length, lessThan(40));
    });

    testWidgets('builds only visible keyed invitations', (tester) async {
      final service = FakeMatrixService()
        ..roomInvites = List<RoomInvite>.generate(
          300,
          (index) => RoomInvite(
            roomId: '!invite-$index:example.org',
            displayName: 'Invite ${index.toString().padLeft(3, '0')}',
          ),
        );
      await _pumpToRooms(tester, service);

      expect(
        find.byKey(const ValueKey('!invite-0:example.org')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('!invite-299:example.org')),
        findsNothing,
      );
      expect(find.byType(MListTile).evaluate().length, lessThan(40));
    });
  });
}

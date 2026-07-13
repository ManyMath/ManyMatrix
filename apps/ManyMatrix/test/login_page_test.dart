import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manyui/manyui.dart';
import 'package:manymatrix_app/src/app.dart';
import 'package:manymatrix_app/src/matrix/account.dart';
import 'package:manymatrix_app/src/matrix/bridge_service.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory [MatrixService]; no FFI, no persistence.
class FakeMatrixService implements MatrixService {
  FakeMatrixService({this.failLoginWith});

  /// When non-null, [login] throws this string (as an exception message).
  String? failLoginWith;

  String? lastHomeserverUrl;
  String? lastUsername;
  String? lastPassword;

  final _messages = StreamController<MessageEvent>.broadcast();
  final _sessionProblems = StreamController<SessionProblem>.broadcast();
  String? _userId;

  @override
  Stream<MessageEvent> get messageEvents => _messages.stream;

  @override
  Stream<ReactionEvent> get reactionEvents =>
      const Stream<ReactionEvent>.empty();

  @override
  Stream<ReceiptEvent> get receiptEvents => const Stream<ReceiptEvent>.empty();

  @override
  Stream<SessionProblem> get sessionProblems => _sessionProblems.stream;

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
    lastHomeserverUrl = homeserverUrl;
    lastUsername = username;
    lastPassword = password;
    if (failLoginWith != null) {
      throw Exception(failLoginWith);
    }
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
  Future<List<RoomSummary>> joinedRooms() async => const <RoomSummary>[];

  @override
  Future<List<RoomInvite>> invitedRooms() async => const <RoomInvite>[];

  @override
  Future<String> createRoom({String? name, String? topic}) async =>
      '!new:example.org';

  @override
  Future<String> joinRoom(String roomIdOrAlias) async => roomIdOrAlias;

  @override
  Future<void> leaveRoom(String roomId) async {}

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

  List<String> membersForRoom = const <String>[];
  final List<String> kicked = <String>[];
  final List<String> banned = <String>[];
  final List<String> redacted = <String>[];

  @override
  Future<List<String>> roomMembers(String roomId) async => membersForRoom;

  @override
  Future<RoomDetails> roomDetails(String roomId) async =>
      RoomDetails(roomId: roomId);

  @override
  Future<bool> isRoomEncrypted(String roomId) async => false;

  @override
  Future<void> enableEncryption(String roomId) async {}

  @override
  Future<void> kick(String roomId, String userId, {String? reason}) async {
    kicked.add(userId);
  }

  @override
  Future<void> ban(String roomId, String userId, {String? reason}) async {
    banned.add(userId);
  }

  @override
  Future<void> redact(String roomId, String eventId, {String? reason}) async {
    redacted.add(eventId);
  }

  @override
  void dispose() {
    _messages.close();
    _sessionProblems.close();
  }
}

Widget _app(FakeMatrixService service) {
  return ProviderScope(
    overrides: [
      matrixServiceProvider.overrideWithValue(service),
      accountLocalDataCleanerProvider.overrideWithValue((_) async {}),
    ],
    child: const MWidgetsApp(
      debugShowCheckedModeBanner: false,
      home: AuthGate(),
    ),
  );
}

Future<void> _enterField(WidgetTester tester, int index, String text) async {
  final editable = find.descendant(
    of: find.byType(MTextField).at(index),
    matching: find.byType(EditableText),
  );
  // MTextField only opens its IME connection once the focus change has been
  // pumped, so focus first, pump a frame, then type.
  await tester.showKeyboard(editable);
  await tester.pump();
  await tester.enterText(editable, text);
  await tester.pump();
}

Future<void> _pumpPastRestore(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('signs in through the fake service and lands on rooms', (
    tester,
  ) async {
    final service = FakeMatrixService();
    await tester.pumpWidget(_app(service));
    await _pumpPastRestore(tester);

    expect(find.text('Sign in to Matrix'), findsOneWidget);

    await _enterField(tester, 1, 'alice');
    await _enterField(tester, 2, 'secret');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    await tester.pump();

    // Empty homeserver falls back to the default.
    expect(service.lastHomeserverUrl, 'https://matrix.org');
    expect(service.lastUsername, 'alice');
    expect(service.lastPassword, 'secret');

    // Authenticated: rooms page shows the user id and the (empty) room list.
    await tester.pump();
    expect(find.text('@alice:example.org'), findsOneWidget);
    expect(find.text('No rooms yet'), findsOneWidget);
  });

  testWidgets('exposes browser autofill semantics for Matrix credentials', (
    tester,
  ) async {
    final service = FakeMatrixService();
    await tester.pumpWidget(_app(service));
    await _pumpPastRestore(tester);

    expect(find.byType(AutofillGroup), findsOneWidget);
    final fields = tester.widgetList<EditableText>(find.byType(EditableText));
    expect(fields, hasLength(3));
    expect(fields.elementAt(0).autofillHints, const <String>[
      AutofillHints.url,
    ]);
    expect(fields.elementAt(1).autofillHints, const <String>[
      AutofillHints.username,
    ]);
    expect(fields.elementAt(2).autofillHints, const <String>[
      AutofillHints.password,
    ]);
  });

  testWidgets('shows a friendly error when credentials are rejected', (
    tester,
  ) async {
    final service = FakeMatrixService(failLoginWith: 'M_FORBIDDEN');
    await tester.pumpWidget(_app(service));
    await _pumpPastRestore(tester);

    await _enterField(tester, 0, 'https://example.org');
    await _enterField(tester, 1, 'alice');
    await _enterField(tester, 2, 'wrong');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    await tester.pump();

    expect(service.lastHomeserverUrl, 'https://example.org');
    expect(find.text('Incorrect username or password.'), findsOneWidget);
    expect(find.text('Sign in to Matrix'), findsOneWidget);
  });

  testWidgets('shows field validation instead of silently ignoring submit', (
    tester,
  ) async {
    final service = FakeMatrixService();
    await tester.pumpWidget(_app(service));
    await _pumpPastRestore(tester);

    await tester.tap(find.text('Sign in'));
    await tester.pump();

    expect(find.text('Enter your Matrix username.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    expect(service.lastUsername, isNull);
  });

  testWidgets('uses a revealable password field', (tester) async {
    final service = FakeMatrixService();
    await tester.pumpWidget(_app(service));
    await _pumpPastRestore(tester);

    expect(find.byType(MSecretField), findsOneWidget);
    expect(find.bySemanticsLabel('Show password'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Show password'));
    await tester.pump();
    expect(find.bySemanticsLabel('Hide password'), findsOneWidget);
  });

  testWidgets('sign-in surface fits a compact viewport', (tester) async {
    _setViewSize(tester, const Size(320, 640));
    final service = FakeMatrixService();
    await tester.pumpWidget(_app(service));
    await _pumpPastRestore(tester);

    expect(find.text('Sign in to Matrix'), findsOneWidget);
    expect(find.byType(MSecretField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('add-account screen can cancel back to the current account', (
    tester,
  ) async {
    final service = FakeMatrixService();
    await tester.pumpWidget(_app(service));
    await _pumpPastRestore(tester);

    await _enterField(tester, 1, 'alice');
    await _enterField(tester, 2, 'secret');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('@alice:example.org'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Accounts').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add account'));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Cancel adding account'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Cancel adding account'));
    await tester.pumpAndSettle();

    expect(find.text('@alice:example.org'), findsOneWidget);
    expect(find.text('No rooms yet'), findsOneWidget);
    expect(find.text('Sign in to Matrix'), findsNothing);
  });
}

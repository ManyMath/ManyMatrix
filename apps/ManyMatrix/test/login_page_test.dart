import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manyui/manyui.dart';
import 'package:manymatrix_app/src/app.dart';
import 'package:manymatrix_app/src/matrix/bridge_service.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';

/// In-memory [MatrixService]; no FFI, no persistence.
class FakeMatrixService implements MatrixService {
  FakeMatrixService({this.failLoginWith});

  /// When non-null, [login] throws this string (as an exception message).
  final String? failLoginWith;

  String? lastHomeserverUrl;
  String? lastUsername;
  String? lastPassword;

  final _messages = StreamController<MessageEvent>.broadcast();
  String? _userId;

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
  Future<String?> restoreSession() async => null;

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
  }) async => PaginatedMessages(messages: <MessageEvent>[]);

  @override
  Future<String> sendText(String roomId, String body) async => r'$local';

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

void main() {
  testWidgets('signs in through the fake service and lands on rooms', (
    tester,
  ) async {
    final service = FakeMatrixService();
    await tester.pumpWidget(_app(service));
    await tester.pump(); // AuthRestoring -> AuthUnauthenticated

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

  testWidgets('shows a friendly error when credentials are rejected', (
    tester,
  ) async {
    final service = FakeMatrixService(failLoginWith: 'M_FORBIDDEN');
    await tester.pumpWidget(_app(service));
    await tester.pump();

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
}

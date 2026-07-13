import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manymatrix_app/src/matrix/auth.dart';
import 'package:manymatrix_app/src/matrix/bridge_service.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';
import 'package:manymatrix_app/src/matrix/thread_timeline.dart';
import 'package:manymatrix_app/src/rooms/rooms_page.dart';
import 'package:manyui/manyui.dart';

const _roomId = '!product:example.org';
const _rootId = r'$root';

class _AuthenticatedController extends AuthController {
  @override
  AuthState build() => const AuthAuthenticated('@alice:example.org');
}

void main() {
  testWidgets(
    'unread shortcut navigates through index, replies, and clears unread',
    (tester) async {
      final service = _ThreadService();
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            matrixServiceProvider.overrideWithValue(service),
            currentUserIdProvider.overrideWithValue(service.currentUserId),
            authControllerProvider.overrideWith(_AuthenticatedController.new),
          ],
          child: const MWidgetsApp(
            debugShowCheckedModeBanner: false,
            home: RoomsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final shortcut = find.bySemanticsLabel('Threads, 2 unread replies');
      expect(shortcut, findsOneWidget);
      await tester.tap(shortcut);
      await tester.pumpAndSettle();

      expect(find.text('Threads'), findsWidgets);
      expect(find.text('Design review'), findsOneWidget);
      final indexedThread = find.bySemanticsLabel(
        'Open thread in Product, Design review, 2 replies, 2 unread replies',
      );
      expect(indexedThread, findsOneWidget);
      await tester.tap(indexedThread);
      await tester.pumpAndSettle();

      expect(find.text('Thread - 2 replies'), findsOneWidget);
      expect(find.text('First answer'), findsOneWidget);
      expect(find.text('Latest answer'), findsOneWidget);
      expect(find.text('Thread reply to alice'), findsOneWidget);
      expect(service.threadReceipts, <String>[r'$reply-2']);

      final messageField = find.descendant(
        of: find.bySemanticsLabel('Message'),
        matching: find.byType(EditableText),
      );
      expect(messageField, findsOneWidget);
      await tester.enterText(messageField, 'Follow-up');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send message'));
      await tester.pumpAndSettle();

      expect(service.sentThreadBodies, <String>['Follow-up']);
      expect(find.text('Follow-up'), findsOneWidget);
      expect(find.text('Thread - 3 replies'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Close thread'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Back to rooms'));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Threads'), findsOneWidget);
      expect(find.bySemanticsLabel('Threads, 2 unread replies'), findsNothing);
    },
  );

  testWidgets('unsupported thread index does not break rooms', (tester) async {
    final service = _ThreadService(indexError: UnsupportedError('/threads'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          matrixServiceProvider.overrideWithValue(service),
          currentUserIdProvider.overrideWithValue(service.currentUserId),
          authControllerProvider.overrideWith(_AuthenticatedController.new),
        ],
        child: const MWidgetsApp(
          debugShowCheckedModeBanner: false,
          home: RoomsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Product'), findsOneWidget);
    expect(find.bySemanticsLabel('Threads unavailable'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Threads unavailable'));
    await tester.pumpAndSettle();

    expect(find.text('Threads unavailable'), findsOneWidget);
    expect(
      find.textContaining('This homeserver did not provide the thread index'),
      findsOneWidget,
    );
    await tester.tap(find.bySemanticsLabel('Back to rooms'));
    await tester.pumpAndSettle();
    expect(find.text('Product'), findsOneWidget);
  });

  testWidgets('unknown unread state is explicit without hiding threads', (
    tester,
  ) async {
    final service = _ThreadService(unreadCount: null);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          matrixServiceProvider.overrideWithValue(service),
          currentUserIdProvider.overrideWithValue(service.currentUserId),
          authControllerProvider.overrideWith(_AuthenticatedController.new),
        ],
        child: const MWidgetsApp(
          debugShowCheckedModeBanner: false,
          home: RoomsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final shortcut = find.bySemanticsLabel(
      'Threads, some unread status unavailable',
    );
    expect(shortcut, findsOneWidget);
    await tester.tap(shortcut);
    await tester.pumpAndSettle();

    expect(find.text('Unread status unavailable'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Open thread in Product, Design review, 2 replies, unread status unavailable',
      ),
      findsOneWidget,
    );
  });

  testWidgets('failed first-activity refresh keeps shortcut navigable', (
    tester,
  ) async {
    final failedRefresh = Completer<List<ThreadSummary>>();
    final service = _ThreadService(
      indexResponses: <Future<List<ThreadSummary>>>[
        Future.value(const <ThreadSummary>[]),
        failedRefresh.future,
      ],
    );
    await _pumpRooms(tester, service);
    expect(find.bySemanticsLabel('Threads'), findsOneWidget);

    service.emit(
      _message(
        r'$first-reply',
        sender: '@bob:example.org',
        body: 'First thread activity',
        timestamp: 400,
        threadRoot: _rootId,
      ),
    );
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RoomsPage)),
    );
    final refresh = container.read(threadIndexProvider.notifier).refresh();
    await tester.pump();
    failedRefresh.completeError(StateError('offline'));
    await refresh;
    await tester.pump();

    final unknown = find.bySemanticsLabel(
      'Threads, 1 unread reply, some unread status unavailable',
    );
    expect(unknown, findsOneWidget);
    await tester.tap(unknown);
    await tester.pumpAndSettle();
    expect(find.text('Unread status unavailable'), findsOneWidget);
    expect(find.text('Message thread'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Open thread in $_roomId, Message thread, 1 reply, 1 unread reply',
      ),
      findsOneWidget,
    );
  });

  testWidgets('wide to narrow resize pushes selected thread as a chat route', (
    tester,
  ) async {
    final restoreView = _setViewSize(tester, const Size(1000, 760));
    addTearDown(restoreView);
    final service = _ThreadService();
    await _pumpRooms(tester, service);

    await tester.tap(find.bySemanticsLabel('Threads, 2 unread replies'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(600, 760);
    await tester.pump();
    await tester.tap(_indexedThread());
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Back to rooms'), findsOneWidget);
    expect(find.text('Thread - 2 replies'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow to wide resize opens selected thread in the room pane', (
    tester,
  ) async {
    final restoreView = _setViewSize(tester, const Size(600, 760));
    addTearDown(restoreView);
    final service = _ThreadService();
    await _pumpRooms(tester, service);

    await tester.tap(find.bySemanticsLabel('Threads, 2 unread replies'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1000, 760);
    await tester.pump();
    await tester.tap(_indexedThread());
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Back to rooms'), findsNothing);
    expect(find.text('Thread - 2 replies'), findsOneWidget);
    expect(find.text('Product'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

Finder _indexedThread() => find.bySemanticsLabel(
  'Open thread in Product, Design review, 2 replies, 2 unread replies',
);

Future<void> _pumpRooms(WidgetTester tester, _ThreadService service) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        matrixServiceProvider.overrideWithValue(service),
        currentUserIdProvider.overrideWithValue(service.currentUserId),
        authControllerProvider.overrideWith(_AuthenticatedController.new),
      ],
      child: const MWidgetsApp(
        debugShowCheckedModeBanner: false,
        home: RoomsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

VoidCallback _setViewSize(WidgetTester tester, Size size) {
  final previousSize = tester.view.physicalSize;
  final previousDevicePixelRatio = tester.view.devicePixelRatio;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  return () {
    tester.view.physicalSize = previousSize;
    tester.view.devicePixelRatio = previousDevicePixelRatio;
  };
}

class _ThreadService implements MatrixService, ThreadMatrixService {
  _ThreadService({
    this.indexError,
    this.unreadCount = 2,
    this.indexResponses = const <Future<List<ThreadSummary>>>[],
  });

  final Object? indexError;
  final int? unreadCount;
  final List<Future<List<ThreadSummary>>> indexResponses;
  final _messages = StreamController<MessageEvent>.broadcast();
  final List<String> threadReceipts = <String>[];
  final List<String> sentThreadBodies = <String>[];
  int _indexCall = 0;

  void emit(MessageEvent event) => _messages.add(event);

  MessageEvent get root => _message(
    _rootId,
    sender: '@alice:example.org',
    body: 'Design review',
    timestamp: 100,
  );

  List<MessageEvent> get replies => <MessageEvent>[
    _message(
      r'$reply-1',
      sender: '@bob:example.org',
      body: 'First answer',
      timestamp: 200,
      threadRoot: _rootId,
    ),
    _message(
      r'$reply-2',
      sender: '@carol:example.org',
      body: 'Latest answer',
      timestamp: 300,
      threadRoot: _rootId,
    ),
  ];

  @override
  String? get currentUserId => '@alice:example.org';

  @override
  Stream<MessageEvent> get messageEvents => _messages.stream;

  @override
  Stream<ReactionEvent> get reactionEvents => const Stream.empty();

  @override
  Stream<ReceiptEvent> get receiptEvents => const Stream.empty();

  @override
  Stream<SessionProblem> get sessionProblems => const Stream.empty();

  @override
  Future<List<RoomSummary>> joinedRooms() async => <RoomSummary>[
    RoomSummary(
      roomId: _roomId,
      displayName: 'Product',
      lastMessage: LastMessage(
        sender: replies.last.sender,
        body: replies.last.body,
        timestamp: replies.last.timestamp,
      ),
      unreadCount: 2,
    ),
  ];

  @override
  Future<List<RoomInvite>> invitedRooms() async => const <RoomInvite>[];

  @override
  Future<PaginatedMessages> getMessages(
    String roomId, {
    String? fromToken,
    int limit = 50,
  }) async => PaginatedMessages(messages: <MessageEvent>[root]);

  @override
  Future<List<ThreadSummary>> threadIndex({int limitPerRoom = 50}) async {
    if (indexError != null) throw indexError!;
    final call = _indexCall++;
    if (call < indexResponses.length) return indexResponses[call];
    return <ThreadSummary>[
      ThreadSummary(
        roomId: _roomId,
        roomName: 'Product',
        root: root,
        latestReply: replies.last,
        replyCount: replies.length,
        unreadCount: unreadCount,
        currentUserParticipated: true,
      ),
    ];
  }

  @override
  Future<PaginatedThreadMessages> getThreadMessages(
    String roomId,
    String threadRootEventId, {
    String? fromToken,
    int limit = 50,
  }) async => PaginatedThreadMessages(root: root, messages: replies);

  @override
  Future<void> sendThreadReadReceipt(
    String roomId,
    String threadRootEventId,
    String eventId,
  ) async {
    threadReceipts.add(eventId);
  }

  @override
  Future<String> sendThreadReply(
    String roomId,
    String threadRootId,
    String body, {
    String? inReplyToEventId,
  }) async {
    sentThreadBodies.add(body);
    return r'$local';
  }

  @override
  Future<void> sendTyping(String roomId, bool typing) async {}

  @override
  Future<void> sendReadReceipt(String roomId, String eventId) async {}

  @override
  Future<Uint8List?> downloadMedia(String mxcUri) async => null;

  @override
  void dispose() {
    unawaited(_messages.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MessageEvent _message(
  String eventId, {
  required String sender,
  required String body,
  required int timestamp,
  String? threadRoot,
}) => MessageEvent(
  eventId: eventId,
  roomId: _roomId,
  sender: sender,
  body: body,
  msgtype: 'm.text',
  timestamp: timestamp,
  threadRoot: threadRoot,
);

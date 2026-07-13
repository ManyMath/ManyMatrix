import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manymatrix_app/src/chat/chat_page.dart';
import 'package:manymatrix_app/src/chat/attachment_io.dart';
import 'package:manymatrix_app/src/chat/message_bubble.dart';
import 'package:manymatrix_app/src/matrix/auth.dart';
import 'package:manymatrix_app/src/matrix/bridge_service.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';
import 'package:manymatrix_app/src/matrix/thread_timeline.dart';
import 'package:manyui/manyui.dart';

void main() {
  testWidgets('sends the selected message as a reply', (tester) async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(r'$event-1', sender: '@bob:example.org', body: 'Original'),
      ],
    );

    await _pumpChat(tester, service);
    await _tapAction(tester, 'Reply');
    await tester.pump();

    expect(find.text('Replying to bob'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'Answer');
    await tester.pump();
    expect(_iconButton(tester, 'Send message').onPressed, isNotNull);
    await _tapAction(tester, 'Send message');
    await tester.pumpAndSettle();

    expect(service.replyCalls, <_ReplyCall>[
      const _ReplyCall(roomId: _roomId, eventId: r'$event-1', body: 'Answer'),
    ]);
    expect(find.text('Replying to bob'), findsNothing);
    expect(find.text('Answer'), findsOneWidget);
    expect(find.bySemanticsLabel('Reply'), findsWidgets);
    expect(find.textContaining(r'$event-1'), findsNothing);
  });

  testWidgets('sends thread replies against the thread root', (tester) async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(r'$root-event', sender: '@alice:example.org', body: 'Root'),
        _message(
          r'$reply-1',
          sender: '@bob:example.org',
          body: 'Existing thread message',
          threadRoot: r'$root-event',
        ),
      ],
    );

    await _pumpChat(tester, service);
    expect(find.text('Existing thread message'), findsNothing);
    const openThreadLabel = 'Open thread, 1 reply, unread status unavailable';
    expect(find.bySemanticsLabel(openThreadLabel), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(openThreadLabel));
    await tester.pumpAndSettle();

    expect(find.text('Existing thread message'), findsOneWidget);
    expect(find.text('Thread reply to alice'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'Thread answer');
    await tester.pump();
    await _tapAction(tester, 'Send message');
    await tester.pumpAndSettle();

    expect(service.threadCalls, <_ThreadCall>[
      const _ThreadCall(
        roomId: _roomId,
        threadRootId: r'$root-event',
        inReplyToEventId: r'$root-event',
        body: 'Thread answer',
      ),
    ]);
    expect(service.textCalls, isEmpty);
    expect(find.text('Thread reply to alice'), findsOneWidget);
    expect(find.text('Thread answer'), findsOneWidget);
    expect(find.text('Thread reply'), findsWidgets);
    expect(find.textContaining(r'$root-event'), findsNothing);

    final nestedBubble = find.ancestor(
      of: find.text('Existing thread message'),
      matching: find.byType(MessageBubble),
    );
    await tester.tap(
      find
          .descendant(of: nestedBubble, matching: _iconButtonFinder('Reply'))
          .first,
    );
    await tester.pump();
    expect(find.text('Thread reply to bob'), findsOneWidget);
    await tester.enterText(find.byType(EditableText), 'Nested answer');
    await tester.pump();
    await _tapAction(tester, 'Send message');
    await tester.pumpAndSettle();

    expect(
      service.threadCalls.last,
      const _ThreadCall(
        roomId: _roomId,
        threadRootId: r'$root-event',
        inReplyToEventId: r'$reply-1',
        body: 'Nested answer',
      ),
    );
    service.emitMessage(
      _message(
        r'$thread-local-2',
        sender: '@alice:example.org',
        body: 'Nested answer',
        threadRoot: r'$root-event',
        inReplyTo: r'$reply-1',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Nested answer'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Close thread'));
    await tester.pumpAndSettle();

    expect(find.text('Thread answer'), findsNothing);
    expect(find.text('Existing thread message'), findsNothing);
    expect(
      find.bySemanticsLabel(
        'Open thread, 3 replies, unread status unavailable',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'shows the authoritative count when only part of a thread loaded',
    (tester) async {
      final service = _FakeThreadMatrixService(
        initialMessages: <MessageEvent>[
          _message(r'$root', sender: '@alice:example.org', body: 'Root'),
          _message(
            r'$reply',
            sender: '@bob:example.org',
            body: 'Loaded reply',
            threadRoot: r'$root',
          ),
        ],
        authoritativeReplyCount: 200,
      );

      await _pumpChat(tester, service);
      expect(find.bySemanticsLabel('Open thread, 200 replies'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Open thread, 200 replies'));
      await tester.pumpAndSettle();

      expect(find.text('Thread - 200 replies, 1 loaded'), findsOneWidget);
      expect(find.text('Loaded reply'), findsOneWidget);
    },
  );

  testWidgets('inserts room-only history behind newer server replies', (
    tester,
  ) async {
    final root = _message(
      r'$root',
      sender: '@alice:example.org',
      body: 'Root',
      timestamp: 100,
    );
    final older = _message(
      r'$older',
      sender: '@bob:example.org',
      body: 'Older room reply',
      threadRoot: root.eventId,
      timestamp: 200,
    );
    final latest = _message(
      r'$latest',
      sender: '@carol:example.org',
      body: 'Latest server reply',
      threadRoot: root.eventId,
      timestamp: 300,
    );
    final service = _FakeThreadMatrixService(
      initialMessages: <MessageEvent>[root, older, latest],
      authoritativeReplyCount: 2,
      remoteReplies: <MessageEvent>[latest],
    );

    await _pumpChat(tester, service);
    await tester.tap(find.bySemanticsLabel('Open thread, 2 replies'));
    await tester.pumpAndSettle();

    final threadOrder = tester
        .widgetList<MessageBubble>(find.byType(MessageBubble))
        .where((bubble) => bubble.message.threadRoot == root.eventId)
        .map((bubble) => bubble.message.eventId)
        .toList();
    expect(threadOrder, <String>[latest.eventId, older.eventId]);
  });

  testWidgets('keeps thread unread state unknown while the index is loading', (
    tester,
  ) async {
    final pendingIndex = Completer<List<ThreadSummary>>();
    addTearDown(() {
      if (!pendingIndex.isCompleted) pendingIndex.complete(const []);
    });
    final service = _FakeThreadMatrixService(
      initialMessages: <MessageEvent>[
        _message(r'$root', sender: '@alice:example.org', body: 'Root'),
        _message(
          r'$reply',
          sender: '@bob:example.org',
          body: 'Reply',
          threadRoot: r'$root',
        ),
      ],
      indexFuture: pendingIndex.future,
    );

    await _pumpChat(tester, service);

    expect(
      find.bySemanticsLabel('Open thread, 1 reply, unread status unavailable'),
      findsOneWidget,
    );
  });

  testWidgets('edits own text messages from the composer', (tester) async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(r'$event-1', sender: '@alice:example.org', body: 'Original'),
      ],
    );

    await _pumpChat(tester, service);
    await _openMessageActions(tester);
    await tester.tap(find.text('Edit'));
    await tester.pump();

    expect(find.text('Editing alice'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'Edited body');
    await tester.pump();
    await _tapAction(tester, 'Save edit');
    await tester.pumpAndSettle();

    expect(service.editCalls, <_EditCall>[
      const _EditCall(
        roomId: _roomId,
        eventId: r'$event-1',
        newBody: 'Edited body',
      ),
    ]);
    expect(find.text('Editing alice'), findsNothing);
    expect(find.text('Original'), findsNothing);
    expect(find.text('Edited body'), findsOneWidget);
    expect(find.textContaining('edited'), findsOneWidget);
  });

  testWidgets('main and thread receipt scopes render only in their context', (
    tester,
  ) async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(r'$root', sender: '@alice:example.org', body: 'Root'),
        _message(
          r'$reply',
          sender: '@bob:example.org',
          body: 'Reply',
          threadRoot: r'$root',
        ),
      ],
    );
    await _pumpChat(tester, service);
    await tester.tap(
      find.bySemanticsLabel('Open thread, 1 reply, unread status unavailable'),
    );
    await tester.pumpAndSettle();

    service
      ..emitReceipt(_receipt(r'$root', '@main:example.org', 'main'))
      ..emitReceipt(_receipt(r'$root', '@thread:example.org', r'$root'))
      ..emitReceipt(_receipt(r'$root', '@other:example.org', r'$other-root'));
    await tester.pumpAndSettle();

    final rootBubbles = tester
        .widgetList<MessageBubble>(find.byType(MessageBubble))
        .where((bubble) => bubble.message.eventId == r'$root')
        .toList();
    expect(rootBubbles, hasLength(2));
    final renderedScopes = rootBubbles
        .map(
          (bubble) =>
              bubble.receipts.map((receipt) => receipt.threadId).toSet(),
        )
        .toList();
    expect(
      renderedScopes.any(
        (scopes) => scopes.length == 1 && scopes.contains('main'),
      ),
      isTrue,
    );
    expect(
      renderedScopes.any(
        (scopes) => scopes.length == 1 && scopes.contains(r'$root'),
      ),
      isTrue,
    );
    expect(
      renderedScopes.expand((scopes) => scopes),
      isNot(contains(r'$other-root')),
    );
  });

  testWidgets('removes a successfully redacted message immediately', (
    tester,
  ) async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(r'$event-1', sender: '@alice:example.org', body: 'Remove me'),
      ],
    );

    await _pumpChat(tester, service);
    await _openMessageActions(tester);
    await tester.ensureVisible(find.text('Delete message'));
    await tester.pump();
    await tester.tap(find.text('Delete message'));
    await tester.pump();
    await tester.tap(find.widgetWithText(MButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(service.redactedEventIds, <String>[r'$event-1']);
    expect(find.text('Remove me'), findsNothing);
    expect(find.text('No messages yet'), findsOneWidget);
  });

  testWidgets('switching from edit to reply clears the edit body', (
    tester,
  ) async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(r'$event-1', sender: '@alice:example.org', body: 'Original'),
      ],
    );

    await _pumpChat(tester, service);
    await _openMessageActions(tester);
    await tester.tap(find.text('Edit'));
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      'Original',
    );

    await _tapAction(tester, 'Reply');
    await tester.pump();
    expect(find.text('Replying to alice'), findsOneWidget);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      isEmpty,
    );
    expect(_iconButton(tester, 'Send message').onPressed, isNull);

    await tester.enterText(find.byType(EditableText), 'Fresh reply');
    await tester.pump();
    await _tapAction(tester, 'Send message');
    await tester.pumpAndSettle();

    expect(service.editCalls, isEmpty);
    expect(service.replyCalls, <_ReplyCall>[
      const _ReplyCall(
        roomId: _roomId,
        eventId: r'$event-1',
        body: 'Fresh reply',
      ),
    ]);
  });

  testWidgets('sends notice messages from the composer mode control', (
    tester,
  ) async {
    final service = _FakeMatrixService(initialMessages: const <MessageEvent>[]);

    await _pumpChat(tester, service);
    await _selectMessageMode(tester, 'Notice');
    await tester.enterText(find.byType(EditableText), 'Maintenance soon');
    await tester.pump();
    await _tapAction(tester, 'Send message');
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
    await _selectMessageMode(tester, 'Emote');
    await tester.enterText(find.byType(EditableText), 'waves');
    await tester.pump();
    await _tapAction(tester, 'Send message');
    await tester.pumpAndSettle();

    expect(service.emoteCalls, <_MessageCall>[
      const _MessageCall(roomId: _roomId, body: 'waves'),
    ]);
    expect(find.text('* You waves'), findsOneWidget);
  });

  testWidgets('sends formatted HTML with a plain-text fallback', (
    tester,
  ) async {
    final service = _FakeMatrixService(initialMessages: const <MessageEvent>[]);

    await _pumpChat(tester, service);
    await _selectMessageMode(tester, 'HTML');
    await tester.enterText(
      find.byType(EditableText).first,
      '<strong>Bold</strong>',
    );
    await tester.enterText(find.byType(EditableText).last, 'Bold');
    await tester.pump();
    await _tapAction(tester, 'Send message');
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

  testWidgets('keeps outgoing messages inside a centered readable lane', (
    tester,
  ) async {
    final previousSize = tester.view.physicalSize;
    final previousDevicePixelRatio = tester.view.devicePixelRatio;
    addTearDown(() {
      tester.view.physicalSize = previousSize;
      tester.view.devicePixelRatio = previousDevicePixelRatio;
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1466, 1000);

    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(r'$event-1', sender: '@alice:example.org', body: 'Readable'),
      ],
    );

    await _pumpChat(tester, service);

    final messageRect = tester.getRect(find.text('Readable'));
    expect(messageRect.right, lessThan(1210));
    expect(messageRect.left, greaterThan(560));
  });

  testWidgets('composer is stable at compact width and disables empty send', (
    tester,
  ) async {
    final previousSize = tester.view.physicalSize;
    final previousDevicePixelRatio = tester.view.devicePixelRatio;
    addTearDown(() {
      tester.view.physicalSize = previousSize;
      tester.view.devicePixelRatio = previousDevicePixelRatio;
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);

    final service = _FakeMatrixService(initialMessages: const <MessageEvent>[]);
    await _pumpChat(tester, service);

    final sendFinder = find.byWidgetPredicate(
      (widget) => widget is MIconButton && widget.label == 'Send message',
    );
    final send = tester.widget<MIconButton>(sendFinder);
    expect(send.onPressed, isNull);
    expect(_messageTypeControl(), findsNothing);
    expect(_iconButtonFinder('Message options'), findsOneWidget);
    await _tapAction(tester, 'Message options');
    expect(_messageTypeControl(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact thread is primary and closes with Escape or system Back',
    (tester) async {
      final previousSize = tester.view.physicalSize;
      final previousDevicePixelRatio = tester.view.devicePixelRatio;
      addTearDown(() {
        tester.view.physicalSize = previousSize;
        tester.view.devicePixelRatio = previousDevicePixelRatio;
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);

      final service = _FakeMatrixService(
        initialMessages: <MessageEvent>[
          _message(r'$root', sender: '@alice:example.org', body: 'Root'),
          _message(
            r'$reply',
            sender: '@bob:example.org',
            body: 'Thread reply body',
            threadRoot: r'$root',
          ),
        ],
      );
      await _pumpChat(tester, service);
      const openLabel = 'Open thread, 1 reply, unread status unavailable';

      await tester.tap(find.bySemanticsLabel(openLabel));
      await tester.pumpAndSettle();

      expect(find.text('Thread - 1 reply'), findsOneWidget);
      expect(find.text('Thread reply body'), findsOneWidget);
      expect(
        tester
            .widgetList<MessageBubble>(find.byType(MessageBubble))
            .where((bubble) => bubble.message.eventId == r'$root'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Thread - 1 reply'), findsNothing);
      expect(find.bySemanticsLabel(openLabel), findsOneWidget);

      await tester.tap(find.bySemanticsLabel(openLabel));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Thread - 1 reply'), findsNothing);
      expect(find.bySemanticsLabel(openLabel), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('covering the room route hides its selected thread', (
    tester,
  ) async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(r'$root', sender: '@alice:example.org', body: 'Root'),
        _message(
          r'$reply',
          sender: '@bob:example.org',
          body: 'Thread reply body',
          threadRoot: r'$root',
        ),
      ],
    );
    await _pumpChat(tester, service);
    await tester.tap(
      find.bySemanticsLabel('Open thread, 1 reply, unread status unavailable'),
    );
    await tester.pumpAndSettle();
    final chatContext = tester.element(find.byType(ChatView));
    final container = ProviderScope.containerOf(chatContext);
    const key = ThreadKey(roomId: _roomId, rootEventId: r'$root');
    expect(container.read(threadVisibilityProvider(key)), isTrue);

    unawaited(
      Navigator.of(chatContext).push<void>(
        PageRouteBuilder<void>(
          pageBuilder: (context, animation, secondaryAnimation) =>
              const SizedBox.expand(child: Text('Covering route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(threadVisibilityProvider(key)), isFalse);

    Navigator.of(tester.element(find.text('Covering route'))).pop();
    await tester.pumpAndSettle();
    expect(container.read(threadVisibilityProvider(key)), isTrue);
  });

  testWidgets('composer sends multiline text without flattening it', (
    tester,
  ) async {
    final service = _FakeMatrixService(initialMessages: const <MessageEvent>[]);
    await _pumpChat(tester, service);

    await tester.enterText(
      find.byType(EditableText),
      'First line\nSecond line',
    );
    await tester.pump();
    await _tapAction(tester, 'Send message');
    await tester.pumpAndSettle();

    expect(service.textCalls, <_MessageCall>[
      const _MessageCall(roomId: _roomId, body: 'First line\nSecond line'),
    ]);
  });

  testWidgets('composer uploads a picked attachment and adds a local echo', (
    tester,
  ) async {
    final service = _FakeMatrixService(initialMessages: const <MessageEvent>[]);
    await _pumpChat(
      tester,
      service,
      attachmentPicker: () async => PickedAttachment(
        filename: 'proof.txt',
        mimeType: 'text/plain',
        data: Uint8List.fromList(<int>[1, 2, 3]),
      ),
    );

    await _tapAction(tester, 'Attach file');
    await tester.pumpAndSettle();

    expect(service.uploadCalls, hasLength(1));
    expect(service.uploadCalls.single.roomId, _roomId);
    expect(service.uploadCalls.single.filename, 'proof.txt');
    expect(service.uploadCalls.single.mimeType, 'text/plain');
    expect(service.uploadCalls.single.data, <int>[1, 2, 3]);
    expect(find.text('File attachment'), findsOneWidget);
    expect(find.text('proof.txt'), findsOneWidget);
  });

  testWidgets('composer reports an oversized attachment without uploading', (
    tester,
  ) async {
    final service = _FakeMatrixService(initialMessages: const <MessageEvent>[]);
    await _pumpChat(
      tester,
      service,
      attachmentPicker: () async =>
          throw const AttachmentTooLargeException(maxAttachmentBytes + 1),
    );

    await _tapAction(tester, 'Attach file');
    await tester.pumpAndSettle();

    expect(service.uploadCalls, isEmpty);
    expect(find.textContaining('25 MiB attachment limit'), findsOneWidget);
  });

  testWidgets('auto-loads older history when the first page is thread-only', (
    tester,
  ) async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(
          r'$thread-only',
          sender: '@bob:example.org',
          body: 'Thread-only newest page',
          threadRoot: r'$older-root',
        ),
      ],
      olderMessages: <MessageEvent>[
        _message(
          r'$older-root',
          sender: '@alice:example.org',
          body: 'Earlier main conversation',
        ),
      ],
    );

    await _pumpChat(tester, service);

    expect(service.olderPageCalls, 1);
    expect(find.text('Earlier main conversation'), findsOneWidget);
    expect(find.text('Thread-only newest page'), findsNothing);
    expect(find.text('No messages yet'), findsNothing);
  });

  testWidgets('builds only visible keyed messages for a long timeline', (
    tester,
  ) async {
    final service = _FakeMatrixService(
      initialMessages: List<MessageEvent>.generate(
        300,
        (index) => _message(
          'event-$index',
          sender: '@bob:example.org',
          body: 'Message ${index.toString().padLeft(3, '0')}',
        ),
      ),
    );

    await _pumpChat(tester, service);

    expect(find.byKey(const ValueKey('event-299')), findsOneWidget);
    expect(find.byKey(const ValueKey('event-0')), findsNothing);
    expect(find.byType(MessageBubble).evaluate().length, lessThan(40));
  });

  testWidgets('ignores a send completion after the composer is disposed', (
    tester,
  ) async {
    final sendResult = Completer<String>();
    final service = _FakeMatrixService(
      initialMessages: const <MessageEvent>[],
      sendTextResult: sendResult,
    );
    await _pumpChat(tester, service);
    await tester.enterText(find.byType(EditableText), 'Delayed send');
    await tester.pump();
    await _tapAction(tester, 'Send message');
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    sendResult.complete(r'$late-event');
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('an old send completion preserves a newly selected reply draft', (
    tester,
  ) async {
    final sendResult = Completer<String>();
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(r'$event-1', sender: '@bob:example.org', body: 'Reply target'),
      ],
      sendTextResult: sendResult,
    );
    await _pumpChat(tester, service);
    await tester.enterText(find.byType(EditableText), 'Delayed send');
    await tester.pump();
    await _tapAction(tester, 'Send message');
    await tester.pump();

    await _tapAction(tester, 'Reply');
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'New reply draft');
    await tester.pump();
    sendResult.complete(r'$late-event');
    await tester.pumpAndSettle();

    expect(find.text('Replying to bob'), findsOneWidget);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      'New reply draft',
    );
    expect(service.replyCalls, isEmpty);
  });
}

const _roomId = '!room:example.org';

Future<void> _pumpChat(
  WidgetTester tester,
  _FakeMatrixService service, {
  AttachmentPicker? attachmentPicker,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        matrixServiceProvider.overrideWithValue(service),
        currentUserIdProvider.overrideWithValue(service.currentUserId),
        authControllerProvider.overrideWith(_AuthenticatedController.new),
        if (attachmentPicker != null)
          attachmentPickerProvider.overrideWithValue(attachmentPicker),
      ],
      child: const MWidgetsApp(
        debugShowCheckedModeBanner: false,
        home: ChatView(roomId: _roomId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _AuthenticatedController extends AuthController {
  @override
  AuthState build() => const AuthAuthenticated('@alice:example.org');
}

Future<void> _tapAction(WidgetTester tester, String label) async {
  await tester.tap(_iconButtonFinder(label).first);
  await tester.pump();
}

MIconButton _iconButton(WidgetTester tester, String label) =>
    tester.widget<MIconButton>(_iconButtonFinder(label).first);

Finder _iconButtonFinder(String label) => find.byWidgetPredicate(
  (widget) => widget is MIconButton && widget.label == label,
);

Future<void> _openMessageActions(WidgetTester tester) async {
  await _tapAction(tester, 'More message actions');
}

Future<void> _selectMessageMode(WidgetTester tester, String label) async {
  if (find.bySemanticsLabel('$label message type').evaluate().isEmpty) {
    await _tapAction(tester, 'Message options');
  }
  await tester.tap(find.bySemanticsLabel('$label message type'));
  await tester.pump();
}

Finder _messageTypeControl() => find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString().startsWith('MSegmentedControl<'),
);

MessageEvent _message(
  String eventId, {
  required String sender,
  required String body,
  String? threadRoot,
  String? inReplyTo,
  int timestamp = 1700000000000,
}) {
  return MessageEvent(
    eventId: eventId,
    roomId: _roomId,
    sender: sender,
    body: body,
    msgtype: 'm.text',
    timestamp: timestamp,
    threadRoot: threadRoot,
    inReplyTo: inReplyTo,
  );
}

ReceiptEvent _receipt(String eventId, String userId, String? threadId) =>
    ReceiptEvent(
      roomId: _roomId,
      userId: userId,
      eventId: eventId,
      receiptType: 'm.read',
      threadId: threadId,
      timestamp: 1700000000100,
    );

class _FakeMatrixService implements MatrixService {
  _FakeMatrixService({
    required this.initialMessages,
    this.olderMessages = const <MessageEvent>[],
    this.sendTextResult,
  });

  final List<MessageEvent> initialMessages;
  final List<MessageEvent> olderMessages;
  final Completer<String>? sendTextResult;
  int olderPageCalls = 0;
  final List<_EditCall> editCalls = <_EditCall>[];
  final List<_HtmlCall> htmlCalls = <_HtmlCall>[];
  final List<_MessageCall> textCalls = <_MessageCall>[];
  final List<_MessageCall> noticeCalls = <_MessageCall>[];
  final List<_MessageCall> emoteCalls = <_MessageCall>[];
  final List<_ReplyCall> replyCalls = <_ReplyCall>[];
  final List<_ThreadCall> threadCalls = <_ThreadCall>[];
  final List<_UploadCall> uploadCalls = <_UploadCall>[];
  final List<String> redactedEventIds = <String>[];

  final _messages = StreamController<MessageEvent>.broadcast();
  final _reactions = StreamController<ReactionEvent>.broadcast();
  final _receipts = StreamController<ReceiptEvent>.broadcast();

  void emitMessage(MessageEvent event) => _messages.add(event);
  void emitReceipt(ReceiptEvent event) => _receipts.add(event);

  @override
  Stream<MessageEvent> get messageEvents => _messages.stream;

  @override
  Stream<ReactionEvent> get reactionEvents => _reactions.stream;

  @override
  Stream<ReceiptEvent> get receiptEvents => _receipts.stream;

  @override
  Stream<SessionProblem> get sessionProblems =>
      const Stream<SessionProblem>.empty();

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
  }) async {
    if (fromToken != null) {
      olderPageCalls += 1;
      return PaginatedMessages(messages: olderMessages);
    }
    return PaginatedMessages(
      messages: initialMessages,
      endToken: olderMessages.isEmpty ? null : 'older-page',
    );
  }

  @override
  Future<String> sendText(String roomId, String body) async {
    textCalls.add(_MessageCall(roomId: roomId, body: body));
    final delayed = sendTextResult;
    if (delayed != null) return delayed.future;
    return r'$local';
  }

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
  Future<String> uploadMedia(
    String roomId,
    String filename,
    String mimeType,
    Uint8List data,
  ) async {
    uploadCalls.add(
      _UploadCall(
        roomId: roomId,
        filename: filename,
        mimeType: mimeType,
        data: data,
      ),
    );
    return r'$media-local';
  }

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
    String body, {
    String? inReplyToEventId,
  }) async {
    threadCalls.add(
      _ThreadCall(
        roomId: roomId,
        threadRootId: threadRootId,
        inReplyToEventId: inReplyToEventId ?? threadRootId,
        body: body,
      ),
    );
    return '\$thread-local-${threadCalls.length}';
  }

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
  Future<void> redact(String roomId, String eventId, {String? reason}) async {
    redactedEventIds.add(eventId);
  }

  @override
  void dispose() {
    _messages.close();
    _reactions.close();
    _receipts.close();
  }
}

class _FakeThreadMatrixService extends _FakeMatrixService
    implements ThreadMatrixService {
  _FakeThreadMatrixService({
    required super.initialMessages,
    this.authoritativeReplyCount = 1,
    this.indexFuture,
    this.remoteReplies,
  });

  final int authoritativeReplyCount;
  final Future<List<ThreadSummary>>? indexFuture;
  final List<MessageEvent>? remoteReplies;

  MessageEvent get _root =>
      initialMessages.firstWhere((message) => message.threadRoot == null);

  List<MessageEvent> get _replies => initialMessages
      .where((message) => message.threadRoot == _root.eventId)
      .toList(growable: false);

  @override
  Future<List<ThreadSummary>> threadIndex({int limitPerRoom = 50}) async {
    final pending = indexFuture;
    if (pending != null) return pending;
    return <ThreadSummary>[
      ThreadSummary(
        roomId: _roomId,
        roomName: 'Room',
        root: _root,
        latestReply: _replies.lastOrNull,
        replyCount: authoritativeReplyCount,
        unreadCount: 0,
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
  }) async =>
      PaginatedThreadMessages(root: _root, messages: remoteReplies ?? _replies);

  @override
  Future<void> sendThreadReadReceipt(
    String roomId,
    String threadRootEventId,
    String eventId,
  ) async {}
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

class _UploadCall {
  const _UploadCall({
    required this.roomId,
    required this.filename,
    required this.mimeType,
    required this.data,
  });

  final String roomId;
  final String filename;
  final String mimeType;
  final Uint8List data;
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
    required this.inReplyToEventId,
    required this.body,
  });

  final String roomId;
  final String threadRootId;
  final String inReplyToEventId;
  final String body;

  @override
  bool operator ==(Object other) {
    return other is _ThreadCall &&
        other.roomId == roomId &&
        other.threadRootId == threadRootId &&
        other.inReplyToEventId == inReplyToEventId &&
        other.body == body;
  }

  @override
  int get hashCode => Object.hash(roomId, threadRootId, inReplyToEventId, body);

  @override
  String toString() {
    return '_ThreadCall('
        'roomId: $roomId, '
        'threadRootId: $threadRootId, '
        'inReplyToEventId: $inReplyToEventId, '
        'body: $body'
        ')';
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manymatrix_app/src/chat/message_bubble.dart';
import 'package:manyui/manyui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows reaction counts and read receipt summary', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MWidgetsApp(
          debugShowCheckedModeBanner: false,
          home: MessageBubble(
            message: MessageEvent(
              eventId: 'event-1',
              roomId: '!room:example.org',
              sender: '@alice:example.org',
              body: 'Hello',
              msgtype: 'm.text',
              timestamp: 1700000000000,
            ),
            isMine: true,
            reactions: <ReactionEvent>[
              ReactionEvent(
                eventId: 'reaction-1',
                roomId: '!room:example.org',
                sender: '@bob:example.org',
                relatesToEventId: 'event-1',
                key: 'ok',
                timestamp: 1700000000001,
              ),
              ReactionEvent(
                eventId: 'reaction-2',
                roomId: '!room:example.org',
                sender: '@carol:example.org',
                relatesToEventId: 'event-1',
                key: 'ok',
                timestamp: 1700000000002,
              ),
            ],
            receipts: <ReceiptEvent>[
              ReceiptEvent(
                roomId: '!room:example.org',
                userId: '@bob:example.org',
                eventId: 'event-1',
                receiptType: 'm.read',
                timestamp: 1700000000003,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('ok 2'), findsOneWidget);
    expect(find.text('Read by bob'), findsOneWidget);
  });

  testWidgets('uses formatted message text when present', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MWidgetsApp(
          debugShowCheckedModeBanner: false,
          home: MessageBubble(
            message: MessageEvent(
              eventId: 'event-1',
              roomId: '!room:example.org',
              sender: '@alice:example.org',
              body: 'fallback',
              formattedBody: '<b>Hello &amp; welcome</b><br>Second line',
              msgtype: 'm.text',
              timestamp: 1700000000000,
            ),
            isMine: false,
          ),
        ),
      ),
    );

    expect(find.text('Hello & welcome\nSecond line'), findsOneWidget);
    expect(find.text('fallback'), findsNothing);
  });

  testWidgets('shows reply, thread, and attachment context', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MWidgetsApp(
          debugShowCheckedModeBanner: false,
          home: MessageBubble(
            message: MessageEvent(
              eventId: 'event-1',
              roomId: '!room:example.org',
              sender: '@alice:example.org',
              body: 'photo.png',
              msgtype: 'm.image',
              timestamp: 1700000000000,
              inReplyTo: r'$parent-event-with-a-long-id',
              threadRoot: r'$thread-root-with-a-long-id',
            ),
            isMine: false,
          ),
        ),
      ),
    );

    expect(find.text('Thread reply'), findsOneWidget);
    expect(find.textContaining(r'$parent-event'), findsNothing);
    expect(find.textContaining(r'$thread-root'), findsNothing);
    expect(find.text('Copy reply link'), findsOneWidget);
    expect(find.text('Copy thread link'), findsOneWidget);
    expect(find.text('Image attachment'), findsOneWidget);
    expect(find.text('photo.png'), findsOneWidget);
  });

  testWidgets('uses a friendly sender label and copies Matrix links', (
    tester,
  ) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map<Object?, Object?>;
          copiedText = args['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MWidgetsApp(
          debugShowCheckedModeBanner: false,
          home: MessageBubble(
            message: MessageEvent(
              eventId: r'$event-1',
              roomId: '!room:example.org',
              sender: '@jbabb:cypherstack.com',
              body: 'Hello',
              msgtype: 'm.text',
              timestamp: 1700000000000,
            ),
            isMine: false,
          ),
        ),
      ),
    );

    expect(find.textContaining('jbabb'), findsOneWidget);
    expect(find.textContaining('@jbabb:cypherstack.com'), findsNothing);

    await tester.tap(find.text('Copy link'));
    await tester.pump();

    expect(copiedText, 'https://matrix.to/#/!room%3Aexample.org/%24event-1');
  });

  testWidgets('shows thread navigation separately from thread reply', (
    tester,
  ) async {
    var opens = 0;
    var replies = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MWidgetsApp(
          debugShowCheckedModeBanner: false,
          home: MessageBubble(
            message: MessageEvent(
              eventId: 'event-1',
              roomId: '!room:example.org',
              sender: '@alice:example.org',
              body: 'Root',
              msgtype: 'm.text',
              timestamp: 1700000000000,
            ),
            isMine: false,
            threadReplyCount: 2,
            onOpenThread: () => opens++,
            onThreadReply: () => replies++,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open thread (2)'));
    await tester.tap(find.text('Thread'));

    expect(opens, 1);
    expect(replies, 1);
  });

  testWidgets('marks edited messages', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MWidgetsApp(
          debugShowCheckedModeBanner: false,
          home: MessageBubble(
            message: MessageEvent(
              eventId: 'event-1',
              roomId: '!room:example.org',
              sender: '@alice:example.org',
              body: 'Edited text',
              msgtype: 'm.text',
              timestamp: 1700000000000,
              editedAt: 1700000001000,
            ),
            isMine: true,
          ),
        ),
      ),
    );

    expect(find.text('Edited text'), findsOneWidget);
    expect(find.textContaining('edited'), findsOneWidget);
  });
}

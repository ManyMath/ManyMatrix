import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manymatrix_app/src/chat/message_bubble.dart';
import 'package:manyui/manyui.dart';

void main() {
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
    expect(find.text('Read by @bob:example.org'), findsOneWidget);
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

    expect(find.text(r'Reply to $parent-event-wi...'), findsOneWidget);
    expect(find.text(r'Thread $thread-root-wit...'), findsOneWidget);
    expect(find.text('Image attachment'), findsOneWidget);
    expect(find.text('photo.png'), findsOneWidget);
  });
}

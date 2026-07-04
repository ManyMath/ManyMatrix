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
}

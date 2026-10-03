import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manymatrix_app/src/matrix/bridge_service.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';
import 'package:manymatrix_app/src/matrix/room_timeline.dart';

void main() {
  test('initial load sends a read receipt for the newest message', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message('event-1', timestamp: 1),
        _message('event-2', timestamp: 2),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final subscription = container.listen(
      roomTimelineProvider(_roomId),
      (_, __) {},
    );
    addTearDown(subscription.close);

    final timeline = await container.read(roomTimelineProvider(_roomId).future);
    await Future<void>.delayed(Duration.zero);

    expect(timeline.newestFirst.map((m) => m.eventId), <String>[
      'event-2',
      'event-1',
    ]);
    expect(service.readReceipts, <({String roomId, String eventId})>[
      (roomId: _roomId, eventId: 'event-2'),
    ]);
  });

  test(
    'opening a room receipts the newest main event without clearing threads',
    () async {
      final service = _FakeMatrixService(
        initialMessages: <MessageEvent>[
          _message('main', timestamp: 1),
          _message('thread', timestamp: 2, threadRoot: r'$root'),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final provider = roomTimelineProvider(_roomId);
      final subscription = container.listen(provider, (_, __) {});
      addTearDown(subscription.close);

      await container.read(provider.future);
      await Future<void>.delayed(Duration.zero);

      expect(service.readReceipts, <({String roomId, String eventId})>[
        (roomId: _roomId, eventId: 'main'),
      ]);

      service.emit(_message('new-thread', timestamp: 3, threadRoot: r'$root'));
      await Future<void>.delayed(Duration.zero);
      expect(service.readReceipts, hasLength(1));
    },
  );

  test('live messages send one receipt and older pages do not', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[_message('event-1')],
      olderMessages: <MessageEvent>[_message('older-1')],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    await container.read(provider.future);
    await Future<void>.delayed(Duration.zero);
    expect(service.readReceipts.map((r) => r.eventId), <String>['event-1']);

    service.emit(_message('event-2', timestamp: 2));
    await Future<void>.delayed(Duration.zero);
    expect(service.readReceipts.map((r) => r.eventId), <String>[
      'event-1',
      'event-2',
    ]);

    service.emit(_message('event-2', timestamp: 2));
    await Future<void>.delayed(Duration.zero);
    expect(
      service.readReceipts.where((r) => r.eventId == 'event-2'),
      hasLength(1),
    );

    await container.read(provider.notifier).loadOlder();
    expect(service.readReceipts.map((r) => r.eventId), <String>[
      'event-1',
      'event-2',
    ]);
  });

  test('server echo enriches an attachment local echo', () async {
    final service = _FakeMatrixService(initialMessages: const <MessageEvent>[]);
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    await container.read(provider.future);
    container
        .read(provider.notifier)
        .addLocalEcho(
          MessageEvent(
            eventId: 'media-1',
            roomId: _roomId,
            sender: '@alice:example.org',
            body: 'proof.txt',
            msgtype: 'm.file',
            timestamp: 1,
            filename: 'proof.txt',
            fileSize: 3,
          ),
        );
    service.emit(
      MessageEvent(
        eventId: 'media-1',
        roomId: _roomId,
        sender: '@alice:example.org',
        body: 'proof.txt',
        msgtype: 'm.file',
        timestamp: 2,
        mxcUri: 'mxc://example.org/media',
        filename: 'proof.txt',
        fileSize: 3,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final message = container.read(provider).value!.newestFirst.single;
    expect(message.mxcUri, 'mxc://example.org/media');
    expect(message.timestamp, 2);
  });

  test('receipt failures do not fail timeline loading', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[_message('event-1')],
    )..failReadReceipt = true;
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    final timeline = await container.read(provider.future);
    await Future<void>.delayed(Duration.zero);

    expect(timeline.newestFirst.single.eventId, 'event-1');
    expect(service.readReceipts, isEmpty);
  });

  test('idle room retries a transient main receipt failure', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[_message('event-1')],
      readReceiptOutcomes: <Object?>[StateError('offline once'), null],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    await container.read(provider.future);
    await Future<void>.delayed(const Duration(milliseconds: 350));

    expect(service.readReceiptAttempts, <String>['event-1', 'event-1']);
    expect(service.readReceipts.map((receipt) => receipt.eventId), <String>[
      'event-1',
    ]);
  });

  test('buffers live messages while the initial page is loading', () async {
    final initialPage = Completer<PaginatedMessages>();
    final service = _FakeMatrixService(initialPage: initialPage);
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    final loading = container.read(provider.future);
    await pumpEventQueue();
    service.emit(_message('live', timestamp: 2));
    await pumpEventQueue();
    initialPage.complete(
      PaginatedMessages(
        messages: <MessageEvent>[_message('initial', timestamp: 1)],
        endToken: 'older',
      ),
    );

    final timeline = await loading;
    expect(timeline.newestFirst.map((message) => message.eventId), <String>[
      'live',
      'initial',
    ]);
  });

  test('discards stale pagination after the service changes', () async {
    final olderPage = Completer<PaginatedMessages>();
    final firstService = _FakeMatrixService(
      initialMessages: <MessageEvent>[_message('first')],
      olderPage: olderPage,
    );
    final secondService = _FakeMatrixService(
      initialMessages: <MessageEvent>[_message('second')],
    );
    final container = _switchingContainer(firstService);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    await container.read(provider.future);
    final staleLoad = container.read(provider.notifier).loadOlder();
    await pumpEventQueue();
    container.read(_selectedServiceProvider.notifier).state = secondService;
    await pumpEventQueue();
    await container.read(provider.future);

    olderPage.complete(
      PaginatedMessages(messages: <MessageEvent>[_message('stale-older')]),
    );
    await staleLoad;
    await pumpEventQueue();

    expect(
      container.read(provider).value!.newestFirst.map((m) => m.eventId),
      <String>['second'],
    );
  });

  test('a final nonempty page clears its continuation token', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[_message('newest', timestamp: 3)],
      olderPages: <PaginatedMessages>[
        PaginatedMessages(
          messages: <MessageEvent>[_message('oldest', timestamp: 1)],
        ),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    await container.read(provider.future);
    await container.read(provider.notifier).loadOlder();
    await container.read(provider.notifier).loadOlder();

    final timeline = container.read(provider).value!;
    expect(timeline.newestFirst.map((message) => message.eventId), <String>[
      'newest',
      'oldest',
    ]);
    expect(timeline.endToken, isNull);
    expect(service.requestedFromTokens, <String?>[null, 'older']);
  });

  test(
    'pagination crosses empty and duplicate pages to visible history',
    () async {
      final duplicate = _message('newest', timestamp: 3);
      final service = _FakeMatrixService(
        initialMessages: <MessageEvent>[duplicate],
        olderPages: <PaginatedMessages>[
          PaginatedMessages(messages: const <MessageEvent>[], endToken: 'p2'),
          PaginatedMessages(
            messages: <MessageEvent>[duplicate],
            endToken: 'p3',
          ),
          PaginatedMessages(
            messages: <MessageEvent>[_message('older', timestamp: 1)],
            endToken: 'p4',
          ),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final provider = roomTimelineProvider(_roomId);
      final subscription = container.listen(provider, (_, __) {});
      addTearDown(subscription.close);

      await container.read(provider.future);
      await container.read(provider.notifier).loadOlder();

      final timeline = container.read(provider).value!;
      expect(timeline.newestFirst.map((message) => message.eventId), <String>[
        'newest',
        'older',
      ]);
      expect(timeline.endToken, 'p4');
      expect(service.requestedFromTokens, <String?>[null, 'older', 'p2', 'p3']);
    },
  );

  test('the empty-page hop bound preserves the next token', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[_message('newest')],
      olderPages: List<PaginatedMessages>.generate(
        8,
        (index) => PaginatedMessages(
          messages: const <MessageEvent>[],
          endToken: 'p${index + 1}',
        ),
      ),
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    await container.read(provider.future);
    await container.read(provider.notifier).loadOlder();

    final timeline = container.read(provider).value!;
    expect(timeline.loadingOlder, isFalse);
    expect(timeline.endToken, 'p8');
    expect(service.requestedFromTokens, hasLength(9));
  });

  test('pagination crosses a thread-only page to visible history', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[_message('newest', timestamp: 4)],
      olderPages: <PaginatedMessages>[
        PaginatedMessages(
          messages: <MessageEvent>[
            _message('thread-reply', timestamp: 3, threadRoot: 'thread-root'),
          ],
          endToken: 'p2',
        ),
        PaginatedMessages(
          messages: <MessageEvent>[_message('older-main', timestamp: 1)],
          endToken: 'p3',
        ),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    await container.read(provider.future);
    await container.read(provider.notifier).loadOlder();

    final timeline = container.read(provider).value!;
    expect(timeline.newestFirst.map((message) => message.eventId), <String>[
      'newest',
      'thread-reply',
      'older-main',
    ]);
    expect(timeline.mainNewestFirst.map((message) => message.eventId), <String>[
      'newest',
      'older-main',
    ]);
    expect(timeline.endToken, 'p3');
    expect(service.requestedFromTokens, <String?>[null, 'older', 'p2']);
  });

  test(
    'pagination receipts the first main event after thread-only history',
    () async {
      final service = _FakeMatrixService(
        initialMessages: <MessageEvent>[
          _message('thread-reply', timestamp: 2, threadRoot: 'root'),
        ],
        olderPages: <PaginatedMessages>[
          PaginatedMessages(
            messages: <MessageEvent>[_message('main', timestamp: 1)],
          ),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final provider = roomTimelineProvider(_roomId);
      final subscription = container.listen(provider, (_, __) {});
      addTearDown(subscription.close);

      await container.read(provider.future);
      await pumpEventQueue();
      expect(service.readReceipts, isEmpty);

      await container.read(provider.notifier).loadOlder();
      await pumpEventQueue();

      expect(service.readReceipts.map((receipt) => receipt.eventId), <String>[
        'main',
      ]);
    },
  );

  test('reaction and receipt callbacks attach metadata to messages', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[_message('event-1')],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    await container.read(provider.future);

    service
      ..emitReaction(_reaction('reaction-1', relatesToEventId: 'event-1'))
      ..emitReceipt(_receipt('event-1', userId: '@bob:example.org'));
    await Future<void>.delayed(Duration.zero);

    final timeline = container.read(provider).value!;
    expect(timeline.reactionsFor('event-1').single.key, '+1');
    expect(timeline.receiptsFor('event-1').single.userId, '@bob:example.org');
  });

  test(
    'a service rebuild resets annotation caches before becoming ready',
    () async {
      final firstService = _FakeMatrixService(
        initialMessages: <MessageEvent>[_message('first')],
      );
      final secondPage = Completer<PaginatedMessages>();
      final secondService = _FakeMatrixService(initialPage: secondPage);
      final container = _switchingContainer(firstService);
      addTearDown(container.dispose);
      final provider = roomTimelineProvider(_roomId);
      final subscription = container.listen(provider, (_, __) {});
      addTearDown(subscription.close);

      await container.read(provider.future);
      firstService
        ..emitReaction(_reaction('old-reaction', relatesToEventId: 'first'))
        ..emitReceipt(_receipt('first', userId: '@bob:example.org'));
      await pumpEventQueue();
      expect(
        container.read(provider).value!.reactionsFor('first'),
        hasLength(1),
      );

      container.read(_selectedServiceProvider.notifier).state = secondService;
      await pumpEventQueue();
      secondService
        ..emitReaction(_reaction('new-reaction', relatesToEventId: 'second'))
        ..emitReceipt(_receipt('second', userId: '@carol:example.org'));
      await pumpEventQueue();
      secondPage.complete(
        PaginatedMessages(messages: <MessageEvent>[_message('second')]),
      );
      final timeline = await container.read(provider.future);

      expect(timeline.reactionsFor('first'), isEmpty);
      expect(timeline.receiptsFor('first'), isEmpty);
      expect(timeline.reactionsFor('second').single.eventId, 'new-reaction');
      expect(
        timeline.receiptsFor('second').single.userId,
        '@carol:example.org',
      );
    },
  );

  test(
    'duplicates reactions and moves receipts only within one scope',
    () async {
      final service = _FakeMatrixService(
        initialMessages: <MessageEvent>[
          _message('event-1', timestamp: 1),
          _message('event-2', timestamp: 2),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final provider = roomTimelineProvider(_roomId);
      final subscription = container.listen(provider, (_, __) {});
      addTearDown(subscription.close);

      await container.read(provider.future);

      final reaction = _reaction('reaction-1', relatesToEventId: 'event-1');
      service
        ..emitReaction(reaction)
        ..emitReaction(reaction)
        ..emitReceipt(_receipt('event-1', userId: '@bob:example.org'))
        ..emitReceipt(
          _receipt(
            'event-1',
            userId: '@bob:example.org',
            threadId: r'$thread-1',
          ),
        )
        ..emitReceipt(
          _receipt(
            'event-2',
            userId: '@bob:example.org',
            threadId: r'$thread-2',
          ),
        )
        ..emitReceipt(_receipt('event-2', userId: '@bob:example.org'));
      await Future<void>.delayed(Duration.zero);

      final timeline = container.read(provider).value!;
      expect(timeline.reactionsFor('event-1'), hasLength(1));
      expect(
        timeline.receiptsFor('event-1').map((receipt) => receipt.threadId),
        <String?>[r'$thread-1'],
      );
      expect(
        timeline
            .receiptsFor('event-2')
            .map((receipt) => receipt.threadId)
            .toSet(),
        <String?>{r'$thread-2', 'main'},
      );
    },
  );

  test('initial load folds replacement events into originals', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message('event-1', body: 'Original', timestamp: 1),
        _message(
          'edit-1',
          body: 'Edited',
          timestamp: 2,
          replacesEventId: 'event-1',
        ),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    final timeline = await container.read(provider.future);

    expect(timeline.newestFirst, hasLength(1));
    expect(timeline.newestFirst.single.eventId, 'event-1');
    expect(timeline.newestFirst.single.body, 'Edited');
    expect(timeline.newestFirst.single.editedAt, 2);
  });

  test(
    'initial chronological page orders messages and folds its edit',
    () async {
      final service = _FakeMatrixService(
        initialMessages: <MessageEvent>[
          _message('event-1', body: 'Original', timestamp: 1),
          _message('event-2', timestamp: 2),
          _message(
            'edit-1',
            body: 'Edited',
            timestamp: 3,
            replacesEventId: 'event-1',
          ),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final provider = roomTimelineProvider(_roomId);
      final subscription = container.listen(provider, (_, __) {});
      addTearDown(subscription.close);

      final timeline = await container.read(provider.future);

      expect(timeline.newestFirst.map((message) => message.eventId), <String>[
        'event-2',
        'event-1',
      ]);
      expect(timeline.newestFirst.last.body, 'Edited');
      expect(timeline.newestFirst.last.editedAt, 3);
    },
  );

  test('an edit is retained until pagination loads its original', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(
          'edit-newer',
          body: 'Latest edit',
          timestamp: 4,
          replacesEventId: 'event-1',
        ),
        _message(
          'edit-older',
          body: 'Stale edit',
          timestamp: 3,
          replacesEventId: 'event-1',
        ),
      ],
      olderPages: <PaginatedMessages>[
        PaginatedMessages(
          messages: <MessageEvent>[
            _message('event-1', body: 'Original', timestamp: 1),
            _message('event-2', timestamp: 2),
          ],
        ),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    final initial = await container.read(provider.future);
    expect(initial.newestFirst, isEmpty);

    await container.read(provider.notifier).loadOlder();
    final timeline = container.read(provider).value!;

    expect(timeline.newestFirst.map((message) => message.eventId), <String>[
      'event-2',
      'event-1',
    ]);
    expect(timeline.newestFirst.last.body, 'Latest edit');
    expect(timeline.newestFirst.last.editedAt, 4);
    expect(timeline.endToken, isNull);
  });

  test('a foreign pending edit cannot suppress the owner edit', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message(
          'valid-edit',
          body: 'Owner edit',
          timestamp: 2,
          replacesEventId: 'event-1',
        ),
        _message(
          'foreign-edit',
          body: 'Foreign edit',
          sender: '@mallory:example.org',
          timestamp: 3,
          replacesEventId: 'event-1',
        ),
      ],
      olderPages: <PaginatedMessages>[
        PaginatedMessages(
          messages: <MessageEvent>[
            _message('event-1', body: 'Original', timestamp: 1),
          ],
        ),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    await container.read(provider.future);
    await container.read(provider.notifier).loadOlder();

    final message = container.read(provider).value!.newestFirst.single;
    expect(message.body, 'Owner edit');
    expect(message.editedAt, 2);
  });

  test('thread replies are projected out of the main timeline', () {
    final timeline = RoomTimeline(
      newestFirst: <MessageEvent>[
        _message('reply-2', timestamp: 3, threadRoot: 'root'),
        _message('reply-1', timestamp: 2, threadRoot: 'root'),
        _message('root', timestamp: 1),
        _message('standalone', timestamp: 0),
      ],
    );

    expect(timeline.mainNewestFirst.map((m) => m.eventId), <String>[
      'root',
      'standalone',
    ]);
    expect(timeline.threadReplyCount('root'), 2);
    expect(
      timeline.threadMessagesNewestFirst('root').map((m) => m.eventId),
      <String>['reply-2', 'reply-1', 'root'],
    );
  });

  test('live replacement events update the original message', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message('event-1', body: 'Original', timestamp: 1),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    await container.read(provider.future);
    await Future<void>.delayed(Duration.zero);
    service.emit(
      _message(
        'edit-1',
        body: 'Edited',
        timestamp: 2,
        replacesEventId: 'event-1',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final timeline = container.read(provider).value!;
    expect(timeline.newestFirst, hasLength(1));
    expect(timeline.newestFirst.single.eventId, 'event-1');
    expect(timeline.newestFirst.single.body, 'Edited');
    expect(timeline.newestFirst.single.editedAt, 2);
    expect(service.readReceipts.map((r) => r.eventId), <String>['event-1']);
  });

  test('a caption edit keeps the attachment downloadable', () async {
    MessageEvent image(String eventId, String body, int timestamp) =>
        MessageEvent(
          eventId: eventId,
          roomId: _roomId,
          sender: '@alice:example.org',
          body: body,
          msgtype: 'm.image',
          timestamp: timestamp,
          replacesEventId: eventId == 'media-1' ? null : 'media-1',
          mxcUri: 'mxc://example.org/cat',
          mediaSource: const <String, dynamic>{'url': 'mxc://example.org/cat'},
          filename: 'cat.png',
          fileSize: 42,
        );
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        image('media-1', 'cat.png', 1),
        image('edit-1', 'A cat', 2),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    void expectAttachment(MessageEvent message, String body) {
      expect(message.eventId, 'media-1');
      expect(message.body, body);
      expect(message.msgtype, 'm.image');
      expect(message.mxcUri, 'mxc://example.org/cat');
      expect(message.mediaSource, <String, dynamic>{
        'url': 'mxc://example.org/cat',
      });
      expect(message.filename, 'cat.png');
      expect(message.fileSize, 42);
    }

    final initial = await container.read(provider.future);
    expectAttachment(initial.newestFirst.single, 'A cat');

    service.emit(image('edit-2', 'A sleepy cat', 3));
    await Future<void>.delayed(Duration.zero);

    final message = container.read(provider).value!.newestFirst.single;
    expectAttachment(message, 'A sleepy cat');
    expect(message.editedAt, 3);
  });

  test('thread edits and deletes never advance the main receipt', () async {
    final service = _FakeMatrixService(
      initialMessages: <MessageEvent>[
        _message('root', timestamp: 1),
        _message('reply', timestamp: 2, threadRoot: 'root'),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = roomTimelineProvider(_roomId);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);
    await container.read(provider.future);
    await pumpEventQueue();

    service.emit(
      _message(
        'edit-reply',
        body: 'Edited reply',
        timestamp: 3,
        replacesEventId: 'reply',
      ),
    );
    service.emit(
      MessageEvent(
        eventId: 'delete-reply',
        roomId: _roomId,
        sender: '@bob:example.org',
        body: '',
        msgtype: 'm.redaction',
        timestamp: 4,
        redactsEventId: 'reply',
      ),
    );
    await pumpEventQueue();

    final timeline = container.read(provider).value!;
    expect(timeline.threadReplyCount('root'), 0);
    expect(service.readReceipts.map((receipt) => receipt.eventId), <String>[
      'root',
    ]);
  });
}

const _roomId = '!room:example.org';

ProviderContainer _container(_FakeMatrixService service) {
  return ProviderContainer(
    overrides: <Override>[matrixServiceProvider.overrideWithValue(service)],
  );
}

final _selectedServiceProvider = StateProvider<MatrixService?>((ref) => null);

ProviderContainer _switchingContainer(MatrixService initialService) {
  return ProviderContainer(
    overrides: <Override>[
      _selectedServiceProvider.overrideWith((ref) => initialService),
      matrixServiceProvider.overrideWith(
        (ref) => ref.watch(_selectedServiceProvider)!,
      ),
    ],
  );
}

MessageEvent _message(
  String eventId, {
  String? body,
  String sender = '@alice:example.org',
  int timestamp = 0,
  String? replacesEventId,
  String? threadRoot,
}) {
  return MessageEvent(
    eventId: eventId,
    roomId: _roomId,
    sender: sender,
    body: body ?? eventId,
    msgtype: 'm.text',
    timestamp: timestamp,
    replacesEventId: replacesEventId,
    threadRoot: threadRoot,
  );
}

ReactionEvent _reaction(String eventId, {required String relatesToEventId}) {
  return ReactionEvent(
    eventId: eventId,
    roomId: _roomId,
    sender: '@bob:example.org',
    relatesToEventId: relatesToEventId,
    key: '+1',
    timestamp: 3,
  );
}

ReceiptEvent _receipt(
  String eventId, {
  required String userId,
  String? threadId = 'main',
}) {
  return ReceiptEvent(
    roomId: _roomId,
    userId: userId,
    eventId: eventId,
    receiptType: 'm.read',
    threadId: threadId,
    timestamp: 4,
  );
}

class _FakeMatrixService implements MatrixService {
  _FakeMatrixService({
    this.initialMessages = const <MessageEvent>[],
    this.olderMessages = const <MessageEvent>[],
    this.olderPages = const <PaginatedMessages>[],
    this.initialPage,
    this.olderPage,
    this.readReceiptOutcomes = const <Object?>[],
  });

  final List<MessageEvent> initialMessages;
  final List<MessageEvent> olderMessages;
  final List<PaginatedMessages> olderPages;
  final Completer<PaginatedMessages>? initialPage;
  final Completer<PaginatedMessages>? olderPage;
  final List<Object?> readReceiptOutcomes;
  final List<String?> requestedFromTokens = <String?>[];
  int _olderPageIndex = 0;
  final List<({String roomId, String eventId})> readReceipts =
      <({String roomId, String eventId})>[];
  bool failReadReceipt = false;
  int _readReceiptAttempt = 0;
  final List<String> readReceiptAttempts = <String>[];

  final _messages = StreamController<MessageEvent>.broadcast();
  final _reactions = StreamController<ReactionEvent>.broadcast();
  final _receipts = StreamController<ReceiptEvent>.broadcast();

  void emit(MessageEvent event) {
    _messages.add(event);
  }

  void emitReaction(ReactionEvent event) {
    _reactions.add(event);
  }

  void emitReceipt(ReceiptEvent event) {
    _receipts.add(event);
  }

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
    requestedFromTokens.add(fromToken);
    if (fromToken == null && initialPage != null) return initialPage!.future;
    if (fromToken != null && olderPage != null) return olderPage!.future;
    if (fromToken != null && _olderPageIndex < olderPages.length) {
      return olderPages[_olderPageIndex++];
    }
    return PaginatedMessages(
      messages: fromToken == null ? initialMessages : olderMessages,
      endToken: fromToken == null ? 'older' : null,
    );
  }

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
  Future<void> sendReadReceipt(String roomId, String eventId) async {
    readReceiptAttempts.add(eventId);
    final outcome = _readReceiptAttempt < readReceiptOutcomes.length
        ? readReceiptOutcomes[_readReceiptAttempt]
        : null;
    _readReceiptAttempt += 1;
    if (outcome != null) throw outcome;
    if (failReadReceipt) throw Exception('M_FORBIDDEN');
    readReceipts.add((roomId: roomId, eventId: eventId));
  }

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
    _reactions.close();
    _receipts.close();
  }
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manymatrix_app/src/matrix/auth.dart';
import 'package:manymatrix_app/src/matrix/bridge_service.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';
import 'package:manymatrix_app/src/matrix/thread_timeline.dart';

const _key = ThreadKey(roomId: '!room:example.org', rootEventId: r'$root');
final _selectedThreadServiceProvider = StateProvider<_ThreadService?>(
  (ref) => null,
);

class _AuthenticatedController extends AuthController {
  @override
  AuthState build() => const AuthAuthenticated('@alice:example.org');
}

void main() {
  test(
    'live replies arriving during initial load remain newest-first',
    () async {
      final initialPage = Completer<PaginatedThreadMessages>();
      final service = _ThreadService(initialPage: initialPage.future);
      final container = _container(service);
      addTearDown(container.dispose);

      final indexSubscription = container.listen(
        threadIndexProvider,
        (_, __) {},
      );
      addTearDown(indexSubscription.close);
      await container.read(threadIndexProvider.future);

      final provider = threadTimelineProvider(_key);
      final subscription = container.listen(provider, (_, __) {});
      addTearDown(subscription.close);
      await pumpEventQueue();

      service.emit(_reply(r'$a', timestamp: 200));
      service.emit(_reply(r'$z', timestamp: 200));
      await pumpEventQueue();
      initialPage.complete(
        PaginatedThreadMessages(
          root: _root(),
          messages: <MessageEvent>[_reply(r'$old', timestamp: 100)],
        ),
      );

      await container.read(provider.future);
      await pumpEventQueue();
      final timeline = container.read(provider).value!;
      expect(timeline.newestFirst.map((message) => message.eventId), <String>[
        r'$z',
        r'$a',
        r'$old',
      ]);
      expect(service.receipts.last, r'$z');
    },
  );

  test(
    'failed threaded receipt refreshes authoritative unread state',
    () async {
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(
            root: _root(),
            messages: <MessageEvent>[_reply(r'$reply', timestamp: 200)],
          ),
        ),
        receiptError: StateError('offline'),
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final indexSubscription = container.listen(
        threadIndexProvider,
        (_, __) {},
      );
      addTearDown(indexSubscription.close);
      await container.read(threadIndexProvider.future);
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 2);

      final provider = threadTimelineProvider(_key);
      final subscription = container.listen(provider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(provider.future);
      await pumpEventQueue(times: 10);

      expect(service.threadIndexCalls, greaterThanOrEqualTo(2));
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 2);
    },
  );

  test(
    'recursive relations apply edits without rendering edit events',
    () async {
      final original = _reply(r'$reply', timestamp: 100);
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(
            root: _root(),
            messages: <MessageEvent>[
              original,
              MessageEvent(
                eventId: r'$edit',
                roomId: _key.roomId,
                sender: original.sender,
                body: 'Edited reply',
                msgtype: 'm.text',
                timestamp: 200,
                replacesEventId: original.eventId,
              ),
            ],
          ),
        ),
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final provider = threadTimelineProvider(_key);
      final subscription = container.listen(provider, (_, __) {});
      addTearDown(subscription.close);

      final timeline = await container.read(provider.future);

      expect(timeline.newestFirst, hasLength(1));
      expect(timeline.newestFirst.single.eventId, original.eventId);
      expect(timeline.newestFirst.single.body, 'Edited reply');
      expect(timeline.newestFirst.single.editedAt, 200);
    },
  );

  test(
    'thread index replaces its event listener when service changes',
    () async {
      final first = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
      );
      final second = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
      );
      final container = ProviderContainer(
        overrides: <Override>[
          _selectedThreadServiceProvider.overrideWith((ref) => first),
          matrixServiceProvider.overrideWith(
            (ref) => ref.watch(_selectedThreadServiceProvider)!,
          ),
          authControllerProvider.overrideWith(_AuthenticatedController.new),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);

      await container.read(threadIndexProvider.future);
      expect(first.hasMessageListener, isTrue);
      container.read(threadIndexProvider.notifier).commitRead(_key);
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);

      container.read(_selectedThreadServiceProvider.notifier).state = second;
      await container.read(threadIndexProvider.future);
      await pumpEventQueue();

      expect(first.hasMessageListener, isFalse);
      expect(second.hasMessageListener, isTrue);
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 2);
    },
  );

  test('thread index coalesces overlapping loads', () async {
    final pending = Completer<List<ThreadSummary>>();
    final service = _ThreadService(
      initialPage: Future.value(
        PaginatedThreadMessages(root: _root(), messages: const []),
      ),
      indexResponses: <Future<List<ThreadSummary>>>[pending.future],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final subscription = container.listen(threadIndexProvider, (_, __) {});
    addTearDown(subscription.close);
    container.read(threadIndexProvider);
    await pumpEventQueue();

    final first = container.read(threadIndexProvider.notifier).refresh();
    final second = container.read(threadIndexProvider.notifier).refresh();
    expect(service.threadIndexCalls, 1);
    pending.complete(_summaries(2));
    await Future.wait(<Future<void>>[first, second]);

    expect(container.read(threadIndexProvider).value!.single.unreadCount, 2);
  });

  test(
    'own reply echo preserves a committed-read stale-response guard',
    () async {
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(_summaries(2)),
          Future.value(_summaries(2)),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);
      final ownReply = _reply(
        r'$own',
        timestamp: 300,
        sender: '@alice:example.org',
      );

      container.read(threadIndexProvider.notifier)
        ..commitRead(_key)
        ..rememberReply(ownReply);
      service.emit(ownReply);
      await pumpEventQueue();
      await container.read(threadIndexProvider.notifier).refresh();

      expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);
    },
  );

  test(
    'failed live refresh preserves directly observed unread activity',
    () async {
      final failedRefresh = Completer<List<ThreadSummary>>();
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(_summaries(0)),
          failedRefresh.future,
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);

      service.emit(_reply(r'$foreign', timestamp: 300));
      await pumpEventQueue();
      final refresh = container.read(threadIndexProvider.notifier).refresh();
      await pumpEventQueue();
      failedRefresh.completeError(StateError('offline'));
      await refresh;

      expect(container.read(threadIndexProvider).value!.single.unreadCount, 1);
      expect(container.read(threadIndexStaleProvider), isTrue);

      service.emit(_reply(r'$second-foreign', timestamp: 400));
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 2);
      expect(container.read(threadIndexStaleProvider), isTrue);
    },
  );

  test(
    'observed replies survive false zero, dedupe, and receipt races',
    () async {
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(_summaries(0)),
          Future.value(_summaries(0)),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);
      final first = _reply(r'$observed', timestamp: 300);

      service
        ..emit(first)
        ..emit(first);
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 1);
      expect(container.read(threadIndexProvider).value!.single.replyCount, 2);

      await container.read(threadIndexProvider.notifier).refresh();
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 1);

      final newer = _reply(r'$newer', timestamp: first.timestamp);
      service.emit(newer);
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 2);

      service.emitReceipt(_receipt(first.eventId, timestamp: 350));
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 1);

      service.emitReceipt(_receipt(first.eventId, timestamp: 450));
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 1);

      service.emitReceipt(_receipt(newer.eventId, timestamp: 450));
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);
    },
  );

  test(
    'hidden thread defers its receipt until the panel is visible again',
    () async {
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(_summaries(0)),
          Future.value(_summaries(0)),
          Future.value(_summaries(0)),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final indexSubscription = container.listen(
        threadIndexProvider,
        (_, __) {},
      );
      addTearDown(indexSubscription.close);
      await container.read(threadIndexProvider.future);
      final provider = threadTimelineProvider(_key);
      final timelineSubscription = container.listen(provider, (_, __) {});
      addTearDown(timelineSubscription.close);
      await container.read(provider.future);
      await pumpEventQueue(times: 10);
      service.receipts.clear();

      container.read(threadVisibilityProvider(_key).notifier).state = false;
      service.emit(_reply(r'$hidden-reply', timestamp: 300));
      await pumpEventQueue(times: 10);

      expect(service.receipts, isEmpty);
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 1);

      container.read(threadVisibilityProvider(_key).notifier).state = true;
      await pumpEventQueue(times: 10);

      expect(service.receipts, <String>[r'$hidden-reply']);
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);
    },
  );

  test(
    'receipt before its reply advances only that thread activity frontier',
    () async {
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(_summaries(0)),
          Future.value(const <ThreadSummary>[]),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emitReceipt(_receipt(r'$receipt-target', timestamp: 250));
      await pumpEventQueue();
      await container.read(threadIndexProvider.notifier).refresh();
      expect(container.read(threadIndexProvider).value, isEmpty);

      service.emit(_reply(r'$receipt-target', timestamp: 300));
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);

      service.emit(_reply(r'$newer', timestamp: 400));
      service.emit(_reply(r'$older', timestamp: 100));
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 1);

      service.emitReceipt(_receipt(r'$older', timestamp: 500));
      await pumpEventQueue();
      final summary = container.read(threadIndexProvider).value!.single;
      expect(summary.latestReply?.eventId, r'$newer');
      expect(summary.unreadCount, 1);
    },
  );

  test(
    'equal-timestamp receipt reads exact target but not distinct live reply',
    () async {
      final target = _reply(r'$zzz-target', timestamp: 300);
      final distinct = _reply(r'$aaa-distinct', timestamp: 300);
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(_summaries(0, latestReply: target)),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emitReceipt(_receipt(target.eventId, timestamp: 350));
      service.emit(target);
      service.emit(distinct);
      await pumpEventQueue();

      var summary = container.read(threadIndexProvider).value!.single;
      expect(summary.latestReply?.eventId, distinct.eventId);
      expect(summary.replyCount, 2);
      expect(summary.unreadCount, 1);

      service.emitReceipt(_receipt(target.eventId, timestamp: 450));
      await pumpEventQueue();
      summary = container.read(threadIndexProvider).value!.single;
      expect(summary.unreadCount, 1);
    },
  );

  test(
    'equal-timestamp own reply reads the earlier server snapshot activity',
    () async {
      final baseline = _reply(r'$server-baseline', timestamp: 300);
      final ownReply = _reply(
        r'$own-same-time',
        timestamp: 300,
        sender: '@alice:example.org',
      );
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(
            _summaries(
              1,
              latestReply: baseline,
              currentUserParticipated: false,
            ),
          ),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emit(ownReply);
      await pumpEventQueue();

      final summary = container.read(threadIndexProvider).value!.single;
      expect(summary.latestReply?.eventId, ownReply.eventId);
      expect(summary.replyCount, 2);
      expect(summary.unreadCount, 0);
      expect(summary.currentUserParticipated, isTrue);
    },
  );

  test(
    'equal-timestamp receipt through live reply reads the server baseline',
    () async {
      final baseline = _reply(r'$server-baseline', timestamp: 300);
      final liveReply = _reply(r'$live-same-time', timestamp: 300);
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(_summaries(1, latestReply: baseline)),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emit(liveReply);
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 1);

      service.emitReceipt(_receipt(liveReply.eventId, timestamp: 400));
      await pumpEventQueue();

      final summary = container.read(threadIndexProvider).value!.single;
      expect(summary.latestReply?.eventId, liveReply.eventId);
      expect(summary.replyCount, 2);
      expect(summary.unreadCount, 0);
    },
  );

  test(
    'redaction before or after a reply prevents phantom unread activity',
    () async {
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(_summaries(0)),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emit(_redaction(r'$redact-first', r'$redacted-first', 250));
      service.emit(_reply(r'$redacted-first', timestamp: 300));
      await pumpEventQueue();
      var summary = container.read(threadIndexProvider).value!.single;
      expect(summary.replyCount, 1);
      expect(summary.unreadCount, 0);

      service.emit(_reply(r'$redacted-later', timestamp: 400));
      await pumpEventQueue();
      summary = container.read(threadIndexProvider).value!.single;
      expect(summary.replyCount, 2);
      expect(summary.unreadCount, 1);

      service.emit(_redaction(r'$redact-later', r'$redacted-later', 450));
      await pumpEventQueue();
      summary = container.read(threadIndexProvider).value!.single;
      expect(summary.latestReply?.eventId, r'$reply');
      expect(summary.replyCount, 1);
      expect(summary.unreadCount, 0);
    },
  );

  test(
    'server false zero cannot erase a foreign reply observed locally',
    () async {
      final observed = _reply(r'$foreign', timestamp: 300);
      final caughtUp = _summaries(0, latestReply: observed, replyCount: 2);
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(_summaries(0)),
          Future.value(caughtUp),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emit(observed);
      await pumpEventQueue();
      await container.read(threadIndexProvider.notifier).refresh();

      final summary = container.read(threadIndexProvider).value!.single;
      expect(summary.replyCount, 2);
      expect(summary.unreadCount, 1);
    },
  );

  test(
    'equal-timestamp local delta is acknowledged by server count growth',
    () async {
      final serverLatest = _reply(r'$server-latest', timestamp: 300);
      final observed = _reply(r'$same-time-observed', timestamp: 300);
      final initial = _summaries(0, latestReply: serverLatest, replyCount: 1);
      final caughtUp = _summaries(0, latestReply: serverLatest, replyCount: 2);
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(initial),
          Future.value(caughtUp),
          Future.value(caughtUp),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emit(observed);
      await pumpEventQueue();
      var summary = container.read(threadIndexProvider).value!.single;
      expect(summary.replyCount, 2);
      expect(summary.latestReply?.eventId, observed.eventId);

      await container.read(threadIndexProvider.notifier).refresh();
      await container.read(threadIndexProvider.notifier).refresh();

      summary = container.read(threadIndexProvider).value!.single;
      expect(summary.replyCount, 2);
      expect(summary.unreadCount, 1);
    },
  );

  test(
    'redacted non-latest indexed reply is removed from baseline estimates',
    () async {
      final serverLatest = _reply(r'$server-latest', timestamp: 500);
      final initial = _summaries(1, latestReply: serverLatest, replyCount: 3);
      final caughtUp = _summaries(0, latestReply: serverLatest, replyCount: 2);
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(initial),
          Future.value(const <ThreadSummary>[]),
          Future.value(caughtUp),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emit(_reply(r'$indexed-non-latest', timestamp: 100));
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value!.single.replyCount, 3);

      service.emit(
        _redaction(r'$delete-non-latest', r'$indexed-non-latest', 600),
      );
      await pumpEventQueue();
      var summary = container.read(threadIndexProvider).value!.single;
      expect(summary.latestReply?.eventId, serverLatest.eventId);
      expect(summary.replyCount, 2);
      expect(summary.unreadCount, 0);

      await container.read(threadIndexProvider.notifier).refresh();
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value, isEmpty);
      expect(container.read(threadIndexStaleProvider), isFalse);

      await container.read(threadIndexProvider.notifier).refresh();
      summary = container.read(threadIndexProvider).value!.single;
      expect(summary.replyCount, 2);
      expect(summary.unreadCount, 0);
    },
  );

  test(
    'redaction acknowledgment survives concurrent server-count growth',
    () async {
      final oldLatest = _reply(r'$old-server-latest', timestamp: 500);
      final added = _reply(r'$concurrent-addition', timestamp: 600);
      final initial = _summaries(0, latestReply: oldLatest, replyCount: 3);
      final refreshed = _summaries(0, latestReply: added, replyCount: 3);
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(initial),
          Future.value(refreshed),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emit(_reply(r'$redacted-indexed', timestamp: 100));
      service.emit(_redaction(r'$delete-indexed', r'$redacted-indexed', 550));
      service.emit(added);
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value!.single.replyCount, 3);

      await container.read(threadIndexProvider.notifier).refresh();
      final summary = container.read(threadIndexProvider).value!.single;
      expect(summary.latestReply?.eventId, added.eventId);
      expect(summary.replyCount, 3);
      expect(summary.unreadCount, 1);
    },
  );

  test(
    'redaction acknowledgment accepts an unobserved concurrent server latest',
    () async {
      final oldLatest = _reply(r'$old-server-latest', timestamp: 500);
      final added = _reply(r'$server-first-addition', timestamp: 600);
      final initial = _summaries(0, latestReply: oldLatest, replyCount: 3);
      final refreshed = _summaries(1, latestReply: added, replyCount: 3);
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(initial),
          Future.value(refreshed),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emit(_reply(r'$redacted-indexed', timestamp: 100));
      service.emit(_redaction(r'$delete-indexed', r'$redacted-indexed', 550));
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value!.single.replyCount, 2);

      await container.read(threadIndexProvider.notifier).refresh();
      var summary = container.read(threadIndexProvider).value!.single;
      expect(summary.latestReply?.eventId, added.eventId);
      expect(summary.replyCount, 3);
      expect(summary.unreadCount, 1);
      expect(container.read(threadIndexStaleProvider), isFalse);

      service.emit(added);
      await pumpEventQueue();
      summary = container.read(threadIndexProvider).value!.single;
      expect(summary.replyCount, 3);
      expect(summary.unreadCount, 1);
      expect(container.read(threadIndexStaleProvider), isFalse);
    },
  );

  test(
    'indexed latest reply is not double-counted or marked participated',
    () async {
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(_summaries(0, currentUserParticipated: false)),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emit(_reply(r'$reply', timestamp: 200));
      await pumpEventQueue();

      final summary = container.read(threadIndexProvider).value!.single;
      expect(summary.replyCount, 1);
      expect(summary.unreadCount, 1);
      expect(summary.currentUserParticipated, isFalse);
    },
  );

  test('failed first-activity refresh retains a provisional thread', () async {
    final failedRefresh = Completer<List<ThreadSummary>>();
    final service = _ThreadService(
      initialPage: Future.value(
        PaginatedThreadMessages(root: _root(), messages: const []),
      ),
      indexResponses: <Future<List<ThreadSummary>>>[
        Future.value(const <ThreadSummary>[]),
        failedRefresh.future,
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final subscription = container.listen(threadIndexProvider, (_, __) {});
    addTearDown(subscription.close);
    await container.read(threadIndexProvider.future);
    expect(container.read(threadIndexProvider).value, isEmpty);
    expect(container.read(threadIndexStaleProvider), isFalse);

    service.emit(_reply(r'$first', timestamp: 300));
    await pumpEventQueue();
    final refresh = container.read(threadIndexProvider.notifier).refresh();
    await pumpEventQueue();
    failedRefresh.completeError(StateError('offline'));
    await refresh;

    final provisional = container.read(threadIndexProvider).value!;
    expect(provisional, hasLength(1));
    expect(provisional.single.root.eventId, _key.rootEventId);
    expect(provisional.single.latestReply?.eventId, r'$first');
    expect(provisional.single.unreadCount, 1);
    expect(container.read(threadIndexStaleProvider), isTrue);
  });

  test(
    'successful index omission retains observed thread as incomplete',
    () async {
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(const <ThreadSummary>[]),
          Future.value(const <ThreadSummary>[]),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emit(_reply(r'$first', timestamp: 300));
      await pumpEventQueue();
      await container.read(threadIndexProvider.notifier).refresh();
      await pumpEventQueue();

      final threads = container.read(threadIndexProvider).value!;
      expect(threads, hasLength(1));
      expect(threads.single.root.eventId, _key.rootEventId);
      expect(threads.single.latestReply?.eventId, r'$first');
      expect(threads.single.replyCount, 1);
      expect(threads.single.unreadCount, 1);
      expect(container.read(threadIndexStaleProvider), isTrue);
    },
  );

  test(
    'delayed indexed reply cannot regress latest, count, or thread order',
    () async {
      final newest = _reply(r'$newest-indexed', timestamp: 500);
      final primary = ThreadSummary(
        roomId: _key.roomId,
        roomName: 'Primary',
        root: _root(),
        latestReply: newest,
        replyCount: 3,
        unreadCount: 0,
        currentUserParticipated: false,
      );
      final secondaryRoot = MessageEvent(
        eventId: r'$secondary-root',
        roomId: '!secondary:example.org',
        sender: '@carol:example.org',
        body: 'Secondary root',
        msgtype: 'm.text',
        timestamp: 10,
      );
      final secondary = ThreadSummary(
        roomId: secondaryRoot.roomId,
        roomName: 'Secondary',
        root: secondaryRoot,
        latestReply: MessageEvent(
          eventId: r'$secondary-reply',
          roomId: secondaryRoot.roomId,
          sender: '@dana:example.org',
          body: 'Secondary reply',
          msgtype: 'm.text',
          timestamp: 400,
          threadRoot: secondaryRoot.eventId,
        ),
        replyCount: 1,
        unreadCount: 0,
        currentUserParticipated: false,
      );
      final snapshots = <ThreadSummary>[primary, secondary];
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(snapshots),
          Future.value(snapshots),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emit(_reply(r'$delayed-indexed', timestamp: 100));
      await pumpEventQueue();
      await container.read(threadIndexProvider.notifier).refresh();

      final threads = container.read(threadIndexProvider).value!;
      expect(threads.map((thread) => thread.root.eventId), <String>[
        _key.rootEventId,
        secondaryRoot.eventId,
      ]);
      expect(threads.first.latestReply?.eventId, newest.eventId);
      expect(threads.first.replyCount, 3);
      expect(threads.first.unreadCount, 0);
    },
  );

  test(
    'same-user reply from another device participates and advances read state',
    () async {
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(_summaries(0, currentUserParticipated: false)),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emit(
        _reply(
          r'$own-other-device',
          timestamp: 300,
          sender: '@alice:example.org',
        ),
      );
      service.emit(_reply(r'$delayed-foreign', timestamp: 250));
      await pumpEventQueue();

      var summary = container.read(threadIndexProvider).value!.single;
      expect(summary.latestReply?.eventId, r'$own-other-device');
      expect(summary.replyCount, 3);
      expect(summary.unreadCount, 0);
      expect(summary.currentUserParticipated, isTrue);

      service.emit(_reply(r'$new-foreign', timestamp: 400));
      await pumpEventQueue();
      summary = container.read(threadIndexProvider).value!.single;
      expect(summary.unreadCount, 1);
    },
  );

  test('failed refresh preserves a locally proven read zero', () async {
    final failedRefresh = Completer<List<ThreadSummary>>();
    final service = _ThreadService(
      initialPage: Future.value(
        PaginatedThreadMessages(root: _root(), messages: const []),
      ),
      indexResponses: <Future<List<ThreadSummary>>>[
        Future.value(_summaries(2, currentUserParticipated: false)),
        failedRefresh.future,
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final subscription = container.listen(threadIndexProvider, (_, __) {});
    addTearDown(subscription.close);
    await container.read(threadIndexProvider.future);

    service.emit(
      _reply(
        r'$own-other-device',
        timestamp: 300,
        sender: '@alice:example.org',
      ),
    );
    await pumpEventQueue();
    expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);

    final refresh = container.read(threadIndexProvider.notifier).refresh();
    await pumpEventQueue();
    failedRefresh.completeError(StateError('offline'));
    await refresh;

    expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);
    expect(container.read(threadIndexStaleProvider), isTrue);
  });

  test(
    'caught-up read activity does not retain a later omitted thread',
    () async {
      final observed = _reply(r'$observed', timestamp: 300);
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(_summaries(0)),
          Future.value(_summaries(0, latestReply: observed, replyCount: 2)),
          Future.value(const <ThreadSummary>[]),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      service.emit(observed);
      await pumpEventQueue();
      await container.read(threadIndexProvider.notifier).refresh();
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 1);

      service.emitReceipt(_receipt(observed.eventId, timestamp: 400));
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);

      await container.read(threadIndexProvider.notifier).refresh();
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value, isEmpty);
      expect(container.read(threadIndexStaleProvider), isFalse);
    },
  );

  test('redacting sole provisional reply removes its placeholder', () async {
    final service = _ThreadService(
      initialPage: Future.value(
        PaginatedThreadMessages(root: _root(), messages: const []),
      ),
      indexResponses: <Future<List<ThreadSummary>>>[
        Future.value(const <ThreadSummary>[]),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final subscription = container.listen(threadIndexProvider, (_, __) {});
    addTearDown(subscription.close);
    await container.read(threadIndexProvider.future);

    service.emit(_reply(r'$provisional', timestamp: 300));
    await pumpEventQueue();
    expect(container.read(threadIndexProvider).value, hasLength(1));
    expect(container.read(threadIndexStaleProvider), isTrue);

    service.emit(_redaction(r'$delete-provisional', r'$provisional', 400));
    await pumpEventQueue();
    expect(container.read(threadIndexProvider).value, isEmpty);
    expect(container.read(threadIndexStaleProvider), isFalse);
  });

  test(
    'observed unread floor is cleared when Matrix service changes',
    () async {
      final first = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(_summaries(0)),
        ],
      );
      final second = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(root: _root(), messages: const []),
        ),
        indexResponses: <Future<List<ThreadSummary>>>[
          Future.value(_summaries(0)),
        ],
      );
      final container = ProviderContainer(
        overrides: <Override>[
          _selectedThreadServiceProvider.overrideWith((ref) => first),
          matrixServiceProvider.overrideWith(
            (ref) => ref.watch(_selectedThreadServiceProvider)!,
          ),
          authControllerProvider.overrideWith(_AuthenticatedController.new),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(threadIndexProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(threadIndexProvider.future);

      first.emit(_reply(r'$foreign', timestamp: 300));
      await pumpEventQueue();
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 1);

      container.read(_selectedThreadServiceProvider.notifier).state = second;
      await container.read(threadIndexProvider.future);

      expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);
    },
  );

  test('same-event receipt retries and commits only after success', () async {
    final reply = _reply(r'$reply', timestamp: 200);
    final service = _ThreadService(
      initialPage: Future.value(
        PaginatedThreadMessages(root: _root(), messages: <MessageEvent>[reply]),
      ),
      receiptOutcomes: <Object?>[
        StateError('offline once'),
        StateError('offline twice'),
        null,
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final indexSubscription = container.listen(threadIndexProvider, (_, __) {});
    addTearDown(indexSubscription.close);
    await container.read(threadIndexProvider.future);
    final provider = threadTimelineProvider(_key);
    final timelineSubscription = container.listen(provider, (_, __) {});
    addTearDown(timelineSubscription.close);

    await container.read(provider.future);
    await pumpEventQueue(times: 10);
    expect(container.read(threadIndexProvider).value!.single.unreadCount, 2);

    service.emit(reply);
    await pumpEventQueue(times: 10);
    expect(container.read(threadIndexProvider).value!.single.unreadCount, 2);

    service.emit(reply);
    await pumpEventQueue(times: 10);
    expect(service.receipts, <String>[r'$reply', r'$reply', r'$reply']);
    expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);
  });

  test(
    'idle thread retries a transient receipt failure automatically',
    () async {
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(
            root: _root(),
            messages: <MessageEvent>[_reply(r'$reply', timestamp: 200)],
          ),
        ),
        receiptOutcomes: <Object?>[
          StateError('offline once'),
          StateError('offline twice'),
          null,
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final indexSubscription = container.listen(
        threadIndexProvider,
        (_, __) {},
      );
      addTearDown(indexSubscription.close);
      await container.read(threadIndexProvider.future);
      final provider = threadTimelineProvider(_key);
      final timelineSubscription = container.listen(provider, (_, __) {});
      addTearDown(timelineSubscription.close);

      await container.read(provider.future);
      await Future<void>.delayed(const Duration(milliseconds: 950));

      expect(service.receipts, <String>[r'$reply', r'$reply', r'$reply']);
      expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);
    },
  );

  test('receipt retry is not blocked by a pending index refresh', () async {
    final pendingRefresh = Completer<List<ThreadSummary>>();
    final service = _ThreadService(
      initialPage: Future.value(
        PaginatedThreadMessages(
          root: _root(),
          messages: <MessageEvent>[_reply(r'$reply', timestamp: 200)],
        ),
      ),
      indexResponses: <Future<List<ThreadSummary>>>[
        Future.value(_summaries(2)),
        pendingRefresh.future,
      ],
      receiptOutcomes: <Object?>[StateError('offline once'), null],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final indexSubscription = container.listen(threadIndexProvider, (_, __) {});
    addTearDown(indexSubscription.close);
    await container.read(threadIndexProvider.future);
    final provider = threadTimelineProvider(_key);
    final timelineSubscription = container.listen(provider, (_, __) {});
    addTearDown(timelineSubscription.close);

    await container.read(provider.future);
    await Future<void>.delayed(const Duration(milliseconds: 350));

    expect(service.receipts, <String>[r'$reply', r'$reply']);
    expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);

    pendingRefresh.complete(_summaries(2));
    await pumpEventQueue(times: 5);
    expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);
  });

  test('stale index refresh cannot undo a successful receipt', () async {
    final stale = Completer<List<ThreadSummary>>();
    final service = _ThreadService(
      initialPage: Future.value(
        PaginatedThreadMessages(
          root: _root(),
          messages: <MessageEvent>[_reply(r'$reply', timestamp: 200)],
        ),
      ),
      indexResponses: <Future<List<ThreadSummary>>>[
        Future.value(_summaries(2)),
        stale.future,
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final indexSubscription = container.listen(threadIndexProvider, (_, __) {});
    addTearDown(indexSubscription.close);
    await container.read(threadIndexProvider.future);
    final staleRefresh = container.read(threadIndexProvider.notifier).refresh();
    await pumpEventQueue();

    final provider = threadTimelineProvider(_key);
    final timelineSubscription = container.listen(provider, (_, __) {});
    addTearDown(timelineSubscription.close);
    await container.read(provider.future);
    await pumpEventQueue();
    stale.complete(_summaries(2));
    await staleRefresh;
    await pumpEventQueue(times: 5);

    expect(container.read(threadIndexProvider).value!.single.unreadCount, 0);
  });

  test('remote root and reply mutations update an open thread', () async {
    final reply = _reply(r'$reply', timestamp: 100);
    final service = _ThreadService(
      initialPage: Future.value(
        PaginatedThreadMessages(root: _root(), messages: <MessageEvent>[reply]),
      ),
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = threadTimelineProvider(_key);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);
    await container.read(provider.future);

    service.emit(_edit(r'$edit-reply', reply.eventId, 'Edited reply', 200));
    await pumpEventQueue();
    expect(
      container.read(provider).value!.newestFirst.single.body,
      'Edited reply',
    );

    service.emit(
      _edit(
        r'$edit-root',
        _key.rootEventId,
        'Edited root',
        210,
        sender: '@alice:example.org',
      ),
    );
    await pumpEventQueue();
    expect(container.read(provider).value!.root.body, 'Edited root');

    service.emit(_redaction(r'$delete-reply', reply.eventId, 300));
    await pumpEventQueue();
    expect(container.read(provider).value!.newestFirst, isEmpty);

    service.emit(_redaction(r'$delete-root', _key.rootEventId, 310));
    await pumpEventQueue();
    expect(container.read(provider).value!.root.body, 'Message deleted');
  });

  test('relation-only pages auto-advance and retain an edit', () async {
    final original = _reply(r'$older', timestamp: 100);
    final service = _ThreadService(
      initialPage: Future.value(
        PaginatedThreadMessages(
          root: _root(),
          messages: const <MessageEvent>[],
          endToken: 'p2',
        ),
      ),
      olderPages: <PaginatedThreadMessages>[
        PaginatedThreadMessages(
          root: _root(),
          messages: <MessageEvent>[
            _edit(r'$edit', original.eventId, 'Edited older', 200),
          ],
          endToken: 'p3',
        ),
        PaginatedThreadMessages(
          root: _root(),
          messages: <MessageEvent>[original],
        ),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = threadTimelineProvider(_key);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);
    await container.read(provider.future);

    await container.read(provider.notifier).loadOlder();

    final timeline = container.read(provider).value!;
    expect(service.requestedTokens, <String?>[null, 'p2', 'p3']);
    expect(timeline.newestFirst.single.body, 'Edited older');
    expect(timeline.endToken, isNull);
    expect(service.receipts, <String>[r'$root', r'$older']);
  });

  test('redaction on one relation page suppresses its later reply', () async {
    final original = _reply(r'$older', timestamp: 100);
    final service = _ThreadService(
      initialPage: Future.value(
        PaginatedThreadMessages(
          root: _root(),
          messages: const <MessageEvent>[],
          endToken: 'p2',
        ),
      ),
      olderPages: <PaginatedThreadMessages>[
        PaginatedThreadMessages(
          root: _root(),
          messages: <MessageEvent>[
            _redaction(r'$delete', original.eventId, 200),
          ],
          endToken: 'p3',
        ),
        PaginatedThreadMessages(
          root: _root(),
          messages: <MessageEvent>[original],
        ),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = threadTimelineProvider(_key);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);
    await container.read(provider.future);

    await container.read(provider.notifier).loadOlder();

    final timeline = container.read(provider).value!;
    expect(service.requestedTokens, <String?>[null, 'p2', 'p3']);
    expect(timeline.newestFirst, isEmpty);
    expect(timeline.redactedEventIds, contains(original.eventId));
    expect(service.receipts, <String>[r'$root']);
  });

  test('recursive relation pages render only exact thread children', () async {
    final valid = _reply(r'$valid', timestamp: 200);
    final service = _ThreadService(
      initialPage: Future.value(
        PaginatedThreadMessages(
          root: _root(),
          messages: <MessageEvent>[
            MessageEvent(
              eventId: r'$reference',
              roomId: _key.roomId,
              sender: '@bob:example.org',
              body: 'Reference relation',
              msgtype: 'm.text',
              timestamp: 300,
            ),
            _reply(r'$other-thread', timestamp: 250, threadRoot: r'$elsewhere'),
            valid,
          ],
        ),
      ),
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final provider = threadTimelineProvider(_key);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    final timeline = await container.read(provider.future);
    await pumpEventQueue();

    expect(timeline.newestFirst.map((message) => message.eventId), <String>[
      valid.eventId,
    ]);
    expect(service.receipts, <String>[valid.eventId]);
  });

  test(
    'newer foreign edit cannot suppress an owner edit before target load',
    () async {
      final original = _reply(r'$reply', timestamp: 100);
      final service = _ThreadService(
        initialPage: Future.value(
          PaginatedThreadMessages(
            root: _root(),
            messages: <MessageEvent>[
              original,
              _edit(r'$valid', original.eventId, 'Owner edit', 200),
              _edit(
                r'$foreign',
                original.eventId,
                'Foreign edit',
                300,
                sender: '@mallory:example.org',
              ),
            ],
          ),
        ),
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final provider = threadTimelineProvider(_key);
      final subscription = container.listen(provider, (_, __) {});
      addTearDown(subscription.close);

      final timeline = await container.read(provider.future);

      expect(timeline.newestFirst.single.body, 'Owner edit');
      expect(timeline.newestFirst.single.editedAt, 200);
    },
  );
}

ProviderContainer _container(_ThreadService service) => ProviderContainer(
  overrides: <Override>[
    matrixServiceProvider.overrideWithValue(service),
    authControllerProvider.overrideWith(_AuthenticatedController.new),
  ],
);

class _ThreadService implements MatrixService, ThreadMatrixService {
  _ThreadService({
    required this.initialPage,
    this.receiptError,
    this.receiptOutcomes = const <Object?>[],
    this.indexResponses = const <Future<List<ThreadSummary>>>[],
    this.olderPages = const <PaginatedThreadMessages>[],
  }) {
    _messages = StreamController<MessageEvent>.broadcast(
      onListen: () => hasMessageListener = true,
      onCancel: () => hasMessageListener = false,
    );
    _receipts = StreamController<ReceiptEvent>.broadcast();
  }

  final Future<PaginatedThreadMessages> initialPage;
  final Object? receiptError;
  final List<Object?> receiptOutcomes;
  final List<Future<List<ThreadSummary>>> indexResponses;
  final List<PaginatedThreadMessages> olderPages;
  late final StreamController<MessageEvent> _messages;
  late final StreamController<ReceiptEvent> _receipts;
  final List<String> receipts = <String>[];
  bool hasMessageListener = false;
  int threadIndexCalls = 0;
  int _receiptAttempt = 0;
  int _olderPage = 0;
  final List<String?> requestedTokens = <String?>[];

  void emit(MessageEvent message) => _messages.add(message);
  void emitReceipt(ReceiptEvent receipt) => _receipts.add(receipt);

  @override
  Stream<MessageEvent> get messageEvents => _messages.stream;

  @override
  Stream<ReceiptEvent> get receiptEvents => _receipts.stream;

  @override
  Future<List<ThreadSummary>> threadIndex({int limitPerRoom = 50}) async {
    final call = threadIndexCalls++;
    if (call < indexResponses.length) return indexResponses[call];
    return _summaries(2);
  }

  @override
  Future<PaginatedThreadMessages> getThreadMessages(
    String roomId,
    String threadRootEventId, {
    String? fromToken,
    int limit = 50,
  }) {
    requestedTokens.add(fromToken);
    if (fromToken == null) return initialPage;
    return Future.value(olderPages[_olderPage++]);
  }

  @override
  Future<void> sendThreadReadReceipt(
    String roomId,
    String threadRootEventId,
    String eventId,
  ) async {
    receipts.add(eventId);
    final outcome = _receiptAttempt < receiptOutcomes.length
        ? receiptOutcomes[_receiptAttempt]
        : receiptError;
    _receiptAttempt += 1;
    if (outcome != null) throw outcome;
  }

  @override
  Future<List<RoomSummary>> joinedRooms() async => const <RoomSummary>[];

  @override
  void dispose() {
    unawaited(_messages.close());
    unawaited(_receipts.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MessageEvent _root() => MessageEvent(
  eventId: _key.rootEventId,
  roomId: _key.roomId,
  sender: '@alice:example.org',
  body: 'Root',
  msgtype: 'm.text',
  timestamp: 1,
);

MessageEvent _reply(
  String eventId, {
  required int timestamp,
  String sender = '@bob:example.org',
  String threadRoot = r'$root',
}) => MessageEvent(
  eventId: eventId,
  roomId: _key.roomId,
  sender: sender,
  body: eventId,
  msgtype: 'm.text',
  timestamp: timestamp,
  threadRoot: threadRoot,
);

MessageEvent _edit(
  String eventId,
  String target,
  String body,
  int timestamp, {
  String sender = '@bob:example.org',
}) => MessageEvent(
  eventId: eventId,
  roomId: _key.roomId,
  sender: sender,
  body: body,
  msgtype: 'm.text',
  timestamp: timestamp,
  replacesEventId: target,
);

MessageEvent _redaction(String eventId, String target, int timestamp) =>
    MessageEvent(
      eventId: eventId,
      roomId: _key.roomId,
      sender: '@bob:example.org',
      body: '',
      msgtype: 'm.redaction',
      timestamp: timestamp,
      redactsEventId: target,
    );

ReceiptEvent _receipt(String eventId, {required int timestamp}) => ReceiptEvent(
  roomId: _key.roomId,
  userId: '@alice:example.org',
  eventId: eventId,
  receiptType: 'm.read',
  threadId: _key.rootEventId,
  timestamp: timestamp,
);

List<ThreadSummary> _summaries(
  int? unreadCount, {
  bool currentUserParticipated = true,
  MessageEvent? latestReply,
  int replyCount = 1,
}) => <ThreadSummary>[
  ThreadSummary(
    roomId: _key.roomId,
    roomName: 'Room',
    root: _root(),
    latestReply: latestReply ?? _reply(r'$reply', timestamp: 200),
    replyCount: replyCount,
    unreadCount: unreadCount,
    currentUserParticipated: currentUserParticipated,
  ),
];

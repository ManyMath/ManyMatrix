import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manymatrix_app/src/matrix/auth.dart';
import 'package:manymatrix_app/src/matrix/bridge_service.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';

final _selectedServiceProvider = StateProvider<MatrixService?>((ref) => null);

class _AuthenticatedController extends AuthController {
  @override
  AuthState build() => const AuthAuthenticated('@alice:example.org');
}

class _ControlledService implements MatrixService {
  _ControlledService({
    this.joinedResponses = const <Future<List<RoomSummary>>>[],
    this.invitedResponses = const <Future<List<RoomInvite>>>[],
  });

  final List<Future<List<RoomSummary>>> joinedResponses;
  final List<Future<List<RoomInvite>>> invitedResponses;
  int joinedCalls = 0;
  int invitedCalls = 0;

  @override
  Stream<MessageEvent> get messageEvents => const Stream.empty();

  @override
  Stream<ReceiptEvent> get receiptEvents => const Stream<ReceiptEvent>.empty();

  @override
  Future<List<RoomSummary>> joinedRooms() => joinedResponses[joinedCalls++];

  @override
  Future<List<RoomInvite>> invitedRooms() => invitedResponses[invitedCalls++];

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProviderContainer _container(_ControlledService service) {
  return ProviderContainer(
    overrides: <Override>[
      _selectedServiceProvider.overrideWith((ref) => service),
      matrixServiceProvider.overrideWith(
        (ref) => ref.watch(_selectedServiceProvider)!,
      ),
      authControllerProvider.overrideWith(_AuthenticatedController.new),
    ],
  );
}

RoomSummary _room(String id, String name, {bool isSynced = true}) =>
    RoomSummary(
      roomId: id,
      displayName: name,
      unreadCount: 0,
      isSynced: isSynced,
    );

RoomInvite _invite(String id, String name) =>
    RoomInvite(roomId: id, displayName: name);

void main() {
  test('room refresh keeps the newest out-of-order response', () async {
    final firstRefresh = Completer<List<RoomSummary>>();
    final secondRefresh = Completer<List<RoomSummary>>();
    final service = _ControlledService(
      joinedResponses: <Future<List<RoomSummary>>>[
        Future.value(<RoomSummary>[_room('initial', 'Initial')]),
        firstRefresh.future,
        secondRefresh.future,
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final subscription = container.listen(roomListProvider, (_, __) {});
    addTearDown(subscription.close);
    await container.read(roomListProvider.future);

    final first = container.read(roomListProvider.notifier).refresh();
    await pumpEventQueue();
    final second = container.read(roomListProvider.notifier).refresh();
    await pumpEventQueue();
    secondRefresh.complete(<RoomSummary>[_room('new', 'Newest')]);
    await second;
    firstRefresh.complete(<RoomSummary>[_room('stale', 'Stale')]);
    await first;

    expect(container.read(roomListProvider).value!.single.roomId, 'new');
  });

  test('invite refresh keeps the newest out-of-order response', () async {
    final firstRefresh = Completer<List<RoomInvite>>();
    final secondRefresh = Completer<List<RoomInvite>>();
    final service = _ControlledService(
      invitedResponses: <Future<List<RoomInvite>>>[
        Future.value(<RoomInvite>[_invite('initial', 'Initial')]),
        firstRefresh.future,
        secondRefresh.future,
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final subscription = container.listen(roomInvitesProvider, (_, __) {});
    addTearDown(subscription.close);
    await container.read(roomInvitesProvider.future);

    final first = container.read(roomInvitesProvider.notifier).refresh();
    await pumpEventQueue();
    final second = container.read(roomInvitesProvider.notifier).refresh();
    await pumpEventQueue();
    secondRefresh.complete(<RoomInvite>[_invite('new', 'Newest')]);
    await second;
    firstRefresh.complete(<RoomInvite>[_invite('stale', 'Stale')]);
    await first;

    expect(container.read(roomInvitesProvider).value!.single.roomId, 'new');
  });

  test(
    'room list discards a delayed response from the previous service',
    () async {
      final staleRooms = Completer<List<RoomSummary>>();
      final firstService = _ControlledService(
        joinedResponses: <Future<List<RoomSummary>>>[staleRooms.future],
      );
      final secondService = _ControlledService(
        joinedResponses: <Future<List<RoomSummary>>>[
          Future.value(<RoomSummary>[_room('second', 'Second')]),
        ],
      );
      final container = _container(firstService);
      addTearDown(container.dispose);
      final subscription = container.listen(roomListProvider, (_, __) {});
      addTearDown(subscription.close);
      container.read(roomListProvider);
      await pumpEventQueue();

      container.read(_selectedServiceProvider.notifier).state = secondService;
      await pumpEventQueue();
      staleRooms.complete(<RoomSummary>[_room('stale', 'Stale')]);
      await pumpEventQueue();

      expect(
        (await container.read(roomListProvider.future)).single.roomId,
        'second',
      );
    },
  );

  test('full sync retires an optimistic room name', () async {
    final service = _ControlledService(
      joinedResponses: <Future<List<RoomSummary>>>[
        Future.value(const <RoomSummary>[]),
        Future.value(<RoomSummary>[_room('joined', 'Authoritative')]),
        Future.value(const <RoomSummary>[]),
      ],
    );
    final container = _container(service);
    addTearDown(container.dispose);
    final subscription = container.listen(roomListProvider, (_, __) {});
    addTearDown(subscription.close);
    await container.read(roomListProvider.future);
    final controller = container.read(roomListProvider.notifier);

    controller.rememberRoom('joined', 'Stale alias');
    expect(
      container.read(roomListProvider).value!.single.displayName,
      'Stale alias',
    );

    await controller.refresh();
    expect(
      container.read(roomListProvider).value!.single.displayName,
      'Authoritative',
    );

    await controller.refresh();
    expect(container.read(roomListProvider).value, isEmpty);
  });

  test(
    'forget room suppresses stale rows until absence is confirmed',
    () async {
      final service = _ControlledService(
        joinedResponses: <Future<List<RoomSummary>>>[
          Future.value(const <RoomSummary>[]),
          Future.value(<RoomSummary>[_room('left', 'Stale room')]),
          Future.value(const <RoomSummary>[]),
          Future.value(<RoomSummary>[_room('left', 'Rejoined room')]),
        ],
      );
      final container = _container(service);
      addTearDown(container.dispose);
      final subscription = container.listen(roomListProvider, (_, __) {});
      addTearDown(subscription.close);
      await container.read(roomListProvider.future);
      final controller = container.read(roomListProvider.notifier);

      controller.rememberRoom('left', 'Optimistic room');
      controller.forgetRoom('left');
      expect(container.read(roomListProvider).value, isEmpty);

      await controller.refresh();
      expect(container.read(roomListProvider).value, isEmpty);

      await controller.refresh();
      expect(container.read(roomListProvider).value, isEmpty);

      await controller.refresh();
      expect(
        container.read(roomListProvider).value!.single.displayName,
        'Rejoined room',
      );
    },
  );
}

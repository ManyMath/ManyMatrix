import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';

import 'bridge_service.dart';
import 'auth.dart';
import 'providers.dart';

class ThreadKey {
  const ThreadKey({required this.roomId, required this.rootEventId});

  final String roomId;
  final String rootEventId;

  @override
  bool operator ==(Object other) =>
      other is ThreadKey &&
      other.roomId == roomId &&
      other.rootEventId == rootEventId;

  @override
  int get hashCode => Object.hash(roomId, rootEventId);
}

/// One-shot navigation requested from the cross-room Threads index.
final requestedThreadProvider = StateProvider<ThreadKey?>((ref) => null);

/// True when a previously usable index could not be refreshed. Kept separate
/// from the list so an empty prior index cannot masquerade as authoritative.
final threadIndexStaleProvider = StateProvider<bool>((ref) => false);

/// Whether a thread timeline is currently visible to the user. The default is
/// true so non-UI consumers retain the historical read-on-load behavior; the
/// chat surface explicitly owns hide/show transitions for mounted panels.
final threadVisibilityProvider = StateProvider.autoDispose
    .family<bool, ThreadKey>((ref, key) => true);

class _RoomEventKey {
  const _RoomEventKey(this.roomId, this.eventId);

  final String roomId;
  final String eventId;

  @override
  bool operator ==(Object other) =>
      other is _RoomEventKey &&
      other.roomId == roomId &&
      other.eventId == eventId;

  @override
  int get hashCode => Object.hash(roomId, eventId);
}

class _ActivityFrontier implements Comparable<_ActivityFrontier> {
  const _ActivityFrontier(this.timestamp, this.eventId, [this.observedOrder]);

  factory _ActivityFrontier.fromEvent(MessageEvent event) =>
      _ActivityFrontier(event.timestamp, event.eventId);

  final int timestamp;
  final String eventId;
  final int? observedOrder;

  @override
  int compareTo(_ActivityFrontier other) {
    final timestampOrder = timestamp.compareTo(other.timestamp);
    if (timestampOrder != 0) return timestampOrder;
    final leftOrder = observedOrder;
    final rightOrder = other.observedOrder;
    if (leftOrder != null && rightOrder != null) {
      return leftOrder.compareTo(rightOrder);
    }
    return eventId.compareTo(other.eventId);
  }
}

class _ObservedThreadReply {
  _ObservedThreadReply({
    required this.event,
    required this.own,
    required this.indexedByServer,
    required this.establishesUnreadFloor,
    required this.observedOrder,
  });

  MessageEvent event;
  bool own;
  bool indexedByServer;
  final bool establishesUnreadFloor;
  bool redactionAcknowledgedByServer = false;
  final int observedOrder;

  _ActivityFrontier get frontier =>
      _ActivityFrontier(event.timestamp, event.eventId, observedOrder);
}

/// Reconciles one thread's stateless server snapshot with activity observed
/// since this client started. Counts are always rebuilt from these records;
/// they are never incrementally copied from a previously rendered summary.
class _ThreadActivityRecord {
  _ThreadActivityRecord(this.key);

  final ThreadKey key;
  final _replies = <String, _ObservedThreadReply>{};
  final _redactedEventIds = <String>{};
  final _pendingReceiptTargets = <String>{};
  final _explicitReadEventIds = <String>{};
  ThreadSummary? _serverSnapshot;
  ThreadSummary? _fallbackSummary;
  _ActivityFrontier? _readFrontier;
  bool _serverOmitted = false;
  bool _hideOmittedSummary = false;
  bool _provisional = false;
  int _nextObservedOrder = 0;

  bool get hasActiveReplyOverlay {
    final participated = _fallbackSummary?.currentUserParticipated ?? false;
    return _replies.values.any((reply) {
      if (_redactedEventIds.contains(reply.event.eventId)) return false;
      return !reply.indexedByServer ||
          (reply.establishesUnreadFloor && !_isReplyRead(reply)) ||
          (reply.own && !participated);
    });
  }

  bool get hasReconciliationState =>
      _pendingReceiptTargets.isNotEmpty ||
      _explicitReadEventIds.isNotEmpty ||
      _readFrontier != null ||
      _redactedEventIds.isNotEmpty ||
      _replies.isNotEmpty;

  bool get isIncomplete {
    if (_hideOmittedSummary) return false;
    if (_provisional || (_serverOmitted && hasActiveReplyOverlay)) {
      return true;
    }
    final baseline = _fallbackSummary;
    if (baseline == null) return false;
    return _baselineRedactions(baseline).isNotEmpty ||
        _redactedEventIds.contains(baseline.root.eventId);
  }

  int get observedUnreadCount => _replies.values.where((reply) {
    if (reply.own || _redactedEventIds.contains(reply.event.eventId)) {
      return false;
    }
    return reply.establishesUnreadFloor && !_isReplyRead(reply);
  }).length;

  bool references(String eventId) =>
      eventId == key.rootEventId ||
      _replies.containsKey(eventId) ||
      _fallbackSummary?.latestReply?.eventId == eventId;

  void observeReply(
    MessageEvent reply, {
    required bool own,
    required bool redacted,
  }) {
    if (redacted) _redactedEventIds.add(reply.eventId);
    final existing = _replies[reply.eventId];
    if (existing == null) {
      final indexedByServer = _serverAlreadyCovers(reply);
      _replies[reply.eventId] = _ObservedThreadReply(
        event: reply,
        own: own,
        indexedByServer: indexedByServer,
        establishesUnreadFloor:
            !own &&
            (!indexedByServer ||
                _fallbackSummary?.latestReply?.eventId == reply.eventId),
        observedOrder: ++_nextObservedOrder,
      );
    } else {
      existing
        ..event = reply
        ..own = existing.own || own;
    }
    final observed = _replies[reply.eventId]!;

    if (!redacted && _fallbackSummary == null) {
      _provisional = true;
      _fallbackSummary = ThreadSummary(
        roomId: key.roomId,
        roomName: key.roomId,
        root: MessageEvent(
          eventId: key.rootEventId,
          roomId: key.roomId,
          sender: 'unknown',
          body: 'Message thread',
          msgtype: 'm.notice',
          timestamp: 0,
        ),
        latestReply: null,
        replyCount: 0,
        unreadCount: 0,
        currentUserParticipated: false,
      );
    }
    if (!redacted && hasActiveReplyOverlay) _hideOmittedSummary = false;

    if (own) _advanceReadFrontier(observed.frontier);
    _resolvePendingReceiptTarget(reply.eventId);
  }

  void observeRedaction(String eventId) {
    _redactedEventIds.add(eventId);
    if (_provisional && !hasActiveReplyOverlay) {
      _serverSnapshot = null;
      _fallbackSummary = null;
      _provisional = false;
      _hideOmittedSummary = true;
    }
  }

  void observeReceipt(String eventId) {
    if (_markKnownReadTarget(eventId, preserveObservedOrder: true)) return;
    _pendingReceiptTargets.add(eventId);
  }

  void commitRead({String? eventId, int? eventTimestamp}) {
    final observed = eventId == null ? null : _replies[eventId];
    if (observed != null) {
      _explicitReadEventIds.add(eventId!);
      _advanceReadFrontier(observed.frontier);
      return;
    }
    if (eventId != null && eventTimestamp != null) {
      _explicitReadEventIds.add(eventId);
      _advanceReadFrontier(_ActivityFrontier(eventTimestamp, eventId));
      return;
    }
    if (eventId != null) {
      if (_markKnownReadTarget(eventId, preserveObservedOrder: false)) return;
      _pendingReceiptTargets.add(eventId);
      return;
    }
    final latest = _latestKnownFrontier();
    if (latest != null) {
      _explicitReadEventIds.add(latest.eventId);
      _advanceReadFrontier(latest);
    }
  }

  void acceptServer(ThreadSummary summary) {
    final previousLatest = _serverSnapshot?.latestReply;
    final previousCount =
        _serverSnapshot?.replyCount ??
        (_provisional ? 0 : _fallbackSummary?.replyCount ?? 0);
    final pendingRedactions = _replies.values
        .where(
          (reply) =>
              reply.indexedByServer &&
              !reply.redactionAcknowledgedByServer &&
              _redactedEventIds.contains(reply.event.eventId),
        )
        .toList(growable: false);
    final latest = summary.latestReply;
    var coverageBudget = summary.replyCount + pendingRedactions.length;
    coverageBudget = coverageBudget > previousCount
        ? coverageBudget - previousCount
        : 0;
    var newlyCovered = 0;
    final unobservedLatestGrowth =
        pendingRedactions.isNotEmpty &&
        coverageBudget > 0 &&
        previousLatest != null &&
        latest != null &&
        latest.eventId != previousLatest.eventId &&
        latest.timestamp >= previousLatest.timestamp &&
        !_replies.containsKey(latest.eventId);
    if (unobservedLatestGrowth) {
      newlyCovered += 1;
      coverageBudget -= 1;
    }
    if (latest != null) {
      final candidates = _replies.values.toList(growable: false)
        ..sort((left, right) => left.frontier.compareTo(right.frontier));
      for (final reply in candidates) {
        if (reply.indexedByServer ||
            _redactedEventIds.contains(reply.event.eventId)) {
          continue;
        }
        final directlyCovered =
            reply.event.eventId == latest.eventId ||
            reply.event.timestamp < latest.timestamp;
        if (directlyCovered) {
          reply.indexedByServer = true;
          newlyCovered += 1;
          if (coverageBudget > 0) coverageBudget -= 1;
        }
      }
      if (coverageBudget > 0) {
        for (final reply in candidates) {
          if (coverageBudget == 0) break;
          if (reply.indexedByServer ||
              _redactedEventIds.contains(reply.event.eventId) ||
              reply.event.timestamp > latest.timestamp) {
            continue;
          }
          reply.indexedByServer = true;
          newlyCovered += 1;
          coverageBudget -= 1;
        }
      }
    }

    var acknowledgedRedactions =
        previousCount + newlyCovered - summary.replyCount;
    if (acknowledgedRedactions < 0) acknowledgedRedactions = 0;
    for (final reply in pendingRedactions) {
      if (acknowledgedRedactions == 0) break;
      reply.redactionAcknowledgedByServer = true;
      acknowledgedRedactions -= 1;
    }

    _serverSnapshot = summary;
    _fallbackSummary = summary;
    _serverOmitted = false;
    _hideOmittedSummary = false;
    _provisional = false;
    _resolvePendingReceiptTarget(summary.root.eventId);
    if (latest != null) _resolvePendingReceiptTarget(latest.eventId);
  }

  void markServerOmitted({required bool retainSummary}) {
    _serverOmitted = true;
    _hideOmittedSummary = !retainSummary;
  }

  ThreadSummary? render() {
    if (_hideOmittedSummary) return null;
    final baseline = _fallbackSummary;
    if (baseline == null) return null;

    final baselineLatest = baseline.latestReply;
    final latestReply = _latestVisibleReply(baseline);

    final baselineRedactions = _baselineRedactions(baseline);
    var replyCount = baseline.replyCount - baselineRedactions.length;
    replyCount += _replies.values.where((reply) {
      return !reply.indexedByServer &&
          !_redactedEventIds.contains(reply.event.eventId);
    }).length;
    if (replyCount < 0) replyCount = 0;

    int? unreadCount = baseline.unreadCount;
    final baselineActivity = baselineLatest ?? baseline.root;
    if (_isEventReadThrough(baselineActivity)) {
      unreadCount = 0;
    } else if (unreadCount != null &&
        unreadCount > 0 &&
        baselineRedactions.isNotEmpty) {
      unreadCount -= baselineRedactions.length;
      if (unreadCount < 0) unreadCount = 0;
    }
    final observedUnread = observedUnreadCount;
    if (unreadCount == null) {
      if (observedUnread > 0) unreadCount = observedUnread;
    } else if (observedUnread > unreadCount) {
      unreadCount = observedUnread;
    }

    final root = _redactedEventIds.contains(baseline.root.eventId)
        ? _deletedThreadRoot(baseline.root)
        : baseline.root;
    return ThreadSummary(
      roomId: baseline.roomId,
      roomName: baseline.roomName,
      root: root,
      latestReply: latestReply,
      replyCount: replyCount,
      unreadCount: unreadCount,
      currentUserParticipated:
          baseline.currentUserParticipated ||
          _replies.values.any((reply) => reply.own),
    );
  }

  int? unreadAfterFailedRefresh(ThreadSummary rendered) {
    final observedUnread = observedUnreadCount;
    if (observedUnread > 0) return observedUnread;
    final latestActivity = rendered.latestReply ?? rendered.root;
    return _isEventReadThrough(latestActivity) ? 0 : null;
  }

  bool _serverAlreadyCovers(MessageEvent reply) {
    final latest = _fallbackSummary?.latestReply;
    if (latest == null) return false;
    return reply.eventId == latest.eventId ||
        reply.timestamp < latest.timestamp;
  }

  bool _markKnownReadTarget(
    String eventId, {
    required bool preserveObservedOrder,
  }) {
    _ActivityFrontier? frontier;
    final observed = _replies[eventId];
    if (observed != null) {
      frontier = preserveObservedOrder
          ? observed.frontier
          : _ActivityFrontier.fromEvent(observed.event);
    } else {
      final summary = _fallbackSummary;
      if (summary?.root.eventId == eventId) {
        frontier = _ActivityFrontier.fromEvent(summary!.root);
      } else if (summary?.latestReply?.eventId == eventId) {
        frontier = _ActivityFrontier.fromEvent(summary!.latestReply!);
      }
    }
    if (frontier == null) return false;
    _explicitReadEventIds.add(eventId);
    _advanceReadFrontier(frontier);
    return true;
  }

  bool _resolvePendingReceiptTarget(String eventId) {
    if (!_pendingReceiptTargets.contains(eventId)) return false;
    MessageEvent? target = _replies[eventId]?.event;
    final summary = _fallbackSummary;
    if (target == null && summary?.root.eventId == eventId) {
      target = summary!.root;
    } else if (target == null && summary?.latestReply?.eventId == eventId) {
      target = summary!.latestReply!;
    }
    if (target == null) return false;
    _pendingReceiptTargets.remove(eventId);
    _explicitReadEventIds.add(eventId);
    // A target learned after its receipt has no trustworthy ordering against
    // distinct events with the same timestamp. Keep only the exact target and
    // strict timestamp boundary authoritative.
    _advanceReadFrontier(_ActivityFrontier.fromEvent(target));
    return true;
  }

  void _advanceReadFrontier(_ActivityFrontier candidate) {
    final current = _readFrontier;
    if (current == null) {
      _readFrontier = candidate;
      return;
    }
    final timestampOrder = candidate.timestamp.compareTo(current.timestamp);
    if (timestampOrder > 0) {
      _readFrontier = candidate;
      return;
    }
    if (timestampOrder < 0) return;
    final candidateOrder = candidate.observedOrder;
    final currentOrder = current.observedOrder;
    if (candidateOrder != null &&
        (currentOrder == null || candidateOrder > currentOrder)) {
      _readFrontier = candidate;
    }
  }

  bool _isReplyRead(_ObservedThreadReply reply) =>
      _isEventReadThrough(reply.event);

  bool _isEventReadThrough(MessageEvent event) {
    if (_explicitReadEventIds.contains(event.eventId)) return true;
    final readFrontier = _readFrontier;
    if (readFrontier == null) return false;
    final timestampOrder = event.timestamp.compareTo(readFrontier.timestamp);
    if (timestampOrder != 0) return timestampOrder < 0;
    final eventOrder = _replies[event.eventId]?.observedOrder;
    final readOrder = readFrontier.observedOrder;
    if (eventOrder == null && readOrder != null) return true;
    return eventOrder != null && readOrder != null && eventOrder <= readOrder;
  }

  Set<String> _baselineRedactions(ThreadSummary baseline) => <String>{
    for (final reply in _replies.values)
      if (reply.indexedByServer &&
          !reply.redactionAcknowledgedByServer &&
          _redactedEventIds.contains(reply.event.eventId))
        reply.event.eventId,
    if (baseline.latestReply != null &&
        _redactedEventIds.contains(baseline.latestReply!.eventId) &&
        !_replies.containsKey(baseline.latestReply!.eventId))
      baseline.latestReply!.eventId,
  };

  _ActivityFrontier? _latestKnownFrontier() {
    final baseline = _fallbackSummary;
    if (baseline == null) return null;
    final latestReply = _latestVisibleReply(baseline);
    return latestReply == null
        ? _ActivityFrontier.fromEvent(baseline.root)
        : _frontierForEvent(latestReply);
  }

  MessageEvent? _latestVisibleReply(ThreadSummary baseline) {
    final baselineLatest = baseline.latestReply;
    MessageEvent? latest =
        baselineLatest == null ||
            _redactedEventIds.contains(baselineLatest.eventId)
        ? null
        : baselineLatest;
    for (final candidate in _replies.values) {
      if (_redactedEventIds.contains(candidate.event.eventId)) continue;
      final current = latest;
      if (current == null || _isDisplayNewer(candidate, current)) {
        latest = candidate.event;
      }
    }
    return latest;
  }

  bool _isDisplayNewer(_ObservedThreadReply candidate, MessageEvent current) {
    final timestampOrder = candidate.event.timestamp.compareTo(
      current.timestamp,
    );
    if (timestampOrder != 0) return timestampOrder > 0;
    final currentObserved = _replies[current.eventId];
    if (currentObserved != null) {
      return candidate.observedOrder > currentObserved.observedOrder;
    }
    // The server's latest event wins equal-timestamp ties once it has counted
    // the local event. Before then, arrival order is the only available proof
    // that a distinct live event happened after the snapshot.
    return candidate.event.eventId != current.eventId &&
        !candidate.indexedByServer;
  }

  _ActivityFrontier _frontierForEvent(MessageEvent event) {
    return _replies[event.eventId]?.frontier ??
        _ActivityFrontier.fromEvent(event);
  }
}

class ThreadIndexController extends AsyncNotifier<List<ThreadSummary>> {
  Timer? _refreshDebounce;
  Future<List<ThreadSummary>>? _indexLoad;
  MatrixService? _indexLoadService;
  int _generation = 0;
  int _refreshRequest = 0;
  int _staleRevision = 0;
  bool _building = false;
  bool _refreshFailed = false;
  final _activity = <ThreadKey, _ThreadActivityRecord>{};
  final _redactedEvents = <_RoomEventKey>{};
  MatrixService? _activityService;
  String? _activityUserId;

  @override
  Future<List<ThreadSummary>> build() async {
    _building = true;
    try {
      return await _buildIndex();
    } finally {
      _building = false;
    }
  }

  Future<List<ThreadSummary>> _buildIndex() async {
    final generation = ++_generation;
    final request = ++_refreshRequest;
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated) {
      _resetLocallyReadScope();
      _setIndexStale(false);
      return const <ThreadSummary>[];
    }
    final service = ref.watch(matrixServiceProvider);
    if (!identical(_activityService, service) ||
        _activityUserId != auth.userId) {
      _activity.clear();
      _redactedEvents.clear();
      _activityService = service;
      _activityUserId = auth.userId;
      _refreshFailed = false;
      _setIndexStale(false);
    }
    final subscription = service.messageEvents
        .where(
          (event) =>
              event.threadRoot != null ||
              event.replacesEventId != null ||
              event.redactsEventId != null,
        )
        .listen((event) {
          _observeMessage(event, currentUserId: auth.userId);
          _scheduleRefresh();
        });
    final receiptSubscription = service.receiptEvents.listen((receipt) {
      final threadId = receipt.threadId;
      if (receipt.userId == auth.userId &&
          threadId != null &&
          threadId != 'main') {
        _applyOwnThreadReceipt(receipt);
      }
      _scheduleRefresh();
    });
    ref.onDispose(() {
      _generation += 1;
      _refreshDebounce?.cancel();
      _indexLoad = null;
      _indexLoadService = null;
      unawaited(subscription.cancel());
      unawaited(receiptSubscription.cancel());
    });
    final threads = await _loadIndex(service);
    if (generation != _generation ||
        request != _refreshRequest ||
        !identical(ref.read(matrixServiceProvider), service)) {
      return const <ThreadSummary>[];
    }
    _refreshFailed = false;
    return _reconcileServerIndex(threads);
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(refresh());
      unawaited(ref.read(roomListProvider.notifier).refresh());
    });
  }

  Future<void> refresh() async {
    if (ref.read(authControllerProvider) is! AuthAuthenticated) return;
    final generation = _generation;
    final request = ++_refreshRequest;
    final service = ref.read(matrixServiceProvider);
    try {
      final threads = await _loadIndex(service);
      if (generation != _generation ||
          request != _refreshRequest ||
          !identical(ref.read(matrixServiceProvider), service)) {
        return;
      }
      _refreshFailed = false;
      state = AsyncData(_reconcileServerIndex(threads));
    } on Object {
      if (generation != _generation ||
          request != _refreshRequest ||
          !identical(ref.read(matrixServiceProvider), service)) {
        return;
      }
      // Keep the navigable index, but never present stale counts as
      // authoritative after a refresh failure.
      _refreshFailed = true;
      _setIndexStale(true);
      final current = state.valueOrNull;
      if (current != null) state = AsyncData(_withUnknownUnread(current));
    }
  }

  Future<List<ThreadSummary>> _loadIndex(MatrixService service) {
    final current = _indexLoad;
    if (current != null && identical(_indexLoadService, service)) {
      return current;
    }
    late final Future<List<ThreadSummary>> load;
    load =
        Future<List<ThreadSummary>>.sync(
          () => _requireThreadService(service).threadIndex(),
        ).whenComplete(() {
          if (identical(_indexLoad, load)) {
            _indexLoad = null;
            _indexLoadService = null;
          }
        });
    _indexLoad = load;
    _indexLoadService = service;
    return load;
  }

  void commitRead(ThreadKey key, {String? eventId, int? eventTimestamp}) {
    final activity = _activity.putIfAbsent(
      key,
      () => _ThreadActivityRecord(key),
    );
    activity.commitRead(eventId: eventId, eventTimestamp: eventTimestamp);
    _publishLocalActivity();
  }

  void rememberReply(MessageEvent reply) {
    final rootEventId = reply.threadRoot;
    if (rootEventId == null) return;
    final key = ThreadKey(roomId: reply.roomId, rootEventId: rootEventId);
    final activity = _activity.putIfAbsent(
      key,
      () => _ThreadActivityRecord(key),
    );
    final redacted = _redactedEvents.contains(
      _RoomEventKey(reply.roomId, reply.eventId),
    );
    activity.observeReply(reply, own: true, redacted: redacted);
    _publishLocalActivity();
  }

  void _observeMessage(MessageEvent event, {required String currentUserId}) {
    final redactedEventId = event.redactsEventId;
    if (redactedEventId != null) {
      _redactedEvents.add(_RoomEventKey(event.roomId, redactedEventId));
      for (final activity in _activity.values) {
        if (activity.key.roomId == event.roomId &&
            activity.references(redactedEventId)) {
          activity.observeRedaction(redactedEventId);
        }
      }
      _publishLocalActivity();
      return;
    }

    final rootEventId = event.threadRoot;
    if (rootEventId == null) return;
    final key = ThreadKey(roomId: event.roomId, rootEventId: rootEventId);
    final activity = _activity.putIfAbsent(
      key,
      () => _ThreadActivityRecord(key),
    );
    final redacted = _redactedEvents.contains(
      _RoomEventKey(event.roomId, event.eventId),
    );
    activity.observeReply(
      event,
      own: event.sender == currentUserId,
      redacted: redacted,
    );
    _publishLocalActivity();
  }

  List<ThreadSummary> _reconcileServerIndex(List<ThreadSummary> threads) {
    final returned = <ThreadKey>{};
    for (final thread in threads) {
      final key = ThreadKey(
        roomId: thread.roomId,
        rootEventId: thread.root.eventId,
      );
      returned.add(key);
      final activity = _activity.putIfAbsent(
        key,
        () => _ThreadActivityRecord(key),
      );
      activity.acceptServer(thread);
      if (_redactedEvents.contains(
        _RoomEventKey(thread.roomId, thread.root.eventId),
      )) {
        activity.observeRedaction(thread.root.eventId);
      }
      final latestReply = thread.latestReply;
      if (latestReply != null &&
          _redactedEvents.contains(
            _RoomEventKey(thread.roomId, latestReply.eventId),
          )) {
        activity.observeRedaction(latestReply.eventId);
      }
    }

    final remove = <ThreadKey>[];
    for (final entry in _activity.entries) {
      if (returned.contains(entry.key)) continue;
      if (entry.value.hasActiveReplyOverlay) {
        entry.value.markServerOmitted(retainSummary: true);
      } else if (entry.value.hasReconciliationState) {
        entry.value.markServerOmitted(retainSummary: false);
      } else {
        remove.add(entry.key);
      }
    }
    for (final key in remove) {
      _activity.remove(key);
    }
    return _renderActivity();
  }

  List<ThreadSummary> _withUnknownUnread(List<ThreadSummary> threads) => [
    for (final thread in threads) _withRefreshFailureUnread(thread),
  ];

  ThreadSummary _withRefreshFailureUnread(ThreadSummary thread) {
    final activity =
        _activity[ThreadKey(
          roomId: thread.roomId,
          rootEventId: thread.root.eventId,
        )];
    return ThreadSummary(
      roomId: thread.roomId,
      roomName: thread.roomName,
      root: thread.root,
      latestReply: thread.latestReply,
      replyCount: thread.replyCount,
      unreadCount: activity?.unreadAfterFailedRefresh(thread),
      currentUserParticipated: thread.currentUserParticipated,
    );
  }

  void _publishLocalActivity() {
    if (state.valueOrNull == null) return;
    state = AsyncData(_renderActivity());
  }

  List<ThreadSummary> _renderActivity() {
    final rendered =
        <ThreadSummary>[
          for (final activity in _activity.values)
            if (activity.render() case final summary?) summary,
        ]..sort((left, right) {
          final activityOrder = right.lastActivityTimestamp.compareTo(
            left.lastActivityTimestamp,
          );
          if (activityOrder != 0) return activityOrder;
          return right.root.eventId.compareTo(left.root.eventId);
        });
    _setIndexStale(
      _refreshFailed ||
          _activity.values.any((activity) => activity.isIncomplete),
    );
    return rendered;
  }

  void _setIndexStale(bool stale) {
    final revision = ++_staleRevision;
    if (!_building) {
      ref.read(threadIndexStaleProvider.notifier).state = stale;
      return;
    }
    final generation = _generation;
    scheduleMicrotask(() {
      if (revision != _staleRevision || generation != _generation) return;
      ref.read(threadIndexStaleProvider.notifier).state = stale;
    });
  }

  void _applyOwnThreadReceipt(ReceiptEvent receipt) {
    final threadId = receipt.threadId;
    if (threadId == null || threadId == 'main') return;
    final key = ThreadKey(roomId: receipt.roomId, rootEventId: threadId);
    final activity = _activity.putIfAbsent(
      key,
      () => _ThreadActivityRecord(key),
    );
    activity.observeReceipt(receipt.eventId);
    _publishLocalActivity();
  }

  void _resetLocallyReadScope() {
    _activity.clear();
    _redactedEvents.clear();
    _activityService = null;
    _activityUserId = null;
    _refreshFailed = false;
  }
}

final threadIndexProvider =
    AsyncNotifierProvider<ThreadIndexController, List<ThreadSummary>>(
      ThreadIndexController.new,
    );

class ThreadTimeline {
  const ThreadTimeline({
    required this.root,
    required this.newestFirst,
    this.endToken,
    this.loadingOlder = false,
    this.olderError,
    this.redactedEventIds = const <String>{},
  });

  final MessageEvent root;
  final List<MessageEvent> newestFirst;
  final String? endToken;
  final bool loadingOlder;
  final Object? olderError;
  final Set<String> redactedEventIds;

  bool get canLoadOlder => endToken != null && !loadingOlder;

  ThreadTimeline copyWith({
    MessageEvent? root,
    List<MessageEvent>? newestFirst,
    String? endToken,
    bool clearEndToken = false,
    bool? loadingOlder,
    Object? olderError,
    bool clearOlderError = false,
    Set<String>? redactedEventIds,
  }) => ThreadTimeline(
    root: root ?? this.root,
    newestFirst: newestFirst ?? this.newestFirst,
    endToken: clearEndToken ? null : (endToken ?? this.endToken),
    loadingOlder: loadingOlder ?? this.loadingOlder,
    olderError: clearOlderError ? null : (olderError ?? this.olderError),
    redactedEventIds: redactedEventIds ?? this.redactedEventIds,
  );
}

class ThreadTimelineController
    extends AutoDisposeFamilyAsyncNotifier<ThreadTimeline, ThreadKey> {
  static const _pageSize = 50;
  static const _maxEmptyPageHops = 8;
  static const _maxReadReceiptAttempts = 3;
  static const _readReceiptRetryDelays = <Duration>[
    Duration(milliseconds: 200),
    Duration(milliseconds: 600),
  ];
  int _generation = 0;
  int _readyGeneration = 0;
  String? _committedReadEventId;
  String? _pendingReadEventId;
  int _readRequest = 0;
  Timer? _readRetryTimer;
  String? _readRetryEventId;
  int _readAttempt = 0;
  final _pendingLive = <MessageEvent>[];
  final _pendingReplacements = <String, List<MessageEvent>>{};
  final _pendingRedactions = <String>{};

  @override
  Future<ThreadTimeline> build(ThreadKey key) async {
    final generation = ++_generation;
    _readyGeneration = 0;
    _committedReadEventId = null;
    _pendingReadEventId = null;
    _clearReadRetry();
    _pendingLive.clear();
    _pendingReplacements.clear();
    _pendingRedactions.clear();
    final service = ref.watch(matrixServiceProvider);
    ref.listen(threadVisibilityProvider(key), (previous, visible) {
      if (!visible) {
        _clearReadRetry();
        return;
      }
      final timeline = state.valueOrNull;
      if (timeline != null && _readyGeneration == _generation) {
        _markNewestRead(timeline);
      }
    });
    final subscription = service.messageEvents
        .where((event) => event.roomId == key.roomId)
        .listen((event) {
          if (generation != _generation) return;
          if (_readyGeneration != generation) {
            _pendingLive.add(event);
          } else {
            _appendLive(event);
          }
        });
    ref.onDispose(() {
      _generation += 1;
      _readyGeneration = 0;
      _pendingLive.clear();
      _pendingReplacements.clear();
      _pendingRedactions.clear();
      _clearReadRetry();
      unawaited(subscription.cancel());
    });

    final page = await _requireThreadService(
      service,
    ).getThreadMessages(key.roomId, key.rootEventId, limit: _pageSize);
    if (generation != _generation) {
      return ThreadTimeline(root: page.root, newestFirst: const []);
    }
    final pendingAtSnapshot = List<MessageEvent>.from(_pendingLive);
    _pendingLive.clear();
    final newestFirst = _mergeThreadPage(const [], page.messages.reversed);
    final timeline = ThreadTimeline(
      root: _applyPendingThreadRoot(page.root),
      newestFirst: newestFirst,
      endToken: page.endToken,
      redactedEventIds: Set<String>.unmodifiable(_pendingRedactions),
    );
    state = AsyncData(timeline);
    _readyGeneration = generation;
    for (final event in pendingAtSnapshot) {
      _appendLive(event);
    }
    final installed = state.valueOrNull ?? timeline;
    _markNewestRead(installed);
    return installed;
  }

  Future<void> loadOlder() async {
    final timeline = state.valueOrNull;
    if (timeline == null ||
        _readyGeneration != _generation ||
        !timeline.canLoadOlder) {
      return;
    }
    state = AsyncData(
      timeline.copyWith(loadingOlder: true, clearOlderError: true),
    );
    final generation = _generation;
    final service = ref.read(matrixServiceProvider);
    var requestToken = timeline.endToken;
    try {
      for (var hop = 0; hop < _maxEmptyPageHops; hop += 1) {
        final page = await _requireThreadService(service).getThreadMessages(
          arg.roomId,
          arg.rootEventId,
          fromToken: requestToken,
          limit: _pageSize,
        );
        if (generation != _generation ||
            !identical(ref.read(matrixServiceProvider), service)) {
          return;
        }
        final current = state.valueOrNull ?? timeline;
        if (!current.loadingOlder || current.endToken != requestToken) return;
        final merged = _mergeThreadPage(
          current.newestFirst,
          page.messages.reversed,
        );
        final nextToken = page.endToken;
        final madeProgress = nextToken != null && nextToken != requestToken;
        final addedReplies = merged.length > current.newestFirst.length;
        final shouldContinue =
            !addedReplies && madeProgress && hop + 1 < _maxEmptyPageHops;
        final updated = current.copyWith(
          root: _applyPendingThreadRoot(current.root),
          newestFirst: merged,
          endToken: nextToken,
          clearEndToken: nextToken == null,
          loadingOlder: shouldContinue,
          clearOlderError: true,
          redactedEventIds: Set<String>.unmodifiable(_pendingRedactions),
        );
        state = AsyncData(updated);
        _markNewestRead(updated);
        if (!shouldContinue) return;
        requestToken = nextToken;
      }
    } on Object catch (error) {
      if (generation != _generation ||
          !identical(ref.read(matrixServiceProvider), service)) {
        return;
      }
      state = AsyncData(
        (state.valueOrNull ?? timeline).copyWith(
          loadingOlder: false,
          olderError: error,
        ),
      );
    }
  }

  void _appendLive(MessageEvent event) {
    final current = state.valueOrNull;
    if (current == null || _readyGeneration != _generation) {
      _pendingLive.add(event);
      return;
    }
    final redactedTarget = event.redactsEventId;
    if (redactedTarget != null) {
      _pendingRedactions.add(redactedTarget);
      _pendingReplacements.remove(redactedTarget);
      state = AsyncData(
        current.copyWith(
          root: _applyPendingThreadRoot(current.root),
          newestFirst: current.newestFirst
              .where((message) => message.eventId != redactedTarget)
              .toList(growable: false),
          redactedEventIds: Set<String>.unmodifiable(_pendingRedactions),
        ),
      );
      return;
    }
    final replacedTarget = event.replacesEventId;
    if (replacedTarget != null) {
      _retainLatestThreadReplacement(_pendingReplacements, event);
      state = AsyncData(
        current.copyWith(
          root: _applyPendingThreadRoot(current.root),
          newestFirst: current.newestFirst
              .map(
                (message) => message.eventId == replacedTarget
                    ? _applyThreadReplacement(message, event)
                    : message,
              )
              .toList(growable: false),
        ),
      );
      return;
    }
    if (event.threadRoot != arg.rootEventId ||
        _pendingRedactions.contains(event.eventId)) {
      return;
    }
    final displayed = _applyThreadReplacement(
      event,
      _latestThreadReplacementFor(event, _pendingReplacements[event.eventId]),
    );
    state = AsyncData(
      current.copyWith(
        newestFirst: <MessageEvent>[
          displayed,
          ...current.newestFirst.where(
            (message) => message.eventId != displayed.eventId,
          ),
        ],
      ),
    );
    _sendReadReceipt(displayed.eventId);
  }

  List<MessageEvent> _mergeThreadPage(
    List<MessageEvent> currentNewestFirst,
    Iterable<MessageEvent> pageNewestFirst,
  ) {
    var merged = <MessageEvent>[...currentNewestFirst];
    final seen = merged.map((message) => message.eventId).toSet();
    for (final event in pageNewestFirst) {
      final redactedTarget = event.redactsEventId;
      if (redactedTarget != null) {
        _pendingRedactions.add(redactedTarget);
        _pendingReplacements.remove(redactedTarget);
        merged.removeWhere((message) => message.eventId == redactedTarget);
        seen.remove(redactedTarget);
        continue;
      }
      final replacedTarget = event.replacesEventId;
      if (replacedTarget != null) {
        _retainLatestThreadReplacement(_pendingReplacements, event);
        merged = <MessageEvent>[
          for (final message in merged)
            if (message.eventId == replacedTarget)
              _applyThreadReplacement(message, event)
            else
              message,
        ];
        continue;
      }
      if (_pendingRedactions.contains(event.eventId) ||
          event.threadRoot != arg.rootEventId ||
          !seen.add(event.eventId)) {
        // Recursive AllRelations pages also contain references and nested
        // relations. Only exact m.thread children render as replies. A
        // redacted reply with stripped relation metadata is intentionally
        // omitted rather than shown as an unscoped tombstone.
        continue;
      }
      merged.add(
        _applyThreadReplacement(
          event,
          _latestThreadReplacementFor(
            event,
            _pendingReplacements[event.eventId],
          ),
        ),
      );
    }
    return merged;
  }

  MessageEvent _applyPendingThreadRoot(MessageEvent root) {
    if (_pendingRedactions.contains(root.eventId)) {
      return _deletedThreadRoot(root);
    }
    return _applyThreadReplacement(
      root,
      _latestThreadReplacementFor(root, _pendingReplacements[root.eventId]),
    );
  }

  void _markNewestRead(ThreadTimeline timeline) {
    final eventId = timeline.newestFirst.isEmpty
        ? timeline.root.eventId
        : timeline.newestFirst.first.eventId;
    _sendReadReceipt(eventId);
  }

  void _sendReadReceipt(String eventId) {
    if (!ref.read(threadVisibilityProvider(arg))) return;
    if (_committedReadEventId == eventId || _pendingReadEventId == eventId) {
      return;
    }
    final service = ref.read(matrixServiceProvider);
    if (service is! ThreadMatrixService) return;
    if (_readRetryEventId != eventId) {
      _clearReadRetry();
      _readRetryEventId = eventId;
    } else {
      _readRetryTimer?.cancel();
      _readRetryTimer = null;
    }
    _readAttempt += 1;
    _pendingReadEventId = eventId;
    final request = ++_readRequest;
    final threadService = service as ThreadMatrixService;
    unawaited(
      _persistReadReceipt(
        threadService,
        eventId,
        generation: _generation,
        request: request,
      ),
    );
  }

  Future<void> _persistReadReceipt(
    ThreadMatrixService service,
    String eventId, {
    required int generation,
    required int request,
  }) async {
    try {
      await service.sendThreadReadReceipt(arg.roomId, arg.rootEventId, eventId);
      if (generation != _generation ||
          request != _readRequest ||
          !identical(ref.read(matrixServiceProvider), service)) {
        return;
      }
      _pendingReadEventId = null;
      _committedReadEventId = eventId;
      _clearReadRetry();
      ref
          .read(threadIndexProvider.notifier)
          .commitRead(
            arg,
            eventId: eventId,
            eventTimestamp: _eventTimestamp(eventId),
          );
      unawaited(ref.read(threadIndexProvider.notifier).refresh());
      unawaited(ref.read(roomListProvider.notifier).refresh());
    } on Object {
      if (generation != _generation || request != _readRequest) return;
      _pendingReadEventId = null;
      if (!identical(ref.read(matrixServiceProvider), service) ||
          _readRetryEventId != eventId ||
          _readAttempt >= _maxReadReceiptAttempts) {
        return;
      }
      final delay = _readReceiptRetryDelays[_readAttempt - 1];
      _readRetryTimer = Timer(delay, () {
        _readRetryTimer = null;
        if (generation == _generation &&
            _readRetryEventId == eventId &&
            _pendingReadEventId == null &&
            _committedReadEventId != eventId) {
          _sendReadReceipt(eventId);
        }
      });
      unawaited(ref.read(threadIndexProvider.notifier).refresh());
    }
  }

  void _clearReadRetry() {
    _readRetryTimer?.cancel();
    _readRetryTimer = null;
    _readRetryEventId = null;
    _readAttempt = 0;
  }

  int? _eventTimestamp(String eventId) {
    final timeline = state.valueOrNull;
    if (timeline == null) return null;
    if (timeline.root.eventId == eventId) return timeline.root.timestamp;
    for (final reply in timeline.newestFirst) {
      if (reply.eventId == eventId) return reply.timestamp;
    }
    return null;
  }
}

ThreadMatrixService _requireThreadService(MatrixService service) {
  if (service is ThreadMatrixService) return service as ThreadMatrixService;
  throw UnsupportedError(
    'This Matrix transport does not support server-backed thread discovery.',
  );
}

void _retainLatestThreadReplacement(
  Map<String, List<MessageEvent>> replacements,
  MessageEvent replacement,
) {
  final target = replacement.replacesEventId;
  if (target == null) return;
  final candidates = replacements.putIfAbsent(target, () => <MessageEvent>[]);
  final existingIndex = candidates.indexWhere(
    (candidate) => candidate.sender == replacement.sender,
  );
  if (existingIndex == -1) {
    candidates.add(replacement);
  } else if (replacement.timestamp > candidates[existingIndex].timestamp) {
    candidates[existingIndex] = replacement;
  }
}

MessageEvent? _latestThreadReplacementFor(
  MessageEvent original,
  List<MessageEvent>? candidates,
) {
  if (candidates == null) return null;
  final matching = candidates.where(
    (candidate) => candidate.sender == original.sender,
  );
  if (matching.isEmpty) return null;
  return matching.reduce(
    (latest, candidate) =>
        candidate.timestamp > latest.timestamp ? candidate : latest,
  );
}

MessageEvent _applyThreadReplacement(
  MessageEvent original,
  MessageEvent? replacement,
) {
  if (replacement == null ||
      replacement.sender != original.sender ||
      (original.editedAt ?? -1) >= replacement.timestamp) {
    return original;
  }
  return MessageEvent(
    eventId: original.eventId,
    roomId: original.roomId,
    sender: original.sender,
    body: replacement.body,
    formattedBody: replacement.formattedBody,
    msgtype: replacement.msgtype,
    timestamp: original.timestamp,
    inReplyTo: original.inReplyTo,
    threadRoot: original.threadRoot,
    replacesEventId: original.replacesEventId,
    redactsEventId: original.redactsEventId,
    editedAt: replacement.timestamp,
    mxcUri: replacement.mxcUri,
    mediaSource: replacement.mediaSource,
    filename: replacement.filename,
    fileSize: replacement.fileSize,
  );
}

MessageEvent _deletedThreadRoot(MessageEvent root) => MessageEvent(
  eventId: root.eventId,
  roomId: root.roomId,
  sender: root.sender,
  body: 'Message deleted',
  msgtype: 'm.notice',
  timestamp: root.timestamp,
);

final threadTimelineProvider = AsyncNotifierProvider.autoDispose
    .family<ThreadTimelineController, ThreadTimeline, ThreadKey>(
      ThreadTimelineController.new,
    );

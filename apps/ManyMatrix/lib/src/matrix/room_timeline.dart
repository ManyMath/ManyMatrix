import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';

import 'bridge_service.dart';
import 'providers.dart';

/// Immutable snapshot of one room's paginated timeline.
///
/// [newestFirst] matches a `ListView(reverse: true)`: index 0 is the newest
/// message, the end of the list is the oldest loaded message.
class RoomTimeline {
  const RoomTimeline({
    required this.newestFirst,
    this.endToken,
    this.loadingOlder = false,
    this.olderError,
    this.reactionsByEventId = const <String, List<ReactionEvent>>{},
    this.receiptsByEventId = const <String, List<ReceiptEvent>>{},
  });

  final List<MessageEvent> newestFirst;

  /// Pagination token for fetching older history; null when exhausted.
  final String? endToken;

  /// True while a load-older request is in flight.
  final bool loadingOlder;

  /// Most recent backward-pagination failure, retained for an inline retry.
  final Object? olderError;

  /// Reaction events keyed by the message event ID they annotate.
  final Map<String, List<ReactionEvent>> reactionsByEventId;

  /// Read receipt events keyed by the message event ID they mark as read.
  final Map<String, List<ReceiptEvent>> receiptsByEventId;

  bool get canLoadOlder => endToken != null && !loadingOlder;

  /// Timeline entries that belong to the room's main timeline.
  ///
  /// Matrix thread replies are still retained in [newestFirst] so they can be
  /// shown inside a thread view, but they should not render as top-level chat
  /// messages.
  List<MessageEvent> get mainNewestFirst => newestFirst
      .where((message) => message.threadRoot == null)
      .toList(growable: false);

  List<MessageEvent> threadMessagesNewestFirst(String threadRootId) =>
      newestFirst
          .where(
            (message) =>
                message.eventId == threadRootId ||
                message.threadRoot == threadRootId,
          )
          .toList(growable: false);

  int threadReplyCount(String threadRootId) =>
      newestFirst.where((message) => message.threadRoot == threadRootId).length;

  List<ReactionEvent> reactionsFor(String eventId) =>
      reactionsByEventId[eventId] ?? const <ReactionEvent>[];

  List<ReceiptEvent> receiptsFor(String eventId) =>
      receiptsByEventId[eventId] ?? const <ReceiptEvent>[];

  RoomTimeline copyWith({
    List<MessageEvent>? newestFirst,
    String? endToken,
    bool clearEndToken = false,
    bool? loadingOlder,
    Object? olderError,
    bool clearOlderError = false,
    Map<String, List<ReactionEvent>>? reactionsByEventId,
    Map<String, List<ReceiptEvent>>? receiptsByEventId,
  }) => RoomTimeline(
    newestFirst: newestFirst ?? this.newestFirst,
    endToken: clearEndToken ? null : (endToken ?? this.endToken),
    loadingOlder: loadingOlder ?? this.loadingOlder,
    olderError: clearOlderError ? null : (olderError ?? this.olderError),
    reactionsByEventId: reactionsByEventId ?? this.reactionsByEventId,
    receiptsByEventId: receiptsByEventId ?? this.receiptsByEventId,
  );
}

/// Per-room timeline: initial page, older pages on demand, live appends.
class RoomTimelineController
    extends AutoDisposeFamilyAsyncNotifier<RoomTimeline, String> {
  static const _pageSize = 50;
  static const _maxEmptyPageHops = 8;
  static const _maxReadReceiptAttempts = 3;
  static const _readReceiptRetryDelays = <Duration>[
    Duration(milliseconds: 200),
    Duration(milliseconds: 600),
  ];
  String? _committedReadReceiptEventId;
  String? _pendingReadReceiptEventId;
  String? _readRetryEventId;
  Timer? _readRetryTimer;
  int _readAttempt = 0;
  int _readRequest = 0;
  int _generation = 0;
  int _readyGeneration = 0;
  final _pendingLive = <MessageEvent>[];
  final _pendingReplacements = <String, List<MessageEvent>>{};
  final _pendingRedactions = <String>{};
  final _reactionsByEventId = <String, List<ReactionEvent>>{};
  final _receiptsByEventId = <String, List<ReceiptEvent>>{};

  @override
  Future<RoomTimeline> build(String roomId) async {
    final generation = ++_generation;
    _readyGeneration = 0;
    _pendingLive.clear();
    _pendingReplacements.clear();
    _pendingRedactions.clear();
    _committedReadReceiptEventId = null;
    _pendingReadReceiptEventId = null;
    _clearReadRetry();
    _reactionsByEventId.clear();
    _receiptsByEventId.clear();
    final service = ref.watch(matrixServiceProvider);

    final messageSubscription = service.messageEvents
        .where((event) => event.roomId == roomId)
        .listen((event) {
          if (generation != _generation) return;
          if (_readyGeneration != generation) {
            _pendingLive.add(event);
          } else {
            _appendLive(event);
          }
        });
    final reactionSubscription = service.reactionEvents
        .where((event) => event.roomId == roomId)
        .listen(_applyReaction);
    final receiptSubscription = service.receiptEvents
        .where((event) => event.roomId == roomId)
        .listen(_applyReceipt);
    ref.onDispose(() {
      _generation += 1;
      _readyGeneration = 0;
      _pendingLive.clear();
      _pendingReplacements.clear();
      _pendingRedactions.clear();
      _clearReadRetry();
      unawaited(messageSubscription.cancel());
      unawaited(reactionSubscription.cancel());
      unawaited(receiptSubscription.cancel());
    });

    final page = await service.getMessages(roomId, limit: _pageSize);
    if (generation != _generation) {
      return const RoomTimeline(newestFirst: <MessageEvent>[]);
    }
    // getMessages returns oldest -> newest; the UI wants newest at index 0.
    final pendingAtSnapshot = List<MessageEvent>.from(_pendingLive);
    _pendingLive.clear();
    final initialPage = _mergeChronologicalPage(
      const <MessageEvent>[],
      page.messages,
      _pendingReplacements,
      _pendingRedactions,
    );
    final timeline = RoomTimeline(
      newestFirst: _mergeLiveMessages(
        initialPage.newestFirst,
        pendingAtSnapshot,
        _pendingReplacements,
        _pendingRedactions,
      ),
      endToken: page.endToken,
      reactionsByEventId: _reactionSnapshot(),
      receiptsByEventId: _receiptSnapshot(),
    );
    state = AsyncData(timeline);
    _readyGeneration = generation;
    final arrivedDuringInstall = List<MessageEvent>.from(_pendingLive);
    _pendingLive.clear();
    for (final event in arrivedDuringInstall) {
      _appendLive(event);
    }
    final installed = state.valueOrNull ?? timeline;
    _markNewestRead(installed);
    return installed;
  }

  /// Appends a just-sent message immediately; the sync callback's copy is
  /// deduplicated by event ID if it arrives later.
  void addLocalEcho(MessageEvent event) => _appendLive(event);

  void applyLocalEdit({
    required String eventId,
    required String body,
    required int editedAt,
  }) {
    final timeline = state.valueOrNull;
    if (timeline == null || _readyGeneration != _generation) return;
    final index = timeline.newestFirst.indexWhere(
      (message) => message.eventId == eventId,
    );
    if (index == -1) return;
    final current = timeline.newestFirst[index];
    final next = <MessageEvent>[...timeline.newestFirst];
    next[index] = _editedMessage(current, body: body, editedAt: editedAt);
    state = AsyncData(timeline.copyWith(newestFirst: next));
  }

  void removeLocal(String eventId) {
    final timeline = state.valueOrNull;
    if (timeline == null || _readyGeneration != _generation) return;
    final target = timeline.newestFirst
        .where((message) => message.eventId == eventId)
        .firstOrNull;
    final keepThreadRoot =
        target != null &&
        target.threadRoot == null &&
        timeline.threadReplyCount(eventId) > 0;
    state = AsyncData(
      timeline.copyWith(
        newestFirst: <MessageEvent>[
          for (final message in timeline.newestFirst)
            if (message.eventId != eventId)
              message
            else if (keepThreadRoot)
              _redactedRoomMessage(message),
        ],
      ),
    );
  }

  void _appendLive(MessageEvent event) {
    if (_readyGeneration != _generation) {
      _pendingLive.add(event);
      return;
    }
    final timeline = state.valueOrNull;
    if (timeline == null) return;
    final redactedTarget = event.redactsEventId;
    if (redactedTarget != null) {
      _pendingRedactions.add(redactedTarget);
      _pendingReplacements.remove(redactedTarget);
      state = AsyncData(
        timeline.copyWith(
          newestFirst: <MessageEvent>[
            for (final message in timeline.newestFirst)
              if (message.eventId != redactedTarget)
                message
              else if (message.threadRoot == null)
                _redactedRoomMessage(message),
          ],
        ),
      );
      return;
    }
    if (event.replacesEventId != null) {
      final targetEventId = event.replacesEventId!;
      final targetLoaded = timeline.newestFirst.any(
        (message) => message.eventId == targetEventId,
      );
      final replaced = _applyReplacement(timeline.newestFirst, event);
      if (!targetLoaded) {
        _retainLatestReplacement(_pendingReplacements, event);
      }
      if (!identical(replaced, timeline.newestFirst)) {
        state = AsyncData(timeline.copyWith(newestFirst: replaced));
      }
      _sendReadReceipt(event);
      return;
    }
    final displayed = _applyPendingReplacement(event, _pendingReplacements);
    final duplicateIndex = timeline.newestFirst.indexWhere(
      (message) => message.eventId == event.eventId,
    );
    if (duplicateIndex != -1) {
      final next = <MessageEvent>[...timeline.newestFirst];
      next[duplicateIndex] = displayed;
      state = AsyncData(timeline.copyWith(newestFirst: next));
      _sendReadReceipt(event);
      return;
    }
    state = AsyncData(
      timeline.copyWith(newestFirst: [displayed, ...timeline.newestFirst]),
    );
    _sendReadReceipt(event);
  }

  /// Fetches the next-older page and appends it to the end of the timeline.
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
        final page = await service.getMessages(
          arg,
          fromToken: requestToken,
          limit: _pageSize,
        );
        if (generation != _generation ||
            !identical(ref.read(matrixServiceProvider), service)) {
          return;
        }
        final current = state.valueOrNull ?? timeline;
        if (!current.loadingOlder || current.endToken != requestToken) return;

        final merged = _mergeChronologicalPage(
          current.newestFirst,
          page.messages,
          _pendingReplacements,
          _pendingRedactions,
        );
        final nextToken = page.endToken;
        final madeProgress = nextToken != null && nextToken != requestToken;
        final shouldContinue =
            merged.addedMainCount == 0 &&
            madeProgress &&
            hop + 1 < _maxEmptyPageHops;
        final updated = current.copyWith(
          newestFirst: merged.newestFirst,
          endToken: nextToken,
          clearEndToken: nextToken == null,
          loadingOlder: shouldContinue,
          clearOlderError: true,
          reactionsByEventId: _reactionSnapshot(),
          receiptsByEventId: _receiptSnapshot(),
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
      final current = state.valueOrNull ?? timeline;
      state = AsyncData(
        current.copyWith(loadingOlder: false, olderError: error),
      );
    }
  }

  void _applyReaction(ReactionEvent event) {
    final existing =
        _reactionsByEventId[event.relatesToEventId] ?? const <ReactionEvent>[];
    if (existing.any((reaction) => reaction.eventId == event.eventId)) return;
    _reactionsByEventId[event.relatesToEventId] = <ReactionEvent>[
      ...existing,
      event,
    ];
    final timeline = state.valueOrNull;
    if (timeline == null || _readyGeneration != _generation) return;
    state = AsyncData(
      timeline.copyWith(reactionsByEventId: _reactionSnapshot()),
    );
  }

  void _applyReceipt(ReceiptEvent event) {
    for (final entry in _receiptsByEventId.entries.toList()) {
      final remaining = entry.value
          .where(
            (receipt) =>
                receipt.userId != event.userId ||
                receipt.receiptType != event.receiptType ||
                receipt.threadId != event.threadId,
          )
          .toList();
      if (remaining.isEmpty) {
        _receiptsByEventId.remove(entry.key);
      } else {
        _receiptsByEventId[entry.key] = remaining;
      }
    }

    final existing =
        _receiptsByEventId[event.eventId] ?? const <ReceiptEvent>[];
    _receiptsByEventId[event.eventId] = <ReceiptEvent>[...existing, event];
    final timeline = state.valueOrNull;
    if (timeline == null || _readyGeneration != _generation) return;
    state = AsyncData(timeline.copyWith(receiptsByEventId: _receiptSnapshot()));
  }

  Map<String, List<ReactionEvent>> _reactionSnapshot() {
    return Map<String, List<ReactionEvent>>.unmodifiable(
      _reactionsByEventId.map(
        (eventId, reactions) =>
            MapEntry(eventId, List<ReactionEvent>.unmodifiable(reactions)),
      ),
    );
  }

  Map<String, List<ReceiptEvent>> _receiptSnapshot() {
    return Map<String, List<ReceiptEvent>>.unmodifiable(
      _receiptsByEventId.map(
        (eventId, receipts) =>
            MapEntry(eventId, List<ReceiptEvent>.unmodifiable(receipts)),
      ),
    );
  }

  void _markNewestRead(RoomTimeline timeline) {
    for (final event in timeline.newestFirst) {
      if (event.threadRoot == null &&
          event.replacesEventId == null &&
          event.redactsEventId == null) {
        _sendReadReceipt(event);
        return;
      }
    }
  }

  void _sendReadReceipt(MessageEvent event) {
    // Main-timeline receipts must never advance from a hidden thread relation.
    // ThreadTimelineController owns receipts scoped to a thread root.
    if (event.threadRoot != null ||
        event.replacesEventId != null ||
        event.redactsEventId != null ||
        _committedReadReceiptEventId == event.eventId ||
        _pendingReadReceiptEventId == event.eventId) {
      return;
    }
    final service = ref.read(matrixServiceProvider);
    if (_readRetryEventId != event.eventId) {
      _clearReadRetry();
      _readRetryEventId = event.eventId;
    } else {
      _readRetryTimer?.cancel();
      _readRetryTimer = null;
    }
    _readAttempt += 1;
    _pendingReadReceiptEventId = event.eventId;
    final generation = _generation;
    final request = ++_readRequest;
    unawaited(
      _persistReadReceipt(
        service,
        event,
        generation: generation,
        request: request,
      ),
    );
  }

  Future<void> _persistReadReceipt(
    MatrixService service,
    MessageEvent event, {
    required int generation,
    required int request,
  }) async {
    try {
      await service.sendReadReceipt(event.roomId, event.eventId);
      if (generation != _generation ||
          request != _readRequest ||
          !identical(ref.read(matrixServiceProvider), service)) {
        return;
      }
      _pendingReadReceiptEventId = null;
      _committedReadReceiptEventId = event.eventId;
      _clearReadRetry();
      unawaited(ref.read(roomListProvider.notifier).refresh());
    } on Object {
      if (generation != _generation || request != _readRequest) return;
      _pendingReadReceiptEventId = null;
      if (!identical(ref.read(matrixServiceProvider), service) ||
          _readRetryEventId != event.eventId ||
          _readAttempt >= _maxReadReceiptAttempts) {
        return;
      }
      final delay = _readReceiptRetryDelays[_readAttempt - 1];
      _readRetryTimer = Timer(delay, () {
        _readRetryTimer = null;
        if (generation == _generation &&
            _readRetryEventId == event.eventId &&
            _pendingReadReceiptEventId == null &&
            _committedReadReceiptEventId != event.eventId) {
          _sendReadReceipt(event);
        }
      });
    }
  }

  void _clearReadRetry() {
    _readRetryTimer?.cancel();
    _readRetryTimer = null;
    _readRetryEventId = null;
    _readAttempt = 0;
  }
}

class _PageMerge {
  const _PageMerge({required this.newestFirst, required this.addedMainCount});

  final List<MessageEvent> newestFirst;
  final int addedMainCount;
}

_PageMerge _mergeChronologicalPage(
  List<MessageEvent> currentNewestFirst,
  List<MessageEvent> oldestFirst,
  Map<String, List<MessageEvent>> pendingReplacements,
  Set<String> pendingRedactions,
) {
  var current = currentNewestFirst;
  final older = <MessageEvent>[];
  final olderIndexByEventId = <String, int>{};
  final currentIndexByEventId = <String, int>{
    for (var index = 0; index < current.length; index += 1)
      current[index].eventId: index,
  };
  for (final event in oldestFirst) {
    if (event.redactsEventId != null) {
      pendingRedactions.add(event.redactsEventId!);
      pendingReplacements.remove(event.redactsEventId);
      continue;
    }
    final targetEventId = event.replacesEventId;
    if (targetEventId != null) {
      final olderIndex = olderIndexByEventId[targetEventId];
      if (olderIndex != null) {
        older[olderIndex] = _messageWithReplacement(older[olderIndex], event);
      } else {
        final currentIndex = currentIndexByEventId[targetEventId];
        if (currentIndex != null) {
          final replacement = _messageWithReplacement(
            current[currentIndex],
            event,
          );
          if (!identical(replacement, current[currentIndex])) {
            current = <MessageEvent>[...current];
            current[currentIndex] = replacement;
          }
        } else {
          _retainLatestReplacement(pendingReplacements, event);
        }
      }
      continue;
    }

    if (pendingRedactions.contains(event.eventId)) {
      if (event.threadRoot == null) {
        final currentIndex = currentIndexByEventId[event.eventId];
        if (currentIndex != null) {
          current = <MessageEvent>[...current];
          current[currentIndex] = _redactedRoomMessage(current[currentIndex]);
        } else if (!olderIndexByEventId.containsKey(event.eventId)) {
          olderIndexByEventId[event.eventId] = older.length;
          older.add(_redactedRoomMessage(event));
        }
      }
      continue;
    }

    final currentIndex = currentIndexByEventId[event.eventId];
    if (currentIndex != null) {
      final displayed = _applyPendingReplacement(
        current[currentIndex],
        pendingReplacements,
      );
      if (!identical(displayed, current[currentIndex])) {
        current = <MessageEvent>[...current];
        current[currentIndex] = displayed;
      }
      continue;
    }
    if (olderIndexByEventId.containsKey(event.eventId)) continue;
    olderIndexByEventId[event.eventId] = older.length;
    older.add(_applyPendingReplacement(event, pendingReplacements));
  }
  return _PageMerge(
    newestFirst: <MessageEvent>[...current, ...older.reversed],
    addedMainCount: older.where((message) => message.threadRoot == null).length,
  );
}

List<MessageEvent> _mergeLiveMessages(
  List<MessageEvent> newestFirst,
  List<MessageEvent> liveEvents,
  Map<String, List<MessageEvent>> pendingReplacements,
  Set<String> pendingRedactions,
) {
  var merged = <MessageEvent>[...newestFirst];
  for (final event in liveEvents) {
    final redactedTarget = event.redactsEventId;
    if (redactedTarget != null) {
      pendingRedactions.add(redactedTarget);
      pendingReplacements.remove(redactedTarget);
      merged = <MessageEvent>[
        for (final message in merged)
          if (message.eventId != redactedTarget)
            message
          else if (message.threadRoot == null)
            _redactedRoomMessage(message),
      ];
      continue;
    }
    if (event.replacesEventId != null) {
      final targetLoaded = merged.any(
        (message) => message.eventId == event.replacesEventId,
      );
      final replaced = _applyReplacement(merged, event);
      if (!targetLoaded) {
        _retainLatestReplacement(pendingReplacements, event);
      }
      merged = replaced;
      continue;
    }
    if (pendingRedactions.contains(event.eventId)) {
      if (event.threadRoot == null) {
        merged.removeWhere((message) => message.eventId == event.eventId);
        merged.insert(0, _redactedRoomMessage(event));
      }
      continue;
    }
    merged.removeWhere((message) => message.eventId == event.eventId);
    merged.insert(0, _applyPendingReplacement(event, pendingReplacements));
  }
  return merged;
}

void _retainLatestReplacement(
  Map<String, List<MessageEvent>> pendingReplacements,
  MessageEvent replacement,
) {
  final targetEventId = replacement.replacesEventId;
  if (targetEventId == null) return;
  final candidates = pendingReplacements.putIfAbsent(
    targetEventId,
    () => <MessageEvent>[],
  );
  final existingIndex = candidates.indexWhere(
    (candidate) => candidate.sender == replacement.sender,
  );
  if (existingIndex == -1) {
    candidates.add(replacement);
  } else if (replacement.timestamp > candidates[existingIndex].timestamp) {
    candidates[existingIndex] = replacement;
  }
}

MessageEvent _applyPendingReplacement(
  MessageEvent original,
  Map<String, List<MessageEvent>> pendingReplacements,
) {
  final candidates = pendingReplacements.remove(original.eventId);
  if (candidates == null) return original;
  final matching = candidates.where(
    (candidate) => candidate.sender == original.sender,
  );
  if (matching.isEmpty) return original;
  final replacement = matching.reduce(
    (latest, candidate) =>
        candidate.timestamp > latest.timestamp ? candidate : latest,
  );
  return _messageWithReplacement(original, replacement);
}

List<MessageEvent> _applyReplacement(
  List<MessageEvent> newestFirst,
  MessageEvent replacement,
) {
  final targetEventId = replacement.replacesEventId;
  if (targetEventId == null) return newestFirst;
  final index = newestFirst.indexWhere(
    (message) => message.eventId == targetEventId,
  );
  if (index == -1) return newestFirst;
  final displayed = _messageWithReplacement(newestFirst[index], replacement);
  if (identical(displayed, newestFirst[index])) return newestFirst;
  final next = <MessageEvent>[...newestFirst];
  next[index] = displayed;
  return next;
}

MessageEvent _messageWithReplacement(
  MessageEvent original,
  MessageEvent replacement,
) {
  if (original.sender != replacement.sender) return original;
  if (original.editedAt != null &&
      original.editedAt! >= replacement.timestamp) {
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
    editedAt: replacement.timestamp,
  );
}

MessageEvent _editedMessage(
  MessageEvent original, {
  required String body,
  required int editedAt,
}) {
  return MessageEvent(
    eventId: original.eventId,
    roomId: original.roomId,
    sender: original.sender,
    body: body,
    msgtype: 'm.text',
    timestamp: original.timestamp,
    inReplyTo: original.inReplyTo,
    threadRoot: original.threadRoot,
    editedAt: editedAt,
  );
}

MessageEvent _redactedRoomMessage(MessageEvent original) => MessageEvent(
  eventId: original.eventId,
  roomId: original.roomId,
  sender: original.sender,
  body: 'Message deleted',
  msgtype: 'm.notice',
  timestamp: original.timestamp,
  inReplyTo: original.inReplyTo,
  threadRoot: original.threadRoot,
);

final roomTimelineProvider = AsyncNotifierProvider.autoDispose
    .family<RoomTimelineController, RoomTimeline, String>(
      RoomTimelineController.new,
    );

import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';

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
    this.reactionsByEventId = const <String, List<ReactionEvent>>{},
    this.receiptsByEventId = const <String, List<ReceiptEvent>>{},
  });

  final List<MessageEvent> newestFirst;

  /// Pagination token for fetching older history; null when exhausted.
  final String? endToken;

  /// True while a load-older request is in flight.
  final bool loadingOlder;

  /// Reaction events keyed by the message event ID they annotate.
  final Map<String, List<ReactionEvent>> reactionsByEventId;

  /// Read receipt events keyed by the message event ID they mark as read.
  final Map<String, List<ReceiptEvent>> receiptsByEventId;

  bool get canLoadOlder => endToken != null && !loadingOlder;

  List<ReactionEvent> reactionsFor(String eventId) =>
      reactionsByEventId[eventId] ?? const <ReactionEvent>[];

  List<ReceiptEvent> receiptsFor(String eventId) =>
      receiptsByEventId[eventId] ?? const <ReceiptEvent>[];

  RoomTimeline copyWith({
    List<MessageEvent>? newestFirst,
    String? endToken,
    bool clearEndToken = false,
    bool? loadingOlder,
    Map<String, List<ReactionEvent>>? reactionsByEventId,
    Map<String, List<ReceiptEvent>>? receiptsByEventId,
  }) => RoomTimeline(
    newestFirst: newestFirst ?? this.newestFirst,
    endToken: clearEndToken ? null : (endToken ?? this.endToken),
    loadingOlder: loadingOlder ?? this.loadingOlder,
    reactionsByEventId: reactionsByEventId ?? this.reactionsByEventId,
    receiptsByEventId: receiptsByEventId ?? this.receiptsByEventId,
  );
}

/// Per-room timeline: initial page, older pages on demand, live appends.
class RoomTimelineController
    extends AutoDisposeFamilyAsyncNotifier<RoomTimeline, String> {
  static const _pageSize = 50;
  String? _lastReadReceiptEventId;
  final _reactionsByEventId = <String, List<ReactionEvent>>{};
  final _receiptsByEventId = <String, List<ReceiptEvent>>{};

  @override
  Future<RoomTimeline> build(String roomId) async {
    final service = ref.watch(matrixServiceProvider);

    final messageSubscription = service.messageEvents
        .where((event) => event.roomId == roomId)
        .listen(_appendLive);
    final reactionSubscription = service.reactionEvents
        .where((event) => event.roomId == roomId)
        .listen(_applyReaction);
    final receiptSubscription = service.receiptEvents
        .where((event) => event.roomId == roomId)
        .listen(_applyReceipt);
    ref.onDispose(() {
      unawaited(messageSubscription.cancel());
      unawaited(reactionSubscription.cancel());
      unawaited(receiptSubscription.cancel());
    });

    final page = await service.getMessages(roomId, limit: _pageSize);
    // getMessages returns oldest -> newest; the UI wants newest at index 0.
    final timeline = RoomTimeline(
      newestFirst: _newestFirstWithReplacements(page.messages),
      endToken: page.endToken,
      reactionsByEventId: _reactionSnapshot(),
      receiptsByEventId: _receiptSnapshot(),
    );
    _markNewestRead(timeline);
    return timeline;
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
    if (timeline == null) return;
    final index = timeline.newestFirst.indexWhere(
      (message) => message.eventId == eventId,
    );
    if (index == -1) return;
    final current = timeline.newestFirst[index];
    final next = <MessageEvent>[...timeline.newestFirst];
    next[index] = _editedMessage(current, body: body, editedAt: editedAt);
    state = AsyncData(timeline.copyWith(newestFirst: next));
  }

  void _appendLive(MessageEvent event) {
    final timeline = state.valueOrNull;
    if (timeline == null) return;
    if (event.replacesEventId != null) {
      final replaced = _applyReplacement(timeline.newestFirst, event);
      if (identical(replaced, timeline.newestFirst)) return;
      state = AsyncData(timeline.copyWith(newestFirst: replaced));
      _sendReadReceipt(event);
      return;
    }
    if (timeline.newestFirst.any((m) => m.eventId == event.eventId)) return;
    state = AsyncData(
      timeline.copyWith(newestFirst: [event, ...timeline.newestFirst]),
    );
    _sendReadReceipt(event);
  }

  /// Fetches the next-older page and appends it to the end of the timeline.
  Future<void> loadOlder() async {
    final timeline = state.valueOrNull;
    if (timeline == null || !timeline.canLoadOlder) return;
    state = AsyncData(timeline.copyWith(loadingOlder: true));
    try {
      final page = await ref
          .read(matrixServiceProvider)
          .getMessages(arg, fromToken: timeline.endToken, limit: _pageSize);
      final current = state.valueOrNull ?? timeline;
      final known = current.newestFirst.map((m) => m.eventId).toSet();
      final older = _newestFirstWithReplacements(
        page.messages,
      ).where((m) => !known.contains(m.eventId)).toList();
      state = AsyncData(
        current.copyWith(
          newestFirst: [...current.newestFirst, ...older],
          endToken: page.endToken,
          clearEndToken: page.messages.isEmpty,
          loadingOlder: false,
          reactionsByEventId: _reactionSnapshot(),
          receiptsByEventId: _receiptSnapshot(),
        ),
      );
    } on Object {
      final current = state.valueOrNull ?? timeline;
      state = AsyncData(current.copyWith(loadingOlder: false));
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
    if (timeline == null) return;
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
                receipt.receiptType != event.receiptType,
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
    if (timeline == null) return;
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
    if (timeline.newestFirst.isEmpty) return;
    _sendReadReceipt(timeline.newestFirst.first);
  }

  void _sendReadReceipt(MessageEvent event) {
    if (event.eventId == _lastReadReceiptEventId) return;
    _lastReadReceiptEventId = event.eventId;
    unawaited(
      ref
          .read(matrixServiceProvider)
          .sendReadReceipt(event.roomId, event.eventId)
          .catchError((_) {}),
    );
  }
}

List<MessageEvent> _newestFirstWithReplacements(
  List<MessageEvent> oldestFirst,
) {
  final messages = <MessageEvent>[];
  final indexByEventId = <String, int>{};
  for (final event in oldestFirst) {
    final targetEventId = event.replacesEventId;
    if (targetEventId != null) {
      final index = indexByEventId[targetEventId];
      if (index != null) {
        messages[index] = _messageWithReplacement(messages[index], event);
      }
      continue;
    }
    indexByEventId[event.eventId] = messages.length;
    messages.add(event);
  }
  return messages.reversed.toList();
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
  final next = <MessageEvent>[...newestFirst];
  next[index] = _messageWithReplacement(next[index], replacement);
  return next;
}

MessageEvent _messageWithReplacement(
  MessageEvent original,
  MessageEvent replacement,
) {
  if (original.sender != replacement.sender) return original;
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

final roomTimelineProvider = AsyncNotifierProvider.autoDispose
    .family<RoomTimelineController, RoomTimeline, String>(
      RoomTimelineController.new,
    );

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
  });

  final List<MessageEvent> newestFirst;

  /// Pagination token for fetching older history; null when exhausted.
  final String? endToken;

  /// True while a load-older request is in flight.
  final bool loadingOlder;

  bool get canLoadOlder => endToken != null && !loadingOlder;

  RoomTimeline copyWith({
    List<MessageEvent>? newestFirst,
    String? endToken,
    bool clearEndToken = false,
    bool? loadingOlder,
  }) =>
      RoomTimeline(
        newestFirst: newestFirst ?? this.newestFirst,
        endToken: clearEndToken ? null : (endToken ?? this.endToken),
        loadingOlder: loadingOlder ?? this.loadingOlder,
      );
}

/// Per-room timeline: initial page, older pages on demand, live appends.
class RoomTimelineController
    extends AutoDisposeFamilyAsyncNotifier<RoomTimeline, String> {
  static const _pageSize = 50;

  @override
  Future<RoomTimeline> build(String roomId) async {
    final service = ref.watch(matrixServiceProvider);

    final subscription = service.messageEvents
        .where((event) => event.roomId == roomId)
        .listen(_appendLive);
    ref.onDispose(subscription.cancel);

    final page = await service.getMessages(roomId, limit: _pageSize);
    // getMessages returns oldest -> newest; the UI wants newest at index 0.
    return RoomTimeline(
      newestFirst: page.messages.reversed.toList(),
      endToken: page.endToken,
    );
  }

  /// Appends a just-sent message immediately; the sync callback's copy is
  /// deduplicated by event ID if it arrives later.
  void addLocalEcho(MessageEvent event) => _appendLive(event);

  void _appendLive(MessageEvent event) {
    final timeline = state.valueOrNull;
    if (timeline == null) return;
    if (timeline.newestFirst.any((m) => m.eventId == event.eventId)) return;
    state = AsyncData(
      timeline.copyWith(
        newestFirst: [event, ...timeline.newestFirst],
      ),
    );
  }

  /// Fetches the next-older page and appends it to the end of the timeline.
  Future<void> loadOlder() async {
    final timeline = state.valueOrNull;
    if (timeline == null || !timeline.canLoadOlder) return;
    state = AsyncData(timeline.copyWith(loadingOlder: true));
    try {
      final page = await ref.read(matrixServiceProvider).getMessages(
            arg,
            fromToken: timeline.endToken,
            limit: _pageSize,
          );
      final known = timeline.newestFirst.map((m) => m.eventId).toSet();
      final older = page.messages.reversed
          .where((m) => !known.contains(m.eventId))
          .toList();
      state = AsyncData(
        RoomTimeline(
          newestFirst: [...timeline.newestFirst, ...older],
          endToken: page.messages.isEmpty ? null : page.endToken,
        ),
      );
    } on Object {
      state = AsyncData(timeline.copyWith(loadingOlder: false));
    }
  }
}

final roomTimelineProvider = AsyncNotifierProvider.autoDispose
    .family<RoomTimelineController, RoomTimeline, String>(
  RoomTimelineController.new,
);

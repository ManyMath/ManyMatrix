import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';
import 'package:manyui_hooks/manyui_hooks.dart';
import 'package:manymatrix/manymatrix.dart';

import '../matrix/account.dart';
import '../matrix/bridge_service.dart';
import '../matrix/providers.dart';
import '../matrix/room_timeline.dart';
import '../matrix/thread_timeline.dart';
import '../matrix/matrix_display.dart';
import '../room_info/room_info_page.dart';
import 'attachment_io.dart';
import 'invite_dialog.dart';
import 'message_bubble.dart';

const double _timelineMaxWidth = 920;
const EdgeInsets _timelinePadding = EdgeInsets.fromLTRB(20, 12, 20, 12);

/// Full-screen chat route used by the narrow layout.
class ChatPage extends ConsumerWidget {
  const ChatPage({required this.roomId, required this.roomName, super.key});

  final String roomId;
  final String roomName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MScaffold(
      header: MAppHeader(
        title: roomName,
        leading: MIconButton(
          icon: MIconData.chevronLeft,
          label: 'Back to rooms',
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: <Widget>[
          MIconButton(
            icon: MIconData.users,
            label: 'Invite to room',
            onPressed: () => showInviteDialog(context, ref, roomId: roomId),
          ),
          MIconButton(
            icon: MIconData.info,
            label: 'Room info',
            onPressed: () => Navigator.of(context).push(
              PageRouteBuilder<void>(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    RoomInfoPage(roomId: roomId, roomName: roomName),
              ),
            ),
          ),
        ],
      ),
      body: ChatView(roomId: roomId),
    );
  }
}

/// Room timeline plus composer. Embeddable: the wide layout hosts it as the
/// right-hand pane, [ChatPage] wraps it for narrow push navigation.
class ChatView extends HookConsumerWidget {
  const ChatView({
    required this.roomId,
    this.showRoomHeader = false,
    super.key,
  });

  final String roomId;

  /// When true, renders the room name above the timeline (used by the
  /// two-pane layout, where there is no page header for the room).
  final bool showRoomHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = MTheme.of(context);
    final route = ModalRoute.of(context);
    useListenable(route?.secondaryAnimation);
    final routeIsCurrent = route?.secondaryAnimation?.isDismissed ?? true;
    final timeline = ref.watch(roomTimelineProvider(roomId));
    final timelineData = timeline.valueOrNull;
    final currentUserId = ref.watch(currentUserIdProvider);
    final scrollController = useScrollController();
    final composeTarget = useState<_ComposeTarget?>(null);
    final selectedThread = useState<ThreadKey?>(null);
    final visibilityRevision = useRef(0);
    final requestedThread = ref.watch(requestedThreadProvider);
    final threadIndexState = ref.watch(threadIndexProvider);
    final threadIndexStale = ref.watch(threadIndexStaleProvider);
    final threadIndex = threadIndexState.valueOrNull;
    // Built once per index change; the timeline looks threads up per message.
    final roomThreadsByRoot = useMemoized(() {
      final byRoot = <String, ThreadSummary>{};
      for (final thread in threadIndex ?? const <ThreadSummary>[]) {
        if (thread.roomId != roomId) continue;
        byRoot.putIfAbsent(thread.root.eventId, () => thread);
      }
      return byRoot;
    }, [threadIndex, roomId]);
    final selectedThreadKey = selectedThread.value?.roomId == roomId
        ? selectedThread.value
        : null;
    final selectedThreadTimeline = selectedThreadKey == null
        ? null
        : ref.watch(threadTimelineProvider(selectedThreadKey)).valueOrNull;

    void selectThread(String rootEventId) {
      final next = ThreadKey(roomId: roomId, rootEventId: rootEventId);
      final previous = selectedThread.value;
      if (previous != null && previous != next) {
        ref.read(threadVisibilityProvider(previous).notifier).state = false;
      }
      ref.read(threadVisibilityProvider(next).notifier).state = routeIsCurrent;
      selectedThread.value = next;
    }

    useEffect(() {
      final previous = selectedThread.value;
      if (previous != null && previous.roomId != roomId) {
        final visibility = ref.read(
          threadVisibilityProvider(previous).notifier,
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (visibility.mounted) visibility.state = false;
        });
      }
      composeTarget.value = null;
      selectedThread.value = null;
      return null;
    }, [roomId]);

    useEffect(() {
      final key = selectedThreadKey;
      if (key == null) return null;
      final visibility = ref.read(threadVisibilityProvider(key).notifier);
      final revision = ++visibilityRevision.value;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted ||
            !visibility.mounted ||
            visibilityRevision.value != revision) {
          return;
        }
        visibility.state = routeIsCurrent;
      });
      return () {
        // Hook cleanup runs during route rebuild/disposal, when Riverpod
        // rejects synchronous provider writes. A newer effect advances the
        // revision before this microtask and therefore owns the final state.
        scheduleMicrotask(() {
          if (!visibility.mounted || visibilityRevision.value != revision) {
            return;
          }
          visibilityRevision.value += 1;
          visibility.state = false;
        });
      };
    }, [selectedThreadKey, routeIsCurrent]);

    useEffect(() {
      if (requestedThread == null || requestedThread.roomId != roomId) {
        return null;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        selectThread(requestedThread.rootEventId);
        composeTarget.value = null;
        if (ref.read(requestedThreadProvider) == requestedThread) {
          ref.read(requestedThreadProvider.notifier).state = null;
        }
      });
      return null;
    }, [requestedThread, roomId]);

    // Load older history when the user scrolls near the (visual) top --
    // with a reversed list that is the max scroll extent.
    useEffect(() {
      void onScroll() {
        if (!scrollController.hasClients) return;
        final position = scrollController.position;
        if (position.pixels >= position.maxScrollExtent - 240) {
          ref.read(roomTimelineProvider(roomId).notifier).loadOlder();
        }
      }

      scrollController.addListener(onScroll);
      return () => scrollController.removeListener(onScroll);
    }, [scrollController, roomId]);

    String? roomName;
    if (showRoomHeader) {
      roomName = ref
          .watch(roomListProvider)
          .valueOrNull
          ?.where((room) => room.roomId == roomId)
          .map((room) => room.displayName)
          .firstOrNull;
    }

    String threadRootIdFor(MessageEvent message) =>
        message.threadRoot ?? message.eventId;

    void openThreadById(String rootEventId) {
      selectThread(rootEventId);
      composeTarget.value = null;
    }

    void openThread(MessageEvent message) =>
        openThreadById(threadRootIdFor(message));

    void replyInThread(MessageEvent message) {
      selectThread(threadRootIdFor(message));
      composeTarget.value = _ComposeTarget.thread(message);
    }

    MessageEvent? selectedThreadRootMessage() {
      final data = timelineData;
      final rootId = selectedThreadKey?.rootEventId;
      if (rootId == null) return null;
      if (data != null) {
        for (final message in data.newestFirst) {
          if (message.eventId == rootId) return message;
        }
      }
      return selectedThreadTimeline?.root;
    }

    final defaultThreadTarget = selectedThreadRootMessage();
    final activeComposeTarget =
        composeTarget.value ??
        (defaultThreadTarget == null
            ? null
            : _ComposeTarget.thread(defaultThreadTarget));
    final threadOpen = selectedThreadKey != null;
    final compactThread = threadOpen && MediaQuery.sizeOf(context).width < 720;

    void closeThread() {
      final key = selectedThread.value;
      if (key != null) {
        ref.read(threadVisibilityProvider(key).notifier).state = false;
      }
      selectedThread.value = null;
      composeTarget.value = null;
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (showRoomHeader) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: MSectionHeader(
              title: roomName ?? roomId,
              titleStyle: theme.typography.title,
              titleMaxLines: 1,
              actions: <Widget>[
                MIconButton(
                  icon: MIconData.users,
                  label: 'Invite to room',
                  onPressed: () =>
                      showInviteDialog(context, ref, roomId: roomId),
                ),
                MIconButton(
                  icon: MIconData.info,
                  label: 'Room info',
                  onPressed: () => Navigator.of(context).push(
                    PageRouteBuilder<void>(
                      pageBuilder: (context, animation, secondaryAnimation) =>
                          RoomInfoPage(
                            roomId: roomId,
                            roomName: roomName ?? roomId,
                          ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(height: 1, color: theme.colors.border),
        ],
        if (!compactThread)
          Expanded(
            child: timeline.when(
              loading: () => const Center(
                child: MLoadingState(message: 'Loading messages'),
              ),
              error: (error, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: MAlert(
                    title: 'Messages unavailable',
                    variant: MAlertVariant.destructive,
                    message: 'Could not load messages: $error',
                    maxWidth: 420,
                    actions: <Widget>[
                      MButton(
                        variant: MButtonVariant.outline,
                        size: MButtonSize.sm,
                        onPressed: () =>
                            ref.invalidate(roomTimelineProvider(roomId)),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
              data: (data) {
                final mainMessages = data.mainNewestFirst;
                if (mainMessages.isEmpty) {
                  if (data.olderError != null) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: MAlert(
                          title: 'Older messages unavailable',
                          variant: MAlertVariant.destructive,
                          message:
                              'The newest page contains thread replies only. '
                              'Could not load the earlier conversation.',
                          maxWidth: 420,
                          actions: <Widget>[
                            MButton(
                              variant: MButtonVariant.outline,
                              size: MButtonSize.sm,
                              onPressed: () => ref
                                  .read(roomTimelineProvider(roomId).notifier)
                                  .loadOlder(),
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  if (data.canLoadOlder) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!context.mounted) return;
                      final current = ref
                          .read(roomTimelineProvider(roomId))
                          .valueOrNull;
                      if (current != null &&
                          current.mainNewestFirst.isEmpty &&
                          current.canLoadOlder) {
                        unawaited(
                          ref
                              .read(roomTimelineProvider(roomId).notifier)
                              .loadOlder(),
                        );
                      }
                    });
                    return const Center(
                      child: MLoadingState(message: 'Loading conversation'),
                    );
                  }
                  if (data.loadingOlder) {
                    return const Center(
                      child: MLoadingState(message: 'Loading conversation'),
                    );
                  }
                  return const Center(
                    child: MEmptyState(
                      title: 'No messages yet',
                      description: 'Say hi to start the conversation.',
                    ),
                  );
                }
                final loadedReplyCounts = <String, int>{};
                for (final message in data.newestFirst) {
                  final root = message.threadRoot;
                  if (root == null) continue;
                  loadedReplyCounts[root] = (loadedReplyCounts[root] ?? 0) + 1;
                }
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final laneWidth = constraints.maxWidth < _timelineMaxWidth
                        ? constraints.maxWidth
                        : _timelineMaxWidth;

                    // reverse: true puts index 0 (newest) at the bottom.
                    return Center(
                      child: SizedBox(
                        width: laneWidth,
                        height: constraints.maxHeight,
                        child: ListView.builder(
                          controller: scrollController,
                          reverse: true,
                          padding: _timelinePadding,
                          itemCount:
                              mainMessages.length +
                              (data.loadingOlder || data.olderError != null
                                  ? 1
                                  : 0),
                          itemBuilder: (context, index) {
                            if (index >= mainMessages.length) {
                              if (data.olderError != null) {
                                return Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: MAlert(
                                    message: 'Could not load older messages.',
                                    actions: <Widget>[
                                      MButton(
                                        variant: MButtonVariant.outline,
                                        size: MButtonSize.sm,
                                        onPressed: () => ref
                                            .read(
                                              roomTimelineProvider(
                                                roomId,
                                              ).notifier,
                                            )
                                            .loadOlder(),
                                        child: const Text('Retry'),
                                      ),
                                    ],
                                  ),
                                );
                              }
                              return const Padding(
                                padding: EdgeInsets.all(12),
                                child: Center(
                                  child: MCircularProgress.indeterminate(
                                    semanticLabel: 'Loading older messages',
                                  ),
                                ),
                              );
                            }
                            final message = mainMessages[index];
                            final isMine =
                                currentUserId != null &&
                                message.sender == currentUserId;
                            final indexedThread =
                                roomThreadsByRoot[message.eventId];
                            final loadedThreadReplyCount =
                                loadedReplyCounts[message.eventId] ?? 0;
                            final threadReplyCount = indexedThread == null
                                ? loadedThreadReplyCount
                                : indexedThread.replyCount >
                                      loadedThreadReplyCount
                                ? indexedThread.replyCount
                                : loadedThreadReplyCount;
                            return MessageBubble(
                              key: ValueKey(message.eventId),
                              message: message,
                              isMine: isMine,
                              threadReplyCount: threadReplyCount,
                              threadUnreadCount:
                                  indexedThread?.unreadCount ?? 0,
                              threadUnreadKnown:
                                  threadIndexState
                                      is AsyncData<List<ThreadSummary>> &&
                                  !threadIndexStale &&
                                  indexedThread?.unreadCount != null,
                              reactions: data.reactionsFor(message.eventId),
                              receipts: isMine
                                  ? data
                                        .receiptsFor(message.eventId)
                                        .where(
                                          (receipt) =>
                                              receipt.userId != currentUserId &&
                                              (receipt.threadId == null ||
                                                  receipt.threadId == 'main'),
                                        )
                                        .toList()
                                  : const <ReceiptEvent>[],
                              onReply: () => composeTarget.value =
                                  _ComposeTarget.reply(message),
                              onEdit: isMine && message.msgtype == 'm.text'
                                  ? () => composeTarget.value =
                                        _ComposeTarget.edit(message)
                                  : null,
                              onOpenThread: () => openThread(message),
                              onThreadReply: () => replyInThread(message),
                            );
                          },
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        if (selectedThreadKey != null)
          Expanded(
            child: _ThreadPanel(
              roomId: roomId,
              rootId: selectedThreadKey.rootEventId,
              timeline: timelineData,
              currentUserId: currentUserId,
              onClose: closeThread,
              onReply: replyInThread,
              onEdit: (message) =>
                  composeTarget.value = _ComposeTarget.edit(message),
              onThreadReply: replyInThread,
            ),
          ),
        Container(height: 1, color: theme.colors.border),
        if (!threadOpen || activeComposeTarget != null)
          _Composer(
            roomId: roomId,
            target: activeComposeTarget,
            keepTargetAfterSend:
                activeComposeTarget?.kind == _ComposeTargetKind.thread,
            onClearTarget: () {
              if (composeTarget.value != null) {
                composeTarget.value = null;
              } else {
                closeThread();
              }
            },
          )
        else
          const Padding(
            padding: EdgeInsets.all(12),
            child: MLoadingState(message: 'Loading thread composer'),
          ),
      ],
    );
    return PopScope(
      canPop: !threadOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && threadOpen) closeThread();
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): closeThread,
        },
        child: Focus(autofocus: threadOpen, child: content),
      ),
    );
  }
}

class _ThreadPanel extends ConsumerWidget {
  const _ThreadPanel({
    required this.roomId,
    required this.rootId,
    required this.timeline,
    required this.currentUserId,
    required this.onClose,
    required this.onReply,
    required this.onEdit,
    required this.onThreadReply,
  });

  final String roomId;
  final String rootId;
  final RoomTimeline? timeline;
  final String? currentUserId;
  final VoidCallback onClose;
  final ValueChanged<MessageEvent> onReply;
  final ValueChanged<MessageEvent> onEdit;
  final ValueChanged<MessageEvent> onThreadReply;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = MTheme.of(context);
    final key = ThreadKey(roomId: roomId, rootEventId: rootId);
    final remote = ref.watch(threadTimelineProvider(key));
    final messages = _mergeThreadPanelMessages(
      rootId: rootId,
      loadedTimeline: timeline,
      remoteTimeline: remote.valueOrNull,
    );
    final replyCount = messages
        .where((message) => message.eventId != rootId)
        .length;
    final authoritativeReplyCount = ref
        .watch(threadIndexProvider)
        .valueOrNull
        ?.where(
          (thread) => thread.roomId == roomId && thread.root.eventId == rootId,
        )
        .firstOrNull
        ?.replyCount;
    final totalReplyCount =
        authoritativeReplyCount != null && authoritativeReplyCount > replyCount
        ? authoritativeReplyCount
        : replyCount;
    final replyCountLabel = totalReplyCount == replyCount
        ? '$totalReplyCount ${totalReplyCount == 1 ? 'reply' : 'replies'}'
        : '$totalReplyCount replies, $replyCount loaded';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colors.background,
        border: Border(top: BorderSide(color: theme.colors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _timelineMaxWidth),
            child: SizedBox(
              height: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  MSectionHeader(
                    title: 'Thread - $replyCountLabel',
                    titleMaxLines: 1,
                    actions: <Widget>[
                      MIconButton(
                        icon: MIconData.close,
                        label: 'Close thread',
                        size: MButtonSize.sm,
                        onPressed: onClose,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: messages.isEmpty
                        ? remote.when(
                            loading: () => const Center(
                              child: MLoadingState(message: 'Loading thread'),
                            ),
                            error: (error, _) => Padding(
                              padding: const EdgeInsets.all(12),
                              child: MAlert(
                                title: 'Thread history unavailable',
                                variant: MAlertVariant.destructive,
                                message:
                                    'Loaded room messages remain usable. Could not fetch the complete thread: $error',
                                actions: <Widget>[
                                  MButton(
                                    variant: MButtonVariant.outline,
                                    size: MButtonSize.sm,
                                    onPressed: () => ref.invalidate(
                                      threadTimelineProvider(key),
                                    ),
                                    child: const Text('Retry'),
                                  ),
                                ],
                              ),
                            ),
                            data: (_) => const Padding(
                              padding: EdgeInsets.all(12),
                              child: MEmptyState(
                                title: 'No replies yet',
                                description: 'Write the first reply below.',
                              ),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            reverse: true,
                            itemCount:
                                messages.length +
                                (remote.hasError ||
                                        remote.valueOrNull?.canLoadOlder ==
                                            true ||
                                        remote.valueOrNull?.loadingOlder ==
                                            true ||
                                        remote.valueOrNull?.olderError != null
                                    ? 1
                                    : 0),
                            itemBuilder: (context, index) {
                              if (index >= messages.length) {
                                final remoteTimeline = remote.valueOrNull;
                                if (remote.hasError) {
                                  return Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: MAlert(
                                      message:
                                          'Could not fetch the complete thread.',
                                      actions: <Widget>[
                                        MButton(
                                          variant: MButtonVariant.outline,
                                          size: MButtonSize.sm,
                                          onPressed: () => ref.invalidate(
                                            threadTimelineProvider(key),
                                          ),
                                          child: const Text('Retry'),
                                        ),
                                      ],
                                    ),
                                  );
                                }
                                if (remoteTimeline?.loadingOlder == true) {
                                  return const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: Center(
                                      child: MCircularProgress.indeterminate(
                                        semanticLabel:
                                            'Loading older thread replies',
                                      ),
                                    ),
                                  );
                                }
                                return Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: MButton(
                                    variant: MButtonVariant.ghost,
                                    size: MButtonSize.sm,
                                    onPressed: () => ref
                                        .read(
                                          threadTimelineProvider(key).notifier,
                                        )
                                        .loadOlder(),
                                    child: Text(
                                      remoteTimeline?.olderError == null
                                          ? 'Load older replies'
                                          : 'Retry older replies',
                                    ),
                                  ),
                                );
                              }
                              final message = messages[index];
                              final isMine =
                                  currentUserId != null &&
                                  message.sender == currentUserId;
                              return MessageBubble(
                                key: ValueKey(message.eventId),
                                message: message,
                                isMine: isMine,
                                reactions:
                                    timeline?.reactionsFor(message.eventId) ??
                                    const <ReactionEvent>[],
                                receipts: isMine
                                    ? (timeline?.receiptsFor(message.eventId) ??
                                              const <ReceiptEvent>[])
                                          .where(
                                            (receipt) =>
                                                receipt.userId !=
                                                    currentUserId &&
                                                receipt.threadId == rootId,
                                          )
                                          .toList()
                                    : const <ReceiptEvent>[],
                                onReply: () => onReply(message),
                                onEdit: isMine && message.msgtype == 'm.text'
                                    ? () => onEdit(message)
                                    : null,
                                onThreadReply: () => onThreadReply(message),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

List<MessageEvent> _mergeThreadPanelMessages({
  required String rootId,
  required RoomTimeline? loadedTimeline,
  required ThreadTimeline? remoteTimeline,
}) {
  final byEventId = <String, MessageEvent>{};
  for (final message in remoteTimeline?.newestFirst ?? const <MessageEvent>[]) {
    byEventId[message.eventId] = message;
  }
  if (remoteTimeline != null) {
    byEventId[remoteTimeline.root.eventId] = remoteTimeline.root;
  }
  final remoteOrder = <String>[
    for (final message in remoteTimeline?.newestFirst ?? const <MessageEvent>[])
      message.eventId,
  ];
  final roomOnly = <String>[];
  // Prefer room-timeline copies for live edits/local echoes while retaining
  // the server relation order for events present in both sources.
  for (final message
      in loadedTimeline?.threadMessagesNewestFirst(rootId) ??
          const <MessageEvent>[]) {
    if (remoteTimeline?.redactedEventIds.contains(message.eventId) == true) {
      continue;
    }
    if (!byEventId.containsKey(message.eventId) && message.eventId != rootId) {
      roomOnly.add(message.eventId);
    }
    final remote = byEventId[message.eventId];
    if (remote == null || (message.editedAt ?? -1) > (remote.editedAt ?? -1)) {
      byEventId[message.eventId] = message;
    }
  }
  final orderedReplyIds = <String>[
    for (final eventId in remoteOrder)
      if (eventId != rootId && byEventId[eventId] != null) eventId,
  ];
  // Preserve the server relation order, but place room-only history at its
  // timestamp position. A live/local echo naturally lands first without an
  // older room-timeline reply jumping ahead of the authoritative page.
  for (final eventId in roomOnly) {
    final message = byEventId[eventId];
    if (message == null) continue;
    var insertAt = orderedReplyIds.length;
    for (var index = 0; index < orderedReplyIds.length; index += 1) {
      final ordered = byEventId[orderedReplyIds[index]];
      if (ordered != null && message.timestamp > ordered.timestamp) {
        insertAt = index;
        break;
      }
    }
    orderedReplyIds.insert(insertAt, eventId);
  }
  final replies = <MessageEvent>[
    for (final eventId in orderedReplyIds) byEventId[eventId]!,
  ];
  final root = byEventId[rootId];
  return <MessageEvent>[...replies, if (root != null) root];
}

enum _ComposeTargetKind { reply, edit, thread }

enum _ComposerMode {
  text('Text', 'm.text'),
  notice('Notice', 'm.notice'),
  emote('Emote', 'm.emote'),
  html('HTML', 'm.text');

  const _ComposerMode(this.label, this.msgtype);

  final String label;
  final String msgtype;
}

class _ComposeTarget {
  const _ComposeTarget._({required this.kind, required this.message});

  const _ComposeTarget.reply(MessageEvent message)
    : this._(kind: _ComposeTargetKind.reply, message: message);

  const _ComposeTarget.edit(MessageEvent message)
    : this._(kind: _ComposeTargetKind.edit, message: message);

  const _ComposeTarget.thread(MessageEvent message)
    : this._(kind: _ComposeTargetKind.thread, message: message);

  final _ComposeTargetKind kind;
  final MessageEvent message;

  String get threadRootId => message.threadRoot ?? message.eventId;

  String get modeLabel => switch (kind) {
    _ComposeTargetKind.reply => 'Replying to',
    _ComposeTargetKind.edit => 'Editing',
    _ComposeTargetKind.thread => 'Thread reply to',
  };

  String get sendFailureLabel => switch (kind) {
    _ComposeTargetKind.reply => 'Reply failed',
    _ComposeTargetKind.edit => 'Edit failed',
    _ComposeTargetKind.thread => 'Thread reply failed',
  };

  String get preview {
    final compact = message.body.trim().replaceAll(RegExp(r'\s+'), ' ');
    final text = compact.isEmpty ? message.msgtype : compact;
    if (text.length <= 80) return text;
    return '${text.substring(0, 77)}...';
  }
}

class _Composer extends HookConsumerWidget {
  const _Composer({
    required this.roomId,
    required this.target,
    required this.keepTargetAfterSend,
    required this.onClearTarget,
  });

  final String roomId;
  final _ComposeTarget? target;
  final bool keepTargetAfterSend;
  final VoidCallback onClearTarget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeAccountId = ref.watch(activeAccountIdProvider);
    final targetKey = target == null
        ? null
        : '${target!.kind.name}:${target!.message.eventId}';
    final operationScope = useMemoized(Object.new, <Object?>[
      roomId,
      activeAccountId,
      targetKey,
    ]);
    final currentOperationScope = useRef<Object>(operationScope);
    currentOperationScope.value = operationScope;
    final initialDraft = target?.kind == _ComposeTargetKind.edit
        ? target!.message.body
        : '';
    final controller = useMController<String>(initialDraft, [
      roomId,
      targetKey,
    ]);
    final htmlController = useMController<String>('', [roomId]);
    final mode = useState(_ComposerMode.text);
    final messageOptionsOpen = useState(false);
    final sending = useState(false);
    final uploading = useState(false);
    final sendError = useState<String?>(null);
    final draft = useValueListenable(controller);
    final htmlDraft = useValueListenable(htmlController);
    final typingTimer = useRef<Timer?>(null);

    bool operationIsCurrent(MatrixService service, Object scope) {
      if (!context.mounted || !identical(currentOperationScope.value, scope)) {
        return false;
      }
      if (ref.read(activeAccountIdProvider) != activeAccountId) return false;
      return identical(ref.read(matrixServiceProvider), service);
    }

    useEffect(() {
      typingTimer.value?.cancel();
      sending.value = false;
      uploading.value = false;
      sendError.value = null;
      return null;
    }, <Object?>[operationScope]);
    useEffect(
      () =>
          () => typingTimer.value?.cancel(),
      const [],
    );

    void clearTarget() {
      if (target?.kind == _ComposeTargetKind.edit) {
        controller.value = '';
      }
      onClearTarget();
    }

    void onChanged(String text) {
      if (text.isEmpty) return;
      final service = ref.read(matrixServiceProvider);
      final scope = operationScope;
      unawaited(service.sendTyping(roomId, true).catchError((_) {}));
      typingTimer.value?.cancel();
      typingTimer.value = Timer(const Duration(seconds: 3), () {
        if (!operationIsCurrent(service, scope)) return;
        unawaited(service.sendTyping(roomId, false).catchError((_) {}));
      });
    }

    Future<void> send() async {
      final body = draft.trim();
      if (body.isEmpty || sending.value) return;
      final composeMode = target == null ? mode.value : _ComposerMode.text;
      final htmlBody = htmlDraft.trim();
      if (composeMode == _ComposerMode.html && htmlBody.isEmpty) {
        sendError.value = 'Send failed: HTML body is required';
        return;
      }
      sending.value = true;
      sendError.value = null;
      final service = ref.read(matrixServiceProvider);
      final scope = operationScope;
      final composeTarget = target;
      try {
        if (composeTarget?.kind == _ComposeTargetKind.edit) {
          await service.editMessage(
            roomId,
            composeTarget!.message.eventId,
            body,
          );
          if (!operationIsCurrent(service, scope)) return;
          final editedAt = DateTime.now().millisecondsSinceEpoch;
          ref
              .read(roomTimelineProvider(roomId).notifier)
              .applyLocalEdit(
                eventId: composeTarget.message.eventId,
                body: body,
                editedAt: editedAt,
              );
          typingTimer.value?.cancel();
          unawaited(service.sendTyping(roomId, false).catchError((_) {}));
          controller.value = '';
          onClearTarget();
          return;
        }
        final eventId = switch (composeTarget?.kind) {
          _ComposeTargetKind.reply => await service.replyTo(
            roomId,
            composeTarget!.message.eventId,
            body,
          ),
          _ComposeTargetKind.edit => throw StateError('edit handled earlier'),
          _ComposeTargetKind.thread => await service.sendThreadReply(
            roomId,
            composeTarget!.threadRootId,
            body,
            inReplyToEventId: composeTarget.message.eventId,
          ),
          null => switch (composeMode) {
            _ComposerMode.text => await service.sendText(roomId, body),
            _ComposerMode.notice => await service.sendNotice(roomId, body),
            _ComposerMode.emote => await service.sendEmote(roomId, body),
            _ComposerMode.html => await service.sendHtml(
              roomId,
              body,
              htmlBody,
            ),
          },
        };
        if (!operationIsCurrent(service, scope)) return;
        typingTimer.value?.cancel();
        unawaited(service.sendTyping(roomId, false).catchError((_) {}));
        controller.value = '';
        htmlController.value = '';
        if (!keepTargetAfterSend) {
          onClearTarget();
        }
        final sender = service.currentUserId;
        if (sender != null) {
          final localEcho = MessageEvent(
            eventId: eventId,
            roomId: roomId,
            sender: sender,
            body: body,
            formattedBody: composeMode == _ComposerMode.html ? htmlBody : null,
            msgtype: composeMode.msgtype,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            inReplyTo: composeTarget?.message.eventId,
            threadRoot: composeTarget?.kind == _ComposeTargetKind.thread
                ? composeTarget?.threadRootId
                : null,
          );
          ref
              .read(roomTimelineProvider(roomId).notifier)
              .addLocalEcho(localEcho);
          if (localEcho.threadRoot != null) {
            ref.read(threadIndexProvider.notifier).rememberReply(localEcho);
          }
        }
      } on Object catch (error) {
        if (operationIsCurrent(service, scope)) {
          sendError.value =
              '${composeTarget?.sendFailureLabel ?? 'Send failed'}: $error';
        }
      } finally {
        if (operationIsCurrent(service, scope)) sending.value = false;
      }
    }

    Future<void> attachFile() async {
      if (sending.value || uploading.value) return;
      sendError.value = null;
      final scope = operationScope;
      MatrixService? service;
      try {
        final attachment = await ref.read(attachmentPickerProvider)();
        if (!context.mounted ||
            !identical(currentOperationScope.value, scope) ||
            ref.read(activeAccountIdProvider) != activeAccountId) {
          return;
        }
        if (attachment == null) return;
        ensureAttachmentSize(attachment.data.length);
        uploading.value = true;
        final uploadService = ref.read(matrixServiceProvider);
        service = uploadService;
        final eventId = await uploadService.uploadMedia(
          roomId,
          attachment.filename,
          attachment.mimeType,
          attachment.data,
        );
        if (!operationIsCurrent(uploadService, scope)) return;
        final sender = uploadService.currentUserId;
        if (sender != null) {
          ref
              .read(roomTimelineProvider(roomId).notifier)
              .addLocalEcho(
                MessageEvent(
                  eventId: eventId,
                  roomId: roomId,
                  sender: sender,
                  body: attachment.filename,
                  msgtype: attachmentMessageType(attachment.mimeType),
                  timestamp: DateTime.now().millisecondsSinceEpoch,
                  filename: attachment.filename,
                  fileSize: attachment.data.length,
                ),
              );
        }
      } on Object catch (error) {
        if (context.mounted &&
            identical(currentOperationScope.value, scope) &&
            ref.read(activeAccountIdProvider) == activeAccountId &&
            (service == null || operationIsCurrent(service, scope))) {
          sendError.value = 'Attachment failed: $error';
        }
      } finally {
        if (context.mounted &&
            identical(currentOperationScope.value, scope) &&
            ref.read(activeAccountIdProvider) == activeAccountId) {
          uploading.value = false;
        }
      }
    }

    final composeMode = target == null ? mode.value : _ComposerMode.text;
    final canSend =
        draft.trim().isNotEmpty &&
        (composeMode != _ComposerMode.html || htmlDraft.trim().isNotEmpty);

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (target != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ComposeTargetBanner(
                target: target!,
                onClear: clearTarget,
              ),
            ),
          if (sendError.value != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: MAlert(
                variant: MAlertVariant.destructive,
                message: sendError.value!,
              ),
            ),
          if (target == null &&
              (messageOptionsOpen.value || mode.value != _ComposerMode.text))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: MSegmentedControl<_ComposerMode>(
                value: mode.value,
                enabled: !sending.value,
                size: MButtonSize.xs,
                fullWidth: true,
                onChanged: (value) {
                  mode.value = value;
                  messageOptionsOpen.value = value != _ComposerMode.text;
                },
                items: <MSegmentedItem<_ComposerMode>>[
                  for (final option in _ComposerMode.values)
                    MSegmentedItem<_ComposerMode>(
                      value: option,
                      label: option.label,
                      semanticLabel: '${option.label} message type',
                    ),
                ],
              ),
            ),
          if (target == null && mode.value == _ComposerMode.html)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: MTextField(
                controller: htmlController,
                placeholder: 'HTML markup',
                semanticLabel: 'HTML message body',
                enabled: !sending.value,
                minLines: 2,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              if (target == null) ...<Widget>[
                MIconButton(
                  icon: MIconData.attachment,
                  label: 'Attach file',
                  onPressed: sending.value || uploading.value
                      ? null
                      : attachFile,
                ),
                const SizedBox(width: 8),
              ],
              if (target == null &&
                  mode.value == _ComposerMode.text) ...<Widget>[
                MIconButton(
                  icon: MIconData.moreHorizontal,
                  label: messageOptionsOpen.value
                      ? 'Hide message options'
                      : 'Message options',
                  onPressed: sending.value
                      ? null
                      : () => messageOptionsOpen.value =
                            !messageOptionsOpen.value,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: MTextField(
                  controller: controller,
                  placeholder: switch (target?.kind) {
                    _ComposeTargetKind.edit => 'Edit message...',
                    _ComposeTargetKind.reply ||
                    _ComposeTargetKind.thread => 'Write a reply...',
                    null =>
                      mode.value == _ComposerMode.html
                          ? 'Plain-text fallback'
                          : 'Write a message',
                  },
                  semanticLabel: mode.value == _ComposerMode.html
                      ? 'Plain-text message fallback'
                      : 'Message',
                  enabled: !sending.value,
                  minLines: 1,
                  maxLines: 5,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  onChanged: onChanged,
                ),
              ),
              const SizedBox(width: 8),
              if (sending.value || uploading.value)
                const MButton(
                  onPressed: null,
                  style: MButtonStyleDelta(
                    padding: EdgeInsets.zero,
                    minHeight: 36,
                  ),
                  child: SizedBox.square(
                    dimension: 36,
                    child: Center(
                      child: SizedBox.square(
                        dimension: 16,
                        child: MCircularProgress.indeterminate(
                          semanticLabel: 'Sending',
                        ),
                      ),
                    ),
                  ),
                )
              else
                MIconButton(
                  icon: target?.kind == _ComposeTargetKind.edit
                      ? MIconData.check
                      : MIconData.arrowUp,
                  label: target?.kind == _ComposeTargetKind.edit
                      ? 'Save edit'
                      : 'Send message',
                  variant: MButtonVariant.primary,
                  onPressed: canSend ? send : null,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ComposeTargetBanner extends StatelessWidget {
  const _ComposeTargetBanner({required this.target, required this.onClear});

  final _ComposeTarget target;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = MTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colors.muted,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '${target.modeLabel} '
                    '${matrixUserDisplayName(target.message.sender)}',
                    style: theme.typography.label.copyWith(
                      color: theme.colors.foreground,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    target.preview,
                    style: theme.typography.caption.copyWith(
                      color: theme.colors.mutedForeground,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            MIconButton(
              icon: MIconData.close,
              label: 'Cancel compose target',
              size: MButtonSize.sm,
              onPressed: onClear,
            ),
          ],
        ),
      ),
    );
  }
}

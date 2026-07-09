import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';
import 'package:manyui_hooks/manyui_hooks.dart';
import 'package:manymatrix/manymatrix.dart';

import '../matrix/providers.dart';
import '../matrix/room_timeline.dart';
import '../room_info/room_info_page.dart';
import 'invite_dialog.dart';
import 'message_bubble.dart';

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
        leading: MButton(
          variant: MButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
          semanticLabel: 'Back to rooms',
          child: const Text('Back'),
        ),
        actions: <Widget>[
          MButton(
            variant: MButtonVariant.ghost,
            onPressed: () => showInviteDialog(context, ref, roomId: roomId),
            semanticLabel: 'Invite to room',
            child: const Text('Invite'),
          ),
          MButton(
            variant: MButtonVariant.ghost,
            onPressed: () => Navigator.of(context).push(
              PageRouteBuilder<void>(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    RoomInfoPage(roomId: roomId, roomName: roomName),
              ),
            ),
            semanticLabel: 'Room info',
            child: const Text('Info'),
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
    final timeline = ref.watch(roomTimelineProvider(roomId));
    final currentUserId = ref.watch(currentUserIdProvider);
    final scrollController = useScrollController();
    final composeTarget = useState<_ComposeTarget?>(null);

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

    return Column(
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
                MButton(
                  variant: MButtonVariant.ghost,
                  onPressed: () =>
                      showInviteDialog(context, ref, roomId: roomId),
                  semanticLabel: 'Invite to room',
                  child: const Text('Invite'),
                ),
                MButton(
                  variant: MButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).push(
                    PageRouteBuilder<void>(
                      pageBuilder: (context, animation, secondaryAnimation) =>
                          RoomInfoPage(
                            roomId: roomId,
                            roomName: roomName ?? roomId,
                          ),
                    ),
                  ),
                  semanticLabel: 'Room info',
                  child: const Text('Info'),
                ),
              ],
            ),
          ),
          Container(height: 1, color: theme.colors.border),
        ],
        Expanded(
          child: timeline.when(
            loading: () =>
                const Center(child: MLoadingState(message: 'Loading messages')),
            error: (error, _) => Center(
              child: MAlert(
                variant: MAlertVariant.destructive,
                message: 'Could not load messages: $error',
                maxWidth: 420,
              ),
            ),
            data: (data) {
              if (data.newestFirst.isEmpty) {
                return const Center(
                  child: MEmptyState(
                    title: 'No messages yet',
                    description: 'Say hi to start the conversation.',
                  ),
                );
              }
              // reverse: true puts index 0 (newest) at the bottom.
              return ListView.builder(
                controller: scrollController,
                reverse: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount:
                    data.newestFirst.length + (data.loadingOlder ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= data.newestFirst.length) {
                    return const Padding(
                      padding: EdgeInsets.all(12),
                      child: Center(
                        child: MCircularProgress.indeterminate(
                          semanticLabel: 'Loading older messages',
                        ),
                      ),
                    );
                  }
                  final message = data.newestFirst[index];
                  final isMine =
                      currentUserId != null && message.sender == currentUserId;
                  return MessageBubble(
                    message: message,
                    isMine: isMine,
                    reactions: data.reactionsFor(message.eventId),
                    receipts: isMine
                        ? data
                              .receiptsFor(message.eventId)
                              .where(
                                (receipt) => receipt.userId != currentUserId,
                              )
                              .toList()
                        : const <ReceiptEvent>[],
                    onReply: () =>
                        composeTarget.value = _ComposeTarget.reply(message),
                    onThreadReply: () =>
                        composeTarget.value = _ComposeTarget.thread(message),
                  );
                },
              );
            },
          ),
        ),
        Container(height: 1, color: theme.colors.border),
        _Composer(
          roomId: roomId,
          target: composeTarget.value,
          onClearTarget: () => composeTarget.value = null,
        ),
      ],
    );
  }
}

enum _ComposeTargetKind { reply, thread }

class _ComposeTarget {
  const _ComposeTarget._({required this.kind, required this.message});

  const _ComposeTarget.reply(MessageEvent message)
    : this._(kind: _ComposeTargetKind.reply, message: message);

  const _ComposeTarget.thread(MessageEvent message)
    : this._(kind: _ComposeTargetKind.thread, message: message);

  final _ComposeTargetKind kind;
  final MessageEvent message;

  String get threadRootId => message.threadRoot ?? message.eventId;

  String get modeLabel => switch (kind) {
    _ComposeTargetKind.reply => 'Replying to',
    _ComposeTargetKind.thread => 'Thread reply to',
  };

  String get sendFailureLabel => switch (kind) {
    _ComposeTargetKind.reply => 'Reply failed',
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
    required this.onClearTarget,
  });

  final String roomId;
  final _ComposeTarget? target;
  final VoidCallback onClearTarget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useMController<String>('', [roomId]);
    final sending = useState(false);
    final sendError = useState<String?>(null);
    final typingTimer = useRef<Timer?>(null);
    useEffect(
      () =>
          () => typingTimer.value?.cancel(),
      const [],
    );

    void onChanged(String text) {
      if (text.isEmpty) return;
      final service = ref.read(matrixServiceProvider);
      unawaited(service.sendTyping(roomId, true).catchError((_) {}));
      typingTimer.value?.cancel();
      typingTimer.value = Timer(const Duration(seconds: 3), () {
        unawaited(service.sendTyping(roomId, false).catchError((_) {}));
      });
    }

    Future<void> send() async {
      final body = controller.value.trim();
      if (body.isEmpty || sending.value) return;
      sending.value = true;
      sendError.value = null;
      final service = ref.read(matrixServiceProvider);
      final composeTarget = target;
      try {
        final eventId = switch (composeTarget?.kind) {
          _ComposeTargetKind.reply => await service.replyTo(
            roomId,
            composeTarget!.message.eventId,
            body,
          ),
          _ComposeTargetKind.thread => await service.sendThreadReply(
            roomId,
            composeTarget!.threadRootId,
            body,
          ),
          null => await service.sendText(roomId, body),
        };
        typingTimer.value?.cancel();
        unawaited(service.sendTyping(roomId, false).catchError((_) {}));
        controller.value = '';
        onClearTarget();
        final sender = service.currentUserId;
        if (sender != null) {
          ref
              .read(roomTimelineProvider(roomId).notifier)
              .addLocalEcho(
                MessageEvent(
                  eventId: eventId,
                  roomId: roomId,
                  sender: sender,
                  body: body,
                  msgtype: 'm.text',
                  timestamp: DateTime.now().millisecondsSinceEpoch,
                  inReplyTo: composeTarget?.message.eventId,
                  threadRoot: composeTarget?.kind == _ComposeTargetKind.thread
                      ? composeTarget?.threadRootId
                      : null,
                ),
              );
        }
      } on Object catch (error) {
        sendError.value =
            '${composeTarget?.sendFailureLabel ?? 'Send failed'}: $error';
      } finally {
        sending.value = false;
      }
    }

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
                onClear: onClearTarget,
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
          Row(
            children: <Widget>[
              Expanded(
                child: MTextField(
                  controller: controller,
                  placeholder: target == null ? 'Message…' : 'Write a reply…',
                  semanticLabel: 'Message',
                  enabled: !sending.value,
                  onChanged: onChanged,
                  onSubmitted: (_) => send(),
                ),
              ),
              const SizedBox(width: 8),
              MButton(
                onPressed: sending.value ? null : send,
                child: Text(sending.value ? 'Sending…' : 'Send'),
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
                    '${target.modeLabel} ${target.message.sender}',
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
            MButton(
              variant: MButtonVariant.ghost,
              size: MButtonSize.sm,
              style: const MButtonStyleDelta(minHeight: 40),
              onPressed: onClear,
              semanticLabel: 'Cancel compose target',
              child: const MIcon(MIconData.close, size: 16),
            ),
          ],
        ),
      ),
    );
  }
}

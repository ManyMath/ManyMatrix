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
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    roomName ?? roomId,
                    style: theme.typography.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                MButton(
                  variant: MButtonVariant.ghost,
                  onPressed: () =>
                      showInviteDialog(context, ref, roomId: roomId),
                  semanticLabel: 'Invite to room',
                  child: const Text('Invite'),
                ),
                const SizedBox(width: 8),
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
            loading: () => const Center(
              child: MCircularProgress.indeterminate(
                semanticLabel: 'Loading messages',
              ),
            ),
            error: (error, _) => Center(
              child: Text(
                'Could not load messages: $error',
                style: theme.typography.bodySmall.copyWith(
                  color: theme.colors.destructive,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            data: (data) {
              if (data.newestFirst.isEmpty) {
                return Center(
                  child: Text(
                    'No messages yet — say hi!',
                    style: theme.typography.body.copyWith(
                      color: theme.colors.mutedForeground,
                    ),
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
                  );
                },
              );
            },
          ),
        ),
        Container(height: 1, color: theme.colors.border),
        _Composer(roomId: roomId),
      ],
    );
  }
}

class _Composer extends HookConsumerWidget {
  const _Composer({required this.roomId});

  final String roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = MTheme.of(context);
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
      try {
        final eventId = await service.sendText(roomId, body);
        typingTimer.value?.cancel();
        unawaited(service.sendTyping(roomId, false).catchError((_) {}));
        controller.value = '';
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
                ),
              );
        }
      } on Object catch (error) {
        sendError.value = 'Send failed: $error';
      } finally {
        sending.value = false;
      }
    }

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (sendError.value != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                sendError.value!,
                style: theme.typography.bodySmall.copyWith(
                  color: theme.colors.destructive,
                ),
              ),
            ),
          Row(
            children: <Widget>[
              Expanded(
                child: MTextField(
                  controller: controller,
                  placeholder: 'Message…',
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

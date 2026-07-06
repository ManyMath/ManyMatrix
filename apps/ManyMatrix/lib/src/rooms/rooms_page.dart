import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';
import 'package:manyui_riverpod/manyui_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';

import '../accounts/accounts_dialog.dart';
import '../chat/chat_page.dart';
import '../matrix/providers.dart';
import '../theme.dart';
import 'room_dialogs.dart';
import 'room_tile.dart';

/// Breakpoint above which rooms and chat render side by side.
const double kTwoPaneBreakpoint = 900;

/// Joined-room list. Wide layouts show rooms | chat as two panes; narrow
/// layouts push [ChatPage] on top.
class RoomsPage extends ConsumerWidget {
  const RoomsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId = ref.watch(currentUserIdProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= kTwoPaneBreakpoint;
        return MScaffold(
          header: MAppHeader(
            title: 'ManyMatrix',
            subtitle: userId,
            actions: <Widget>[
              MButton(
                variant: MButtonVariant.ghost,
                onPressed: () => ref.toggleMThemeMode(themeModeProvider),
                semanticLabel: 'Toggle theme',
                child: MIcon(
                  ref.watchMThemeMode(themeModeProvider) == MThemeMode.dark
                      ? MIconData.sun
                      : MIconData.moon,
                ),
              ),
              MButton(
                variant: MButtonVariant.ghost,
                onPressed: () => showJoinRoomDialog(context, ref),
                child: const Text('Join room'),
              ),
              MButton(
                onPressed: () => showCreateRoomDialog(context, ref),
                child: const Text('Create room'),
              ),
              MButton(
                variant: MButtonVariant.ghost,
                onPressed: () => showAccountsDialog(context),
                child: const Text('Accounts'),
              ),
              MButton(
                variant: MButtonVariant.ghost,
                onPressed: () {
                  ref.read(selectedRoomIdProvider.notifier).state = null;
                  ref.read(authControllerProvider.notifier).signOut();
                },
                child: const Text('Logout'),
              ),
            ],
          ),
          body: wide ? const _TwoPaneBody() : const _RoomListBody(wide: false),
        );
      },
    );
  }
}

class _TwoPaneBody extends ConsumerWidget {
  const _TwoPaneBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = MTheme.of(context);
    final selectedRoomId = ref.watch(selectedRoomIdProvider);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(width: 320, child: _RoomListBody(wide: true)),
        Container(width: 1, color: theme.colors.border),
        Expanded(
          child: selectedRoomId == null
              ? const Center(
                  child: MEmptyState(title: 'Select a room to start chatting'),
                )
              : ChatView(
                  key: ValueKey(selectedRoomId),
                  roomId: selectedRoomId,
                  showRoomHeader: true,
                ),
        ),
      ],
    );
  }
}

class _RoomListBody extends ConsumerWidget {
  const _RoomListBody({required this.wide});

  final bool wide;

  void _openRoom(BuildContext context, WidgetRef ref, RoomSummary room) {
    ref.read(selectedRoomIdProvider.notifier).state = room.roomId;
    if (!wide) {
      Navigator.of(context).push(
        PageRouteBuilder<void>(
          pageBuilder: (context, animation, secondaryAnimation) =>
              ChatPage(roomId: room.roomId, roomName: room.displayName),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = MTheme.of(context);
    final rooms = ref.watch(roomListProvider);
    final selectedRoomId = ref.watch(selectedRoomIdProvider);

    return rooms.when(
      loading: () => const Center(
        child: MCircularProgress.indeterminate(semanticLabel: 'Loading rooms'),
      ),
      error: (error, _) => Center(
        child: Text(
          'Could not load rooms: $error',
          style: theme.typography.bodySmall.copyWith(
            color: theme.colors.destructive,
          ),
          textAlign: TextAlign.center,
        ),
      ),
      data: (list) {
        if (list.isEmpty) {
          return Center(
            child: MEmptyState(
              title: 'No rooms yet',
              description: 'Create a room or join one by room id.',
              actions: <Widget>[
                MButton(
                  onPressed: () => showCreateRoomDialog(context, ref),
                  child: const Text('Create room'),
                ),
                MButton(
                  variant: MButtonVariant.ghost,
                  onPressed: () => showJoinRoomDialog(context, ref),
                  child: const Text('Join room'),
                ),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: list.length,
          itemBuilder: (context, index) {
            final room = list[index];
            return RoomTile(
              room: room,
              selected: wide && room.roomId == selectedRoomId,
              onTap: () => _openRoom(context, ref, room),
            );
          },
        );
      },
    );
  }
}

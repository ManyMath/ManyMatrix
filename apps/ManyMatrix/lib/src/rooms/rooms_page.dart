import 'dart:async';

import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';
import 'package:manyui_hooks/manyui_hooks.dart';
import 'package:manyui_riverpod/manyui_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';

import '../accounts/accounts_dialog.dart';
import '../branding.dart';
import '../chat/chat_page.dart';
import '../matrix/matrix_display.dart';
import '../matrix/providers.dart';
import '../matrix/thread_timeline.dart';
import '../theme.dart';
import '../threads/threads_page.dart';
import 'room_dialogs.dart';
import 'room_tile.dart';

/// Breakpoint above which rooms and chat render side by side.
const double kTwoPaneBreakpoint = 840;
const double _roomPaneMinWidth = 288;
const double _roomPaneMaxWidth = 360;

enum _RoomFilter { all, unread }

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
        final compactHeader = constraints.maxWidth < 720;
        final roomPaneWidth = (constraints.maxWidth * 0.3).clamp(
          _roomPaneMinWidth,
          _roomPaneMaxWidth,
        );
        return MScaffold(
          header: MAppHeader(
            title: 'ManyMatrix',
            subtitle: userId,
            leading: const ManyMatrixMark(size: 28),
            actions: <Widget>[
              _ThreadsShortcut(
                compact: compactHeader,
                onPressed: () => _openThreads(context, ref),
              ),
              MIconButton(
                onPressed: () => ref.toggleMThemeMode(themeModeProvider),
                label: 'Toggle theme',
                icon: ref.watchMThemeMode(themeModeProvider) == MThemeMode.dark
                    ? MIconData.sun
                    : MIconData.moon,
              ),
              if (compactHeader)
                MIconButton(
                  icon: MIconData.network,
                  label: 'Join room',
                  size: MButtonSize.sm,
                  onPressed: () => showJoinRoomDialog(context, ref),
                )
              else
                MButton(
                  variant: MButtonVariant.ghost,
                  size: MButtonSize.sm,
                  onPressed: () => showJoinRoomDialog(context, ref),
                  child: const Text('Join room'),
                ),
              if (compactHeader)
                MIconButton(
                  icon: MIconData.plus,
                  label: 'Create room',
                  size: MButtonSize.sm,
                  variant: MButtonVariant.primary,
                  onPressed: () => showCreateRoomDialog(context, ref),
                )
              else
                MButton(
                  size: MButtonSize.sm,
                  onPressed: () => showCreateRoomDialog(context, ref),
                  child: const Text('Create room'),
                ),
              MButton(
                variant: MButtonVariant.ghost,
                size: MButtonSize.sm,
                onPressed: () => showAccountsDialog(context),
                semanticLabel: 'Accounts',
                child: MAvatar(
                  size: 24,
                  fallback: Text(_accountInitial(userId)),
                ),
              ),
            ],
          ),
          body: wide
              ? _TwoPaneBody(roomPaneWidth: roomPaneWidth)
              : const _RoomListBody(wide: false),
        );
      },
    );
  }

  Future<void> _openThreads(BuildContext context, WidgetRef ref) async {
    final thread = await Navigator.of(context).push<ThreadSummary>(
      PageRouteBuilder<ThreadSummary>(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const ThreadsPage(),
      ),
    );
    if (thread == null || !context.mounted) return;
    final key = ThreadKey(
      roomId: thread.roomId,
      rootEventId: thread.root.eventId,
    );
    ref.read(requestedThreadProvider.notifier).state = key;
    ref.read(selectedRoomIdProvider.notifier).state = thread.roomId;
    final wide = MediaQuery.sizeOf(context).width >= kTwoPaneBreakpoint;
    if (!wide) {
      await Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          pageBuilder: (context, animation, secondaryAnimation) =>
              ChatPage(roomId: thread.roomId, roomName: thread.roomName),
        ),
      );
    }
  }
}

class _ThreadsShortcut extends ConsumerWidget {
  const _ThreadsShortcut({required this.compact, required this.onPressed});

  final bool compact;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threadIndex = ref.watch(threadIndexProvider);
    final stale = ref.watch(threadIndexStaleProvider);
    final threads = threadIndex.valueOrNull;
    final unread =
        threads?.fold<int>(
          0,
          (total, thread) => total + (thread.unreadCount ?? 0),
        ) ??
        0;
    final unknownUnread =
        stale ||
        (threads?.any((thread) => thread.unreadCount == null) ?? false);
    final label = threadIndex.hasError
        ? 'Threads unavailable'
        : unread == 0 && !unknownUnread
        ? 'Threads'
        : 'Threads'
              '${unread == 0 ? '' : ', $unread unread ${unread == 1 ? 'reply' : 'replies'}'}'
              '${unknownUnread ? ', some unread status unavailable' : ''}';
    return MButton(
      variant: MButtonVariant.ghost,
      size: MButtonSize.sm,
      style: const MButtonStyleDelta(minHeight: 40),
      onPressed: onPressed,
      semanticLabel: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const MIcon(MIconData.message, size: 18),
          if (!compact) ...<Widget>[
            const SizedBox(width: 7),
            const Text('Threads'),
          ],
          if (unread > 0) ...<Widget>[
            const SizedBox(width: 6),
            MBadge(child: Text(unread > 99 ? '99+' : '$unread')),
          ],
          if (threadIndex.hasError || unknownUnread) ...<Widget>[
            const SizedBox(width: 6),
            MBadge(
              variant: threadIndex.hasError
                  ? MBadgeVariant.destructive
                  : MBadgeVariant.secondary,
              child: Text(threadIndex.hasError ? '!' : '?'),
            ),
          ],
        ],
      ),
    );
  }
}

class _TwoPaneBody extends ConsumerWidget {
  const _TwoPaneBody({required this.roomPaneWidth});

  final double roomPaneWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = MTheme.of(context);
    final selectedRoomId = ref.watch(selectedRoomIdProvider);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(width: roomPaneWidth, child: const _RoomListBody(wide: true)),
        Container(width: 1, color: theme.colors.border),
        Expanded(
          child: selectedRoomId == null
              ? const Center(
                  child: MEmptyState(
                    title: 'Choose a conversation',
                    description:
                        'Select a room from the list to read and send messages.',
                  ),
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

class _RoomListBody extends HookConsumerWidget {
  const _RoomListBody({required this.wide});

  final bool wide;

  void _openRoom(BuildContext context, WidgetRef ref, RoomSummary room) {
    _openRoomById(
      context,
      ref,
      roomId: room.roomId,
      roomName: room.displayName,
    );
  }

  void _openRoomById(
    BuildContext context,
    WidgetRef ref, {
    required String roomId,
    required String roomName,
  }) {
    ref.read(selectedRoomIdProvider.notifier).state = roomId;
    if (!wide) {
      Navigator.of(context).push(
        PageRouteBuilder<void>(
          pageBuilder: (context, animation, secondaryAnimation) =>
              ChatPage(roomId: roomId, roomName: roomName),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rooms = ref.watch(roomListProvider);
    final invites = ref.watch(roomInvitesProvider);
    final selectedRoomId = ref.watch(selectedRoomIdProvider);
    final currentUserId = ref.watch(currentUserIdProvider);
    final queryController = useMController<String>('');
    final query = useValueListenable(queryController);
    final filter = useState(_RoomFilter.all);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _RoomListToolbar(
          queryController: queryController,
          filter: filter.value,
          onFilterChanged: (value) => filter.value = value,
          onRefresh: () {
            unawaited(ref.read(roomListProvider.notifier).refresh());
            unawaited(ref.read(roomInvitesProvider.notifier).refresh());
          },
        ),
        const MDivider(),
        Expanded(
          child: rooms.when(
            loading: () =>
                const Center(child: MLoadingState(message: 'Loading rooms')),
            error: (error, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: MAlert(
                  title: 'Rooms unavailable',
                  variant: MAlertVariant.destructive,
                  message: 'Could not load rooms: $error',
                  maxWidth: 420,
                  actions: <Widget>[
                    MButton(
                      variant: MButtonVariant.outline,
                      size: MButtonSize.sm,
                      onPressed: () => ref.invalidate(roomListProvider),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
            data: (list) => _buildRoomList(
              context,
              ref,
              list: list,
              invites: invites,
              selectedRoomId: selectedRoomId,
              currentUserId: currentUserId,
              query: query,
              queryController: queryController,
              filter: filter,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRoomList(
    BuildContext context,
    WidgetRef ref, {
    required List<RoomSummary> list,
    required AsyncValue<List<RoomInvite>> invites,
    required String? selectedRoomId,
    required String? currentUserId,
    required String query,
    required MController<String> queryController,
    required ValueNotifier<_RoomFilter> filter,
  }) {
    final inviteList = invites.valueOrNull ?? const <RoomInvite>[];
    final normalizedQuery = query.trim().toLowerCase();
    final visibleRooms =
        list
            .where(
              (room) =>
                  (filter.value == _RoomFilter.all || room.unreadCount > 0) &&
                  _roomMatches(room, normalizedQuery),
            )
            .toList()
          ..sort(_compareRoomsByActivity);
    final visibleInvites = inviteList
        .where((invite) => _inviteMatches(invite, normalizedQuery))
        .toList();

    if (wide &&
        selectedRoomId != null &&
        !list.any((room) => room.roomId == selectedRoomId)) {
      Future.microtask(() {
        if (!context.mounted) return;
        ref.read(selectedRoomIdProvider.notifier).state = null;
      });
    }

    if (list.isEmpty && invites.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: MAlert(
            title: 'Invitations unavailable',
            variant: MAlertVariant.destructive,
            message: 'Could not load invitations: ${invites.error}',
            actions: <Widget>[
              MButton(
                variant: MButtonVariant.outline,
                size: MButtonSize.sm,
                onPressed: () => ref.invalidate(roomInvitesProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (list.isEmpty && inviteList.isEmpty && !invites.isLoading) {
      return Center(
        child: MEmptyState(
          title: 'No rooms yet',
          description: 'Create a room or join one by room ID or alias.',
          actions: <Widget>[
            MButton(
              onPressed: () => showCreateRoomDialog(context, ref),
              child: const Text('Create room'),
            ),
            MButton(
              variant: MButtonVariant.outline,
              onPressed: () => showJoinRoomDialog(context, ref),
              child: const Text('Join room'),
            ),
          ],
        ),
      );
    }

    if (visibleRooms.isEmpty && visibleInvites.isEmpty && !invites.isLoading) {
      final unreadOnly = filter.value == _RoomFilter.unread;
      return Center(
        child: MEmptyState(
          title: unreadOnly ? 'You are all caught up' : 'No matching rooms',
          description: unreadOnly
              ? 'There are no unread conversations.'
              : 'Try a different room name or message.',
          actions: <Widget>[
            MButton(
              variant: MButtonVariant.outline,
              onPressed: () {
                queryController.value = '';
                filter.value = _RoomFilter.all;
              },
              child: const Text('Show all rooms'),
            ),
          ],
        ),
      );
    }

    return CustomScrollView(
      slivers: <Widget>[
        if (invites.isLoading && list.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: MLoadingState(message: 'Checking invitations'),
            ),
          ),
        if (invites.hasError)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: MAlert(
                variant: MAlertVariant.destructive,
                message: 'Could not load invitations: ${invites.error}',
                actions: <Widget>[
                  MButton(
                    variant: MButtonVariant.outline,
                    size: MButtonSize.sm,
                    onPressed: () => ref.invalidate(roomInvitesProvider),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        if (visibleInvites.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: MSectionHeader(
                title: 'Invitations',
                status: MBadge(child: Text('${visibleInvites.length}')),
              ),
            ),
          ),
        if (visibleInvites.isNotEmpty)
          SliverList.builder(
            itemCount: visibleInvites.length,
            itemBuilder: (context, index) {
              final invite = visibleInvites[index];
              return _InviteTile(
                key: ValueKey(invite.roomId),
                invite: invite,
                onJoined: (roomId) => _openRoomById(
                  context,
                  ref,
                  roomId: roomId,
                  roomName: invite.displayName,
                ),
              );
            },
          ),
        if (visibleInvites.isNotEmpty && visibleRooms.isNotEmpty)
          const SliverToBoxAdapter(child: MDivider()),
        SliverPadding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          sliver: SliverList.builder(
            itemCount: visibleRooms.length,
            itemBuilder: (context, index) {
              final room = visibleRooms[index];
              return RoomTile(
                key: ValueKey(room.roomId),
                room: room,
                selected: wide && room.roomId == selectedRoomId,
                currentUserId: currentUserId,
                onTap: () => _openRoom(context, ref, room),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RoomListToolbar extends StatelessWidget {
  const _RoomListToolbar({
    required this.queryController,
    required this.filter,
    required this.onFilterChanged,
    required this.onRefresh,
  });

  final MController<String> queryController;
  final _RoomFilter filter;
  final ValueChanged<_RoomFilter> onFilterChanged;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          MSectionHeader(
            title: 'Rooms',
            actions: <Widget>[
              MIconButton(
                icon: MIconData.refresh,
                label: 'Refresh rooms',
                size: MButtonSize.sm,
                onPressed: onRefresh,
              ),
            ],
          ),
          const SizedBox(height: 10),
          MTextField(
            controller: queryController,
            placeholder: 'Search rooms',
            semanticLabel: 'Search rooms',
            leading: const MIcon(MIconData.search, size: 16),
          ),
          const SizedBox(height: 10),
          MSegmentedControl<_RoomFilter>(
            value: filter,
            fullWidth: true,
            onChanged: onFilterChanged,
            items: const <MSegmentedItem<_RoomFilter>>[
              MSegmentedItem<_RoomFilter>(value: _RoomFilter.all, label: 'All'),
              MSegmentedItem<_RoomFilter>(
                value: _RoomFilter.unread,
                label: 'Unread',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InviteTile extends ConsumerStatefulWidget {
  const _InviteTile({required this.invite, required this.onJoined, super.key});

  final RoomInvite invite;
  final ValueChanged<String> onJoined;

  @override
  ConsumerState<_InviteTile> createState() => _InviteTileState();
}

class _InviteTileState extends ConsumerState<_InviteTile> {
  bool _busy = false;
  Object? _error;

  String get _initial {
    final name = widget.invite.displayName.trim();
    if (name.isEmpty) return '?';
    final letters = name.replaceFirst(RegExp(r'^[#!@]+'), '');
    return (letters.isEmpty ? name : letters).substring(0, 1).toUpperCase();
  }

  String get _subtitle {
    final inviter = widget.invite.inviterDisplayName?.trim();
    if (inviter != null && inviter.isNotEmpty) return 'Invited by $inviter';
    final inviterId = widget.invite.inviterUserId?.trim();
    if (inviterId != null && inviterId.isNotEmpty) {
      return 'Invited by ${matrixUserDisplayName(inviterId)}';
    }
    final aliases = widget.invite.aliases;
    if (aliases.isNotEmpty) return aliases.join(' ');
    return widget.invite.roomId;
  }

  Future<void> _join() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final invite = widget.invite;
    final onJoined = widget.onJoined;
    final service = ref.read(matrixServiceProvider);
    try {
      final roomId = await service.joinRoom(invite.roomId);
      if (!mounted ||
          widget.invite.roomId != invite.roomId ||
          !identical(ref.read(matrixServiceProvider), service)) {
        return;
      }
      final roomList = ref.read(roomListProvider.notifier);
      roomList.rememberRoom(roomId, invite.displayName);
      onJoined(roomId);
      ref.invalidate(roomInvitesProvider);
      unawaited(roomList.refresh());
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decline() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final invite = widget.invite;
    final service = ref.read(matrixServiceProvider);
    try {
      await service.leaveRoom(invite.roomId);
      if (!mounted ||
          widget.invite.roomId != invite.roomId ||
          !identical(ref.read(matrixServiceProvider), service)) {
        return;
      }
      ref.invalidate(roomInvitesProvider);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showDetails() async {
    await showMDialog<void>(
      context,
      builder: (context) => _InviteDetailsDialog(
        invite: widget.invite,
        busy: _busy,
        onJoin: () {
          Navigator.of(context).pop();
          unawaited(_join());
        },
        onDecline: () {
          Navigator.of(context).pop();
          unawaited(_decline());
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MListTile(
          leading: MAvatar(
            size: 36,
            fallback: Text(_initial),
            semanticLabel: widget.invite.displayName,
          ),
          title: Text(
            widget.invite.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            _subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              MButton(
                size: MButtonSize.sm,
                onPressed: _busy ? null : _join,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: MCircularProgress.indeterminate(
                          semanticLabel: 'Joining room',
                        ),
                      )
                    : const Text('Join'),
              ),
            ],
          ),
          onTap: _busy ? null : _showDetails,
          semanticLabel: 'Room invitation ${widget.invite.displayName}',
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: MAlert(
              variant: MAlertVariant.destructive,
              message: 'Could not update invitation: $_error',
            ),
          ),
      ],
    );
  }
}

class _InviteDetailsDialog extends StatelessWidget {
  const _InviteDetailsDialog({
    required this.invite,
    required this.busy,
    required this.onJoin,
    required this.onDecline,
  });

  final RoomInvite invite;
  final bool busy;
  final VoidCallback onJoin;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final aliases = invite.aliases;
    final topic = invite.topic?.trim();
    return MDialogContent(
      title: 'Room invitation',
      maxWidth: 560,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _InviteDetailField(label: 'Room', value: invite.displayName),
          _InviteDetailField(label: 'Room ID', value: invite.roomId),
          if (aliases.isNotEmpty)
            _InviteDetailField(label: 'Aliases', value: aliases.join('\n')),
          if (topic != null && topic.isNotEmpty)
            _InviteDetailField(label: 'Topic', value: topic),
          _InviteDetailField(
            label: 'Invited account',
            value: _memberLine(
              userId: invite.invitedUserId,
              displayName: invite.invitedDisplayName,
            ),
          ),
          _InviteDetailField(
            label: 'Invited by',
            value: _memberLine(
              userId: invite.inviterUserId,
              displayName: invite.inviterDisplayName,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        MButton(
          variant: MButtonVariant.ghost,
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        MButton(
          variant: MButtonVariant.destructive,
          onPressed: busy ? null : onDecline,
          child: const Text('Decline'),
        ),
        MButton(
          onPressed: busy ? null : onJoin,
          child: Text(busy ? '...' : 'Join'),
        ),
      ],
    );
  }
}

class _InviteDetailField extends StatelessWidget {
  const _InviteDetailField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = MTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: theme.typography.caption.copyWith(
              color: theme.colors.mutedForeground,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value.isEmpty ? 'Not available before joining' : value,
            style: theme.typography.body.copyWith(
              color: theme.colors.foreground,
            ),
          ),
        ],
      ),
    );
  }
}

String _memberLine({required String? userId, required String? displayName}) {
  final name = displayName?.trim();
  final id = userId?.trim();
  if (name != null && name.isNotEmpty && id != null && id.isNotEmpty) {
    if (name == id) return id;
    return '$name ($id)';
  }
  if (id != null && id.isNotEmpty) return id;
  if (name != null && name.isNotEmpty) return name;
  return '';
}

String _accountInitial(String? userId) {
  if (userId == null || userId.trim().isEmpty) return '?';
  final display = matrixUserDisplayName(userId).trim();
  return (display.isEmpty ? userId : display).substring(0, 1).toUpperCase();
}

bool _roomMatches(RoomSummary room, String query) {
  if (query.isEmpty) return true;
  final preview = room.lastMessage;
  return room.displayName.toLowerCase().contains(query) ||
      room.roomId.toLowerCase().contains(query) ||
      (preview != null &&
          (preview.body.toLowerCase().contains(query) ||
              preview.sender.toLowerCase().contains(query)));
}

bool _inviteMatches(RoomInvite invite, String query) {
  if (query.isEmpty) return true;
  return <String>[
    invite.displayName,
    invite.roomId,
    ...invite.aliases,
    if (invite.topic != null) invite.topic!,
    if (invite.inviterDisplayName != null) invite.inviterDisplayName!,
    if (invite.inviterUserId != null) invite.inviterUserId!,
  ].any((value) => value.toLowerCase().contains(query));
}

int _compareRoomsByActivity(RoomSummary left, RoomSummary right) {
  final leftTimestamp = left.lastMessage?.timestamp ?? 0;
  final rightTimestamp = right.lastMessage?.timestamp ?? 0;
  final byTimestamp = rightTimestamp.compareTo(leftTimestamp);
  if (byTimestamp != 0) return byTimestamp;
  final byUnread = right.unreadCount.compareTo(left.unreadCount);
  if (byUnread != 0) return byUnread;
  return left.displayName.toLowerCase().compareTo(
    right.displayName.toLowerCase(),
  );
}

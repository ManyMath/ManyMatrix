import 'dart:async';

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

    return rooms.when(
      loading: () =>
          const Center(child: MLoadingState(message: 'Loading rooms')),
      error: (error, _) => Center(
        child: MAlert(
          variant: MAlertVariant.destructive,
          message: 'Could not load rooms: $error',
          maxWidth: 420,
        ),
      ),
      data: (list) {
        final inviteList = invites.valueOrNull ?? const <RoomInvite>[];
        if (wide &&
            selectedRoomId != null &&
            !list.any((room) => room.roomId == selectedRoomId)) {
          Future.microtask(() {
            if (!context.mounted) return;
            ref.read(selectedRoomIdProvider.notifier).state = null;
          });
        }

        if (list.isEmpty && inviteList.isEmpty && !invites.isLoading) {
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
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 4),
          children: <Widget>[
            if (invites.isLoading && list.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: MLoadingState(message: 'Checking invitations'),
              ),
            if (invites.hasError)
              Padding(
                padding: const EdgeInsets.all(12),
                child: MAlert(
                  variant: MAlertVariant.destructive,
                  message: 'Could not load invitations: ${invites.error}',
                ),
              ),
            if (inviteList.isNotEmpty) ...<Widget>[
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: MSectionHeader(title: 'Invitations'),
              ),
              for (final invite in inviteList)
                _InviteTile(
                  invite: invite,
                  onJoined: (roomId) => _openRoomById(
                    context,
                    ref,
                    roomId: roomId,
                    roomName: invite.displayName,
                  ),
                ),
              if (list.isNotEmpty) const MDivider(),
            ],
            for (final room in list)
              RoomTile(
                room: room,
                selected: wide && room.roomId == selectedRoomId,
                onTap: () => _openRoom(context, ref, room),
              ),
          ],
        );
      },
    );
  }
}

class _InviteTile extends ConsumerStatefulWidget {
  const _InviteTile({required this.invite, required this.onJoined});

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
    try {
      final roomId = await ref
          .read(matrixServiceProvider)
          .joinRoom(widget.invite.roomId);
      ref.invalidate(roomInvitesProvider);
      ref.invalidate(roomListProvider);
      if (mounted) widget.onJoined(roomId);
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
    try {
      await ref.read(matrixServiceProvider).leaveRoom(widget.invite.roomId);
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
                variant: MButtonVariant.ghost,
                size: MButtonSize.sm,
                onPressed: _busy ? null : _showDetails,
                child: const Text('Details'),
              ),
              const SizedBox(width: 6),
              MButton(
                size: MButtonSize.sm,
                onPressed: _busy ? null : _join,
                child: Text(_busy ? '...' : 'Join'),
              ),
              const SizedBox(width: 6),
              MButton(
                variant: MButtonVariant.ghost,
                size: MButtonSize.sm,
                onPressed: _busy ? null : _decline,
                child: const Text('Decline'),
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

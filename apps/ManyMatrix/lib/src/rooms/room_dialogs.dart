import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';

import '../matrix/providers.dart';

/// Opens the "create room" dialog. On success, refreshes the room list and
/// selects the new room. Returns the new room's ID, or null if cancelled.
Future<String?> showCreateRoomDialog(BuildContext context, WidgetRef ref) {
  return showMDialog<String>(
    context,
    semanticLabel: 'Create room',
    builder: (context) => const _CreateRoomDialogBody(),
  );
}

class _CreateRoomDialogBody extends HookConsumerWidget {
  const _CreateRoomDialogBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = useState('');
    final topic = useState('');
    final creating = useState(false);
    final error = useState<String?>(null);
    final status = useState<String?>(null);
    final createdRoomId = useState<String?>(null);
    final nameFocus = useFocusNode();
    final topicFocus = useFocusNode();

    Future<void> submit() async {
      if (creating.value) return;
      final trimmedName = name.value.trim();
      creating.value = true;
      error.value = null;
      status.value = null;
      try {
        final service = ref.read(matrixServiceProvider);
        var roomId = createdRoomId.value;
        roomId ??= await service.createRoom(
          name: trimmedName.isEmpty ? null : trimmedName,
          topic: topic.value.trim().isEmpty ? null : topic.value.trim(),
        );
        if (!context.mounted ||
            !identical(ref.read(matrixServiceProvider), service)) {
          return;
        }
        createdRoomId.value = roomId;
        ref.read(roomListProvider.notifier).rememberRoom(roomId, trimmedName);
        var ready = false;
        for (var attempt = 0; attempt < 40; attempt += 1) {
          if (!context.mounted ||
              !identical(ref.read(matrixServiceProvider), service)) {
            return;
          }
          try {
            final rooms = await service.joinedRooms();
            ready = rooms.any(
              (room) =>
                  room.roomId == roomId &&
                  room.isSynced &&
                  (trimmedName.isEmpty || room.displayName == trimmedName),
            );
          } on Object {
            // The room already exists; background sync or Refresh retries.
          }
          if (!context.mounted ||
              !identical(ref.read(matrixServiceProvider), service)) {
            return;
          }
          if (ready) break;
          if (attempt < 39) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
        await ref.read(roomListProvider.notifier).refresh();
        if (!context.mounted ||
            !identical(ref.read(matrixServiceProvider), service)) {
          return;
        }
        if (!ready) {
          status.value =
              'Room created. Waiting for its first sync before opening it.';
          return;
        }
        ref.read(selectedRoomIdProvider.notifier).state = roomId;
        if (context.mounted) Navigator.of(context).pop(roomId);
      } on Object catch (err) {
        if (context.mounted) {
          error.value = createdRoomId.value == null
              ? 'Could not create room: $err'
              : 'The room was created, but its sync check failed: $err';
        }
      } finally {
        if (context.mounted) creating.value = false;
      }
    }

    return PopScope(
      canPop: !creating.value,
      child: MDialogContent(
        title: 'Create room',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            MField(
              label: 'Name (optional)',
              focusNode: nameFocus,
              enabled: !creating.value && createdRoomId.value == null,
              child: MTextField(
                focusNode: nameFocus,
                placeholder: 'Room name',
                semanticLabel: 'Room name',
                enabled: !creating.value && createdRoomId.value == null,
                onChanged: (value) => name.value = value,
                onSubmitted: (_) => submit(),
              ),
            ),
            const SizedBox(height: 16),
            MField(
              label: 'Topic (optional)',
              focusNode: topicFocus,
              enabled: !creating.value && createdRoomId.value == null,
              child: MTextField(
                focusNode: topicFocus,
                placeholder: 'Topic',
                semanticLabel: 'Room topic',
                enabled: !creating.value && createdRoomId.value == null,
                onChanged: (value) => topic.value = value,
                onSubmitted: (_) => submit(),
              ),
            ),
            if (error.value != null) ...<Widget>[
              const SizedBox(height: 12),
              MAlert(variant: MAlertVariant.destructive, message: error.value!),
            ],
            if (status.value != null) ...<Widget>[
              const SizedBox(height: 12),
              MAlert(message: status.value!),
            ],
          ],
        ),
        actions: <Widget>[
          MButton(
            variant: MButtonVariant.ghost,
            onPressed: creating.value
                ? null
                : () => Navigator.of(context).pop(),
            child: Text(createdRoomId.value == null ? 'Cancel' : 'Close'),
          ),
          MButton(
            onPressed: creating.value ? null : submit,
            child: Text(
              creating.value
                  ? createdRoomId.value == null
                        ? 'Creating...'
                        : 'Checking...'
                  : createdRoomId.value == null
                  ? 'Create'
                  : 'Check again',
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the "join room" dialog. On success, refreshes the room list and
/// selects the joined room. Returns the joined room's ID, or null if
/// cancelled.
Future<String?> showJoinRoomDialog(BuildContext context, WidgetRef ref) {
  return showMDialog<String>(
    context,
    semanticLabel: 'Join room',
    builder: (context) => const _JoinRoomDialogBody(),
  );
}

class _JoinRoomDialogBody extends HookConsumerWidget {
  const _JoinRoomDialogBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roomIdOrAlias = useState('');
    final joining = useState(false);
    final error = useState<String?>(null);
    final targetFocus = useFocusNode();

    Future<void> submit() async {
      if (joining.value) return;
      final target = roomIdOrAlias.value.trim();
      if (target.isEmpty) return;
      joining.value = true;
      error.value = null;
      try {
        final service = ref.read(matrixServiceProvider);
        final roomId = await service.joinRoom(target);
        if (!context.mounted ||
            !identical(ref.read(matrixServiceProvider), service)) {
          return;
        }
        final roomList = ref.read(roomListProvider.notifier);
        roomList.rememberRoom(roomId, target);
        await roomList.refresh();
        if (!context.mounted ||
            !identical(ref.read(matrixServiceProvider), service)) {
          return;
        }
        ref.read(selectedRoomIdProvider.notifier).state = roomId;
        if (context.mounted) Navigator.of(context).pop(roomId);
      } on Object catch (err) {
        if (context.mounted) error.value = 'Could not join room: $err';
      } finally {
        if (context.mounted) joining.value = false;
      }
    }

    return PopScope(
      canPop: !joining.value,
      child: MDialogContent(
        title: 'Join room',
        description:
            'Enter a room ID (!abc:example.org) or alias (#room:example.org).',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            MField(
              label: 'Room ID or alias',
              focusNode: targetFocus,
              enabled: !joining.value,
              child: MTextField(
                focusNode: targetFocus,
                placeholder: '#room:example.org',
                semanticLabel: 'Room ID or alias',
                enabled: !joining.value,
                onChanged: (value) => roomIdOrAlias.value = value,
                onSubmitted: (_) => submit(),
              ),
            ),
            if (error.value != null) ...<Widget>[
              const SizedBox(height: 12),
              MAlert(variant: MAlertVariant.destructive, message: error.value!),
            ],
          ],
        ),
        actions: <Widget>[
          MButton(
            variant: MButtonVariant.ghost,
            onPressed: joining.value ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          MButton(
            onPressed: joining.value || roomIdOrAlias.value.trim().isEmpty
                ? null
                : submit,
            child: Text(joining.value ? 'Joining...' : 'Join'),
          ),
        ],
      ),
    );
  }
}

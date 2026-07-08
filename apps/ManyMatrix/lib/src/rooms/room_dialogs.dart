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

    Future<void> submit() async {
      if (creating.value) return;
      final trimmedName = name.value.trim();
      creating.value = true;
      error.value = null;
      try {
        final service = ref.read(matrixServiceProvider);
        final roomId = await service.createRoom(
          name: trimmedName.isEmpty ? null : trimmedName,
          topic: topic.value.trim().isEmpty ? null : topic.value.trim(),
        );
        await ref.read(roomListProvider.notifier).refresh();
        ref.read(selectedRoomIdProvider.notifier).state = roomId;
        if (context.mounted) Navigator.of(context).pop(roomId);
      } on Object catch (err) {
        error.value = 'Could not create room: $err';
      } finally {
        creating.value = false;
      }
    }

    return MDialogContent(
      title: 'Create room',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const MLabel('Name'),
          const SizedBox(height: 8),
          MTextField(
            placeholder: 'Room name',
            semanticLabel: 'Room name',
            enabled: !creating.value,
            onChanged: (value) => name.value = value,
            onSubmitted: (_) => submit(),
          ),
          const SizedBox(height: 16),
          const MLabel('Topic (optional)'),
          const SizedBox(height: 8),
          MTextField(
            placeholder: 'Topic',
            semanticLabel: 'Room topic',
            enabled: !creating.value,
            onChanged: (value) => topic.value = value,
            onSubmitted: (_) => submit(),
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
          onPressed: creating.value ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        MButton(
          onPressed: creating.value ? null : submit,
          child: Text(creating.value ? 'Creating…' : 'Create'),
        ),
      ],
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

    Future<void> submit() async {
      if (joining.value) return;
      final target = roomIdOrAlias.value.trim();
      if (target.isEmpty) return;
      joining.value = true;
      error.value = null;
      try {
        final service = ref.read(matrixServiceProvider);
        final roomId = await service.joinRoom(target);
        await ref.read(roomListProvider.notifier).refresh();
        ref.read(selectedRoomIdProvider.notifier).state = roomId;
        if (context.mounted) Navigator.of(context).pop(roomId);
      } on Object catch (err) {
        error.value = 'Could not join room: $err';
      } finally {
        joining.value = false;
      }
    }

    return MDialogContent(
      title: 'Join room',
      description:
          'Enter a room ID (!abc:example.org) or alias (#room:example.org).',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const MLabel('Room ID or alias'),
          const SizedBox(height: 8),
          MTextField(
            placeholder: '#room:example.org',
            semanticLabel: 'Room ID or alias',
            enabled: !joining.value,
            onChanged: (value) => roomIdOrAlias.value = value,
            onSubmitted: (_) => submit(),
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
          onPressed: joining.value ? null : submit,
          child: Text(joining.value ? 'Joining…' : 'Join'),
        ),
      ],
    );
  }
}

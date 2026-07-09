import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manyui/manyui.dart';

import '../matrix/providers.dart';

/// Opens the "invite user" dialog for [roomId]. Returns true if the invite
/// was sent, false/null if cancelled.
Future<bool?> showInviteDialog(
  BuildContext context,
  WidgetRef ref, {
  required String roomId,
}) {
  return showMDialog<bool>(
    context,
    semanticLabel: 'Invite to room',
    builder: (context) => _InviteDialogBody(roomId: roomId),
  );
}

class _InviteDialogBody extends HookConsumerWidget {
  const _InviteDialogBody({required this.roomId});

  final String roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId = useState('');
    final inviting = useState(false);
    final error = useState<String?>(null);
    final userIdFocus = useFocusNode();

    Future<void> submit() async {
      if (inviting.value) return;
      final target = userId.value.trim();
      if (target.isEmpty) return;
      inviting.value = true;
      error.value = null;
      try {
        final service = ref.read(matrixServiceProvider);
        await service.invite(roomId, target);
        if (context.mounted) Navigator.of(context).pop(true);
      } on Object catch (err) {
        error.value = 'Could not invite: $err';
      } finally {
        inviting.value = false;
      }
    }

    return MDialogContent(
      title: 'Invite to room',
      description: 'Enter the Matrix user ID to invite (@user:example.org).',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          MField(
            label: 'User ID',
            focusNode: userIdFocus,
            enabled: !inviting.value,
            child: MTextField(
              focusNode: userIdFocus,
              placeholder: '@user:example.org',
              semanticLabel: 'User ID',
              enabled: !inviting.value,
              onChanged: (value) => userId.value = value,
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
          onPressed: inviting.value ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        MButton(
          onPressed: inviting.value ? null : submit,
          child: Text(inviting.value ? 'Inviting…' : 'Invite'),
        ),
      ],
    );
  }
}

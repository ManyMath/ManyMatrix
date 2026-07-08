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
    final theme = MTheme.of(context);
    final userId = useState('');
    final inviting = useState(false);
    final error = useState<String?>(null);

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

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Invite to room', style: theme.typography.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'Enter the Matrix user ID to invite (@user:example.org).',
          style: theme.typography.bodySmall.copyWith(
            color: theme.colors.mutedForeground,
          ),
        ),
        const SizedBox(height: 16),
        const MLabel('User ID'),
        const SizedBox(height: 8),
        MTextField(
          placeholder: '@user:example.org',
          semanticLabel: 'User ID',
          enabled: !inviting.value,
          onChanged: (value) => userId.value = value,
          onSubmitted: (_) => submit(),
        ),
        if (error.value != null) ...<Widget>[
          const SizedBox(height: 12),
          MAlert(variant: MAlertVariant.destructive, message: error.value!),
        ],
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            MButton(
              variant: MButtonVariant.ghost,
              onPressed: inviting.value
                  ? null
                  : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            MButton(
              onPressed: inviting.value ? null : submit,
              child: Text(inviting.value ? 'Inviting…' : 'Invite'),
            ),
          ],
        ),
      ],
    );
  }
}

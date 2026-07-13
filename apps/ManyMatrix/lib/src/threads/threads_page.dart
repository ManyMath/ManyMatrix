import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manyui/manyui.dart';
import 'package:manyui_hooks/manyui_hooks.dart';

import '../matrix/matrix_display.dart';
import '../matrix/thread_timeline.dart';
import '../rooms/room_tile.dart';

enum _ThreadFilter { all, unread }

/// Cross-room index of recent Matrix threads.
class ThreadsPage extends HookConsumerWidget {
  const ThreadsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(threadIndexProvider);
    final stale = ref.watch(threadIndexStaleProvider);
    final queryController = useMController<String>('');
    final query = useValueListenable(queryController).trim().toLowerCase();
    final filter = useState(_ThreadFilter.all);

    return MScaffold(
      header: MAppHeader(
        title: 'Threads',
        leading: MIconButton(
          icon: MIconData.chevronLeft,
          label: 'Back to rooms',
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: <Widget>[
          MIconButton(
            icon: MIconData.refresh,
            label: 'Refresh threads',
            onPressed: () => ref.invalidate(threadIndexProvider),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 520;
                    final search = MTextField(
                      controller: queryController,
                      placeholder: 'Search threads',
                      semanticLabel: 'Search threads',
                      leading: const MIcon(MIconData.search, size: 16),
                    );
                    final filters = SizedBox(
                      width: compact ? null : 220,
                      child: MSegmentedControl<_ThreadFilter>(
                        value: filter.value,
                        fullWidth: true,
                        onChanged: (value) => filter.value = value,
                        items: const <MSegmentedItem<_ThreadFilter>>[
                          MSegmentedItem(
                            value: _ThreadFilter.all,
                            label: 'Recent',
                          ),
                          MSegmentedItem(
                            value: _ThreadFilter.unread,
                            label: 'Unread',
                          ),
                        ],
                      ),
                    );
                    if (compact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          search,
                          const SizedBox(height: 10),
                          filters,
                        ],
                      );
                    }
                    return Row(
                      children: <Widget>[
                        Expanded(child: search),
                        const SizedBox(width: 12),
                        filters,
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          const MDivider(),
          Expanded(
            child: index.when(
              loading: () => const Center(
                child: MLoadingState(message: 'Loading threads'),
              ),
              error: (error, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: MAlert(
                    title: 'Threads unavailable',
                    variant: MAlertVariant.destructive,
                    message:
                        'This homeserver did not provide the thread index. '
                        'Threads already loaded in room conversations remain usable.\n\n$error',
                    maxWidth: 520,
                    actions: <Widget>[
                      MButton(
                        variant: MButtonVariant.outline,
                        onPressed: () => ref.invalidate(threadIndexProvider),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
              data: (threads) {
                final visible = threads
                    .where((thread) {
                      if (filter.value == _ThreadFilter.unread &&
                          thread.unreadCount == 0) {
                        return false;
                      }
                      if (query.isEmpty) return true;
                      return <String>[
                        thread.roomName,
                        thread.roomId,
                        thread.root.body,
                        thread.root.sender,
                        if (thread.latestReply != null)
                          thread.latestReply!.body,
                        if (thread.latestReply != null)
                          thread.latestReply!.sender,
                      ].any((value) => value.toLowerCase().contains(query));
                    })
                    .toList(growable: false);
                if (visible.isEmpty) {
                  if (stale) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: MAlert(
                          title: 'Thread activity may be incomplete',
                          message:
                              'Could not refresh threads after new activity. Retry to load the latest index.',
                          maxWidth: 520,
                        ),
                      ),
                    );
                  }
                  final filtered =
                      query.isNotEmpty || filter.value == _ThreadFilter.unread;
                  return Center(
                    child: MEmptyState(
                      title: filtered
                          ? 'No matching threads'
                          : 'No recent threads',
                      description: filter.value == _ThreadFilter.unread
                          ? 'There are no unread thread replies.'
                          : filtered
                          ? 'Try a different room, author, or message.'
                          : 'Start a thread from any message in a room.',
                    ),
                  );
                }
                final unreadUnknown =
                    stale ||
                    threads.any((thread) => thread.unreadCount == null);
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: visible.length + (unreadUnknown ? 1 : 0),
                      separatorBuilder: (_, _) => const MDivider(),
                      itemBuilder: (context, index) {
                        if (unreadUnknown && index == 0) {
                          return const Padding(
                            padding: EdgeInsets.all(12),
                            child: MAlert(
                              title: 'Unread status unavailable',
                              message:
                                  'Thread activity is still listed, but may be incomplete. Refresh to retry.',
                            ),
                          );
                        }
                        final visibleIndex = index - (unreadUnknown ? 1 : 0);
                        return _ThreadTile(
                          thread: visible[visibleIndex],
                          onTap: () =>
                              Navigator.of(context).pop(visible[visibleIndex]),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({required this.thread, required this.onTap});

  final ThreadSummary thread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = MTheme.of(context);
    final latest = thread.latestReply;
    final unread = (thread.unreadCount ?? 0) > 0;
    final unreadUnknown = thread.unreadCount == null;
    final replies =
        '${thread.replyCount} ${thread.replyCount == 1 ? 'reply' : 'replies'}';
    final unreadLabel = unreadUnknown
        ? 'unread status unavailable'
        : unread
        ? '${thread.unreadCount} unread ${thread.unreadCount == 1 ? 'reply' : 'replies'}'
        : 'read';
    final roomInitial = _initial(thread.roomName);

    return MListTile(
      leading: ExcludeSemantics(
        child: MAvatar(size: 40, fallback: Text(roomInitial)),
      ),
      title: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              thread.root.body.trim().isEmpty
                  ? 'Message thread'
                  : thread.root.body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.body.copyWith(
                fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
          if (unread) ...<Widget>[
            const SizedBox(width: 8),
            MBadge(child: Text(_compactCount(thread.unreadCount!))),
          ] else if (unreadUnknown) ...<Widget>[
            const SizedBox(width: 8),
            const MBadge(variant: MBadgeVariant.secondary, child: Text('?')),
          ],
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '${thread.roomName} / ${matrixUserDisplayName(thread.root.sender)} / $replies',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (latest != null)
              Text(
                '${matrixUserDisplayName(latest.sender)}: ${latest.body}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.caption.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
          ],
        ),
      ),
      trailing: ExcludeSemantics(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              formatRoomListTimestamp(thread.lastActivityTimestamp),
              style: theme.typography.caption.copyWith(
                color: unread
                    ? theme.colors.primary
                    : theme.colors.mutedForeground,
              ),
            ),
            const SizedBox(height: 4),
            const MIcon(MIconData.chevronRight, size: 16),
          ],
        ),
      ),
      onTap: onTap,
      semanticLabel:
          'Open thread in ${thread.roomName}, ${thread.root.body}, $replies, $unreadLabel',
    );
  }
}

String _initial(String name) {
  final trimmed = name.trim().replaceFirst(RegExp(r'^[#!@]+'), '');
  return (trimmed.isEmpty ? '?' : trimmed.substring(0, 1)).toUpperCase();
}

String _compactCount(int count) => count > 99 ? '99+' : '$count';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/manymatrix_providers.dart';
import '../widgets/room_tile.dart';

/// Room list screen showing all joined rooms.
///
/// Triggers a sync on first load, supports pull-to-refresh,
/// and provides a logout action in the app bar.
class RoomListScreen extends ConsumerStatefulWidget {
  const RoomListScreen({super.key});

  @override
  ConsumerState<RoomListScreen> createState() => _RoomListScreenState();
}

class _RoomListScreenState extends ConsumerState<RoomListScreen> {
  @override
  void initState() {
    super.initState();
    // Trigger an initial sync to fetch latest data.
    Future.microtask(() => ref.read(syncProvider));
  }

  Future<void> _refresh() async {
    ref.invalidate(syncProvider);
    await ref.read(syncProvider.future);
  }

  Future<void> _logout() async {
    await performLogout(ref);
    // authStateProvider flips to false; GoRouter redirects to /login.
  }

  @override
  Widget build(BuildContext context) {
    final rooms = ref.watch(roomListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rooms'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: rooms.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Error loading rooms:\n$error',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => ref.invalidate(roomListProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (roomList) => RefreshIndicator(
          onRefresh: _refresh,
          child: roomList.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 200),
                    Center(child: Text('No rooms yet')),
                  ],
                )
              : ListView.builder(
                  itemCount: roomList.length,
                  itemBuilder: (context, index) {
                    final room = roomList[index];
                    return RoomTile(
                      room: room,
                      onTap: () => context.go('/chat/${room.roomId}'),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

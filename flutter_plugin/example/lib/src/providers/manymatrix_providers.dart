import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:manymatrix/manymatrix.dart';

/// Notifier that holds the active [ManyMatrixBridge] instance.
///
/// Null when the user is logged out. Set after login or session restore.
class ManyMatrixNotifier extends Notifier<ManyMatrixBridge?> {
  @override
  ManyMatrixBridge? build() {
    ref.onDispose(() {
      state?.dispose();
    });
    return null;
  }

  /// Set the active client instance.
  void setClient(ManyMatrixBridge? client) {
    state = client;
  }
}

/// Provider holding the active [ManyMatrixBridge] instance.
final matrixClientProvider =
    NotifierProvider<ManyMatrixNotifier, ManyMatrixBridge?>(
  ManyMatrixNotifier.new,
);

/// Whether the user is currently logged in (client is non-null).
final authStateProvider = Provider<bool>((ref) {
  return ref.watch(matrixClientProvider) != null;
});

/// The logged-in user's Matrix ID, or null while logged out.
final currentUserIdProvider = FutureProvider<String?>((ref) async {
  final client = ref.watch(matrixClientProvider);
  if (client == null) return null;
  return client.whoami();
});

/// Performs login: creates a client, authenticates, and stores it in
/// [matrixClientProvider]. Returns the session JSON for persistence.
Future<String> performLogin(
  WidgetRef ref, {
  required String homeserverUrl,
  required String storePath,
  required String username,
  required String password,
}) async {
  final client = await ManyMatrixBridge.create(homeserverUrl, storePath);
  final String sessionJson;
  try {
    sessionJson = await client.login(username, password);
  } catch (_) {
    // Nothing owns the client yet; release its native handle / worker.
    await client.close();
    rethrow;
  }
  ref.read(matrixClientProvider.notifier).setClient(client);
  return sessionJson;
}

/// Restores a session from previously saved JSON. Sets [matrixClientProvider].
Future<void> performRestore(
  WidgetRef ref, {
  required String homeserverUrl,
  required String storePath,
  required String sessionJson,
}) async {
  final client = await ManyMatrixBridge.create(homeserverUrl, storePath);
  await client.restore(sessionJson);
  ref.read(matrixClientProvider.notifier).setClient(client);
}

/// Logs out and clears the client.
///
/// The bridge tears down local state even when the server request fails
/// (native deletes the store, web closes the worker), so the client is
/// cleared either way and the server error is rethrown for the caller.
Future<void> performLogout(WidgetRef ref) async {
  final client = ref.read(matrixClientProvider);
  try {
    await client?.logout();
  } finally {
    ref.read(matrixClientProvider.notifier).setClient(null);
  }
}

/// Fetches the list of joined rooms. Re-fetch by invalidating this provider.
final roomListProvider = FutureProvider<List<RoomSummary>>((ref) async {
  final client = ref.watch(matrixClientProvider);
  if (client == null) return [];
  return client.joinedRooms();
});

/// Performs a single sync cycle and then invalidates [roomListProvider]
/// so the UI refreshes.
final syncProvider = FutureProvider<void>((ref) async {
  final client = ref.watch(matrixClientProvider);
  if (client == null) return;
  await client.syncOnce();
  ref.invalidate(roomListProvider);
});

/// Fetches paginated messages for a room.
///
/// Usage: `ref.watch(messagesProvider('!roomId:server'))`.
/// Invalidate to re-fetch.
final messagesProvider =
    FutureProvider.family<PaginatedMessages, String>((ref, roomId) async {
  final client = ref.watch(matrixClientProvider);
  if (client == null) {
    return PaginatedMessages(messages: []);
  }
  return client.getMessages(roomId, limit: 50);
});

/// Sends a text message to a room and invalidates that room's messages.
Future<String> performSendText(
  WidgetRef ref, {
  required String roomId,
  required String body,
}) async {
  final client = ref.read(matrixClientProvider);
  if (client == null) {
    throw StateError('Not logged in');
  }
  final eventId = await client.sendText(roomId, body);
  ref.invalidate(messagesProvider(roomId));
  return eventId;
}

/// Fetches the display name for a room.
final roomNameProvider =
    FutureProvider.family<String?, String>((ref, roomId) async {
  final client = ref.watch(matrixClientProvider);
  if (client == null) return null;
  return client.roomName(roomId);
});

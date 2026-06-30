import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';

import '../platform/runtime.dart';
import 'auth.dart';
import 'bridge_service.dart';

/// The app-wide [MatrixService]. Tests override this with a fake.
final matrixServiceProvider = Provider<MatrixService>((ref) {
  final service = BridgeMatrixService();
  ref.onDispose(service.dispose);
  return service;
});

/// Drives sign-in / restore / sign-out and exposes the current [AuthState].
class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    if (!matrixRuntimeSupported) return const AuthUnauthenticated();
    Future.microtask(_restore);
    return const AuthRestoring();
  }

  Future<void> _restore() async {
    try {
      final userId = await ref.read(matrixServiceProvider).restoreSession();
      state = userId != null
          ? AuthAuthenticated(userId)
          : const AuthUnauthenticated();
    } on Object {
      state = const AuthUnauthenticated();
    }
  }

  Future<void> signIn({
    required String homeserverUrl,
    required String username,
    required String password,
  }) async {
    if (state is AuthAuthenticating) return;
    state = const AuthAuthenticating();
    try {
      final userId = await ref.read(matrixServiceProvider).login(
            homeserverUrl: homeserverUrl,
            username: username,
            password: password,
          );
      state = AuthAuthenticated(userId);
    } on Object catch (error) {
      state = AuthUnauthenticated(friendlyLoginError(error));
    }
  }

  Future<void> signOut() async {
    try {
      await ref.read(matrixServiceProvider).logout();
    } finally {
      state = const AuthUnauthenticated();
    }
  }
}

final authControllerProvider =
    NotifierProvider<AuthController, AuthState>(AuthController.new);

/// The logged-in user's Matrix ID (from whoami at session start), else null.
final currentUserIdProvider = Provider<String?>((ref) {
  final auth = ref.watch(authControllerProvider);
  return auth is AuthAuthenticated ? auth.userId : null;
});

/// Room selected in the two-pane layout. Null when no room is open.
final selectedRoomIdProvider = StateProvider<String?>((ref) => null);

/// Joined rooms, refreshed whenever the sync thread delivers a message.
class RoomListController extends AsyncNotifier<List<RoomSummary>> {
  Timer? _refreshDebounce;

  @override
  Future<List<RoomSummary>> build() async {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated) return const <RoomSummary>[];

    final service = ref.watch(matrixServiceProvider);
    final subscription = service.messageEvents.listen((_) => _scheduleRefresh());
    ref.onDispose(() {
      subscription.cancel();
      _refreshDebounce?.cancel();
    });
    return service.joinedRooms();
  }

  /// Coalesces bursts of sync events into one re-fetch.
  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 250), refresh);
  }

  Future<void> refresh() async {
    if (ref.read(authControllerProvider) is! AuthAuthenticated) return;
    try {
      final rooms = await ref.read(matrixServiceProvider).joinedRooms();
      state = AsyncData(rooms);
    } on Object {
      // Keep showing the previous list; the next sync event retries.
    }
  }
}

final roomListProvider =
    AsyncNotifierProvider<RoomListController, List<RoomSummary>>(
  RoomListController.new,
);

/// Joined member user IDs for a room, fetched on demand (room-info view).
final roomMembersProvider =
    FutureProvider.family<List<String>, String>((ref, roomId) {
  return ref.watch(matrixServiceProvider).roomMembers(roomId);
});

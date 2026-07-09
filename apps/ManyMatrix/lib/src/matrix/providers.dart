import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';

import '../platform/runtime.dart';
import 'account.dart';
import 'auth.dart';
import 'bridge_service.dart';

/// Account id used before any account has been saved yet (i.e. while a
/// fresh login is in flight for what will become the first saved account).
/// Superseded the moment [AccountsController.add] makes an account active.
const _pendingAccountId = '_pending';

/// The app-wide [MatrixService], scoped to the active saved account (see
/// `account.dart`). Rebuilding when the active account changes disposes the
/// old service and constructs a fresh one against the new account's own
/// store path: only the active account's client is ever live (sync runs
/// for one account at a time). Tests override this with a fake.
final matrixServiceProvider = Provider<MatrixService>((ref) {
  final activeId = ref.watch(activeAccountIdProvider) ?? _pendingAccountId;
  final service = BridgeMatrixService(accountId: activeId);
  ref.onDispose(service.dispose);
  return service;
});

/// Drives sign-in / restore / sign-out and exposes the current [AuthState].
///
/// Multi-account aware: restoring/signing in/out act on whichever account is
/// currently active in `account.dart`'s `activeAccountIdProvider` (there is
/// only ever one *live* client at a time, see `matrixServiceProvider`).
class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    if (!matrixRuntimeSupported) return const AuthUnauthenticated();
    Future.microtask(_restore);
    return const AuthRestoring();
  }

  Future<void> _restore() async {
    try {
      // matrixServiceProvider is already scoped to whichever account is
      // active (see its doc comment); restoreSession() on the pending-id
      // service is simply a no-op (nothing persisted under that id yet)
      // when no account is active, so no extra gate is needed here.
      final userId = await ref.read(matrixServiceProvider).restoreSession();
      state = userId != null
          ? AuthAuthenticated(userId)
          : const AuthUnauthenticated();
    } on Object {
      state = const AuthUnauthenticated();
    }
  }

  /// Signs in under a fresh [SavedAccount] (added and made active on
  /// success), so the switcher can offer it alongside any other saved
  /// accounts.
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
      ref.read(accountsControllerProvider).add(SavedAccount(
            id: '${DateTime.now().microsecondsSinceEpoch}',
            label: userId,
            homeserverUrl: homeserverUrl,
            userId: userId,
          ));
      state = AuthAuthenticated(userId);
    } on Object catch (error) {
      state = AuthUnauthenticated(friendlyLoginError(error));
    }
  }

  /// Signs out of and forgets the active account, then falls back to
  /// another saved account (restoring it) if one remains, else the login
  /// page.
  Future<void> signOut() async {
    final activeId = ref.read(activeAccountIdProvider);
    try {
      await ref.read(matrixServiceProvider).logout();
    } finally {
      if (activeId != null) {
        ref.read(accountsControllerProvider).forget(activeId);
      }
      if (ref.read(activeAccountIdProvider) == null) {
        state = const AuthUnauthenticated();
      } else {
        state = const AuthRestoring();
        await _restore();
      }
    }
  }

  /// Switches to a different saved account, restoring its session.
  Future<void> switchAccount(String accountId) async {
    if (ref.read(activeAccountIdProvider) == accountId) return;
    ref.read(accountsControllerProvider).switchTo(accountId);
    state = const AuthRestoring();
    await _restore();
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

/// End-to-end encryption status for a room, fetched on demand.
final roomEncryptionProvider =
    FutureProvider.family<bool, String>((ref, roomId) {
  return ref.watch(matrixServiceProvider).isRoomEncrypted(roomId);
});

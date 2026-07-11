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
  StreamSubscription<SessionProblem>? _sessionProblemSubscription;

  @override
  AuthState build() {
    ref.onDispose(() {
      unawaited(_sessionProblemSubscription?.cancel());
    });
    if (!matrixRuntimeSupported) return const AuthUnauthenticated();
    Future.microtask(_restore);
    return const AuthRestoring();
  }

  Future<void> _restore() async {
    await _sessionProblemSubscription?.cancel();
    _sessionProblemSubscription = null;
    try {
      await ref.read(accountsLoaderProvider.future);
      final account = ref.read(activeAccountProvider);
      if (account == null) {
        state = const AuthUnauthenticated();
        return;
      }

      // matrixServiceProvider is scoped to the active saved account. Do not
      // restore from the transient pending id at startup: old builds could
      // leave a session there, but it is not a real saved account.
      final userId = await ref.read(matrixServiceProvider).restoreSession();
      if (userId != null) {
        _setAuthenticated(userId);
      } else {
        state = _reauthState(
          account,
          'Sign in again to reconnect this saved account.',
        );
      }
    } on Object catch (error) {
      final account = ref.read(activeAccountProvider);
      state = account == null
          ? const AuthUnauthenticated()
          : _recoveryStateFor(account, error);
    }
  }

  void _setAuthenticated(String userId) {
    state = AuthAuthenticated(userId);
    final accountId = ref.read(activeAccountIdProvider);
    final account = ref.read(activeAccountProvider);
    final service = ref.read(matrixServiceProvider);
    unawaited(_sessionProblemSubscription?.cancel());
    _sessionProblemSubscription = service.sessionProblems.listen((problem) {
      if (ref.read(activeAccountIdProvider) != accountId) return;
      final current = ref.read(activeAccountProvider) ?? account;
      if (current == null) return;
      state = problem.requiresReauth
          ? _reauthState(current, problem.message)
          : _reconnectState(current, problem.message);
    });
  }

  AuthState _recoveryStateFor(SavedAccount account, Object error) {
    final message = friendlySessionProblem(error);
    return isInvalidMatrixSessionError(error)
        ? _reauthState(account, message)
        : _reconnectState(account, message);
  }

  AuthNeedsReauth _reauthState(SavedAccount account, String message) {
    return AuthNeedsReauth(
      accountId: account.id,
      label: account.label,
      homeserverUrl: account.homeserverUrl,
      userId: account.userId,
      message: message,
    );
  }

  AuthNeedsReconnect _reconnectState(SavedAccount account, String message) {
    return AuthNeedsReconnect(
      accountId: account.id,
      label: account.label,
      homeserverUrl: account.homeserverUrl,
      userId: account.userId,
      message: message,
    );
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
    final previousActiveId = ref.read(activeAccountIdProvider);
    final account = SavedAccount(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      label: username.trim().isEmpty ? homeserverUrl : username.trim(),
      homeserverUrl: homeserverUrl,
    );
    ref.read(accountsControllerProvider).add(account);
    try {
      final userId = await ref
          .read(matrixServiceProvider)
          .login(
            homeserverUrl: homeserverUrl,
            username: username,
            password: password,
          );
      ref
          .read(accountsControllerProvider)
          .update(
            account.copyWith(
              label: userId,
              homeserverUrl: homeserverUrl,
              userId: userId,
            ),
          );
      _setAuthenticated(userId);
    } on Object catch (error) {
      ref.read(accountsControllerProvider).forget(account.id);
      if (previousActiveId != null &&
          ref
              .read(accountsProvider)
              .any((account) => account.id == previousActiveId)) {
        ref.read(accountsControllerProvider).switchTo(previousActiveId);
      }
      state = AuthUnauthenticated(friendlyLoginError(error));
    }
  }

  /// Re-authenticates the active saved account without creating a duplicate
  /// switcher entry.
  Future<void> reauthenticateActive({
    required String username,
    required String password,
  }) async {
    if (state is AuthAuthenticating) return;
    final account = ref.read(activeAccountProvider);
    if (account == null) {
      state = const AuthUnauthenticated();
      return;
    }
    state = const AuthAuthenticating();
    try {
      final userId = await ref
          .read(matrixServiceProvider)
          .login(
            homeserverUrl: account.homeserverUrl,
            username: username,
            password: password,
          );
      ref
          .read(accountsControllerProvider)
          .update(account.copyWith(label: userId, userId: userId));
      _setAuthenticated(userId);
    } on Object catch (error) {
      state = _reauthState(account, friendlyLoginError(error));
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

  /// Retries restore/sync for the currently selected saved account.
  Future<void> reconnectActive() async {
    if (state is AuthRestoring || state is AuthAuthenticating) return;
    state = const AuthRestoring();
    await _restore();
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);

/// The logged-in user's Matrix ID (from whoami at session start), else null.
final currentUserIdProvider = Provider<String?>((ref) {
  final auth = ref.watch(authControllerProvider);
  return auth is AuthAuthenticated ? auth.userId : null;
});

/// Room selected in the two-pane layout. Null when no room is open.
///
/// Selection is scoped to the active account. Wide mode keeps the chat pane
/// mounted beside the room list, so switching accounts must discard any room
/// chosen under the previous homeserver/account before providers below rebuild.
final selectedRoomIdProvider = StateProvider<String?>((ref) {
  ref.watch(activeAccountIdProvider);
  return null;
});

/// Joined rooms, refreshed whenever the sync thread delivers a message.
class RoomListController extends AsyncNotifier<List<RoomSummary>> {
  Timer? _refreshDebounce;

  @override
  Future<List<RoomSummary>> build() async {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated) return const <RoomSummary>[];

    final service = ref.watch(matrixServiceProvider);
    final subscription = service.messageEvents.listen(
      (_) => _scheduleRefresh(),
    );
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

/// Pending room invitations. Refreshed periodically because invite sync state
/// can change without producing a user-visible timeline message event.
class RoomInvitesController extends AsyncNotifier<List<RoomInvite>> {
  Timer? _refreshTimer;

  @override
  Future<List<RoomInvite>> build() async {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated) return const <RoomInvite>[];

    final service = ref.watch(matrixServiceProvider);
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => refresh(),
    );
    ref.onDispose(() => _refreshTimer?.cancel());
    return service.invitedRooms();
  }

  Future<void> refresh() async {
    if (ref.read(authControllerProvider) is! AuthAuthenticated) return;
    try {
      final invites = await ref.read(matrixServiceProvider).invitedRooms();
      state = AsyncData(invites);
    } on Object {
      // Keep showing the previous invite list; the timer or user action retries.
    }
  }
}

final roomInvitesProvider =
    AsyncNotifierProvider<RoomInvitesController, List<RoomInvite>>(
      RoomInvitesController.new,
    );

/// Joined member user IDs for a room, fetched on demand (room-info view).
final roomMembersProvider = FutureProvider.family<List<String>, String>((
  ref,
  roomId,
) {
  return ref.watch(matrixServiceProvider).roomMembers(roomId);
});

/// Stable identity details for a room, fetched on demand (room-info view).
final roomDetailsProvider = FutureProvider.family<RoomDetails, String>((
  ref,
  roomId,
) {
  return ref.watch(matrixServiceProvider).roomDetails(roomId);
});

/// End-to-end encryption status for a room, fetched on demand.
final roomEncryptionProvider = FutureProvider.family<bool, String>((
  ref,
  roomId,
) {
  return ref.watch(matrixServiceProvider).isRoomEncrypted(roomId);
});

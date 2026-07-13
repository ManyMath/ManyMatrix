import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';

import '../platform/runtime.dart';
import '../platform/homeserver_policy.dart';
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
  Future<void> _operationTail = Future<void>.value();
  int _operationGeneration = 0;
  bool _disposed = false;

  @override
  AuthState build() {
    ref.onDispose(() {
      _disposed = true;
      _operationGeneration += 1;
      unawaited(_sessionProblemSubscription?.cancel());
    });
    if (!matrixRuntimeSupported) return const AuthUnauthenticated();
    unawaited(_serialize(_restore).catchError((_) {}));
    return const AuthRestoring();
  }

  Future<T> _serialize<T>(Future<T> Function(int generation) operation) {
    final result = Completer<T>();
    final predecessor = _operationTail;
    final scheduled = () async {
      try {
        await predecessor;
      } on Object {
        // A failed operation must not poison the account-mutation queue.
      }
      if (_disposed) {
        result.completeError(StateError('Authentication controller disposed'));
        return;
      }
      final generation = ++_operationGeneration;
      try {
        result.complete(await operation(generation));
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    }();
    _operationTail = scheduled;
    return result.future;
  }

  bool _isCurrent(int generation, {String? accountId, MatrixService? service}) {
    if (_disposed || generation != _operationGeneration) return false;
    if (accountId != null && ref.read(activeAccountIdProvider) != accountId) {
      return false;
    }
    if (service != null &&
        !identical(ref.read(matrixServiceProvider), service)) {
      return false;
    }
    return true;
  }

  Future<void> _cancelSessionProblemSubscription() async {
    final subscription = _sessionProblemSubscription;
    _sessionProblemSubscription = null;
    try {
      await subscription?.cancel();
    } on Object {
      // Session teardown is best effort; the generation guard also makes a
      // late event from the old subscription harmless.
    }
  }

  Future<void> _suspendService(MatrixService service) async {
    if (service is SuspendableMatrixService) {
      await (service as SuspendableMatrixService).suspend();
    }
  }

  Future<void> _restore(int generation, {String? expectedAccountId}) async {
    await _cancelSessionProblemSubscription();
    if (!_isCurrent(generation)) return;
    SavedAccount? account;
    MatrixService? service;
    try {
      await ref.read(accountsLoaderProvider.future);
      if (!_isCurrent(generation)) return;
      account = ref.read(activeAccountProvider);
      if (account == null) {
        state = const AuthUnauthenticated();
        return;
      }
      if (account.localCleanupRequired) {
        state = _reconnectState(
          account,
          'Saved data for this account is invalid. Use Accounts > Forget to purge it from this browser.',
        );
        return;
      }
      if (expectedAccountId != null && account.id != expectedAccountId) return;

      // matrixServiceProvider is scoped to the active saved account. Do not
      // restore from the transient pending id at startup: old builds could
      // leave a session there, but it is not a real saved account.
      final restoringService = ref.read(matrixServiceProvider);
      service = restoringService;
      final userId = await restoringService.restoreSession();
      if (!_isCurrent(generation, accountId: account.id, service: service)) {
        return;
      }
      if (userId != null) {
        if (account.userId != null && account.userId != userId) {
          Object? cleanupError;
          try {
            await restoringService.logout();
          } on Object catch (error) {
            cleanupError = error;
            try {
              await restoringService.clearSavedSession(keepHomeserver: true);
            } on Object catch (error) {
              cleanupError = error;
            }
          }
          if (!_isCurrent(
            generation,
            accountId: account.id,
            service: service,
          )) {
            return;
          }
          state = _reauthState(
            account,
            'The saved session belongs to $userId, not ${account.userId}. Sign in again with the saved account.'
            '${cleanupError == null ? '' : ' Local session cleanup did not complete; use Accounts > Forget to retry.'}',
          );
          return;
        }
        await _setAuthenticated(
          userId,
          generation: generation,
          accountId: account.id,
          service: service,
        );
      } else {
        state = _reauthState(
          account,
          'Sign in again to reconnect this saved account.',
        );
      }
    } on Object catch (error) {
      if (!_isCurrent(generation, accountId: account?.id, service: service)) {
        return;
      }
      account ??= ref.read(activeAccountProvider);
      final restoredDeviceId = service is ReauthenticatingMatrixService
          ? (service as ReauthenticatingMatrixService).currentDeviceId
          : null;
      if (account != null &&
          restoredDeviceId != null &&
          account.deviceId != restoredDeviceId) {
        await ref
            .read(accountsControllerProvider)
            .update(account.copyWith(deviceId: restoredDeviceId));
        account = ref.read(activeAccountProvider) ?? account;
      }
      state = account == null
          ? const AuthUnauthenticated()
          : _recoveryStateFor(account, error);
    }
  }

  Future<void> _setAuthenticated(
    String userId, {
    required int generation,
    required String accountId,
    required MatrixService service,
  }) async {
    await _cancelSessionProblemSubscription();
    if (!_isCurrent(generation, accountId: accountId, service: service)) {
      return;
    }
    var account = ref.read(activeAccountProvider);
    final deviceId = service is ReauthenticatingMatrixService
        ? (service as ReauthenticatingMatrixService).currentDeviceId
        : null;
    if (account != null && deviceId != null && account.deviceId != deviceId) {
      await ref
          .read(accountsControllerProvider)
          .update(account.copyWith(deviceId: deviceId));
      if (!_isCurrent(generation, accountId: accountId, service: service)) {
        return;
      }
      account = ref.read(activeAccountProvider) ?? account;
    }
    state = AuthAuthenticated(userId);
    _sessionProblemSubscription = service.sessionProblems.listen((problem) {
      if (!_isCurrent(generation, accountId: accountId, service: service)) {
        return;
      }
      if (state is! AuthAuthenticated) return;
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
  Future<String?> signIn({
    required String homeserverUrl,
    required String username,
    required String password,
    bool restorePreviousAccountOnFailure = false,
  }) {
    return _serialize((generation) async {
      state = const AuthAuthenticating();
      final canonicalHomeserver = canonicalHomeserverUrl(homeserverUrl);
      if (canonicalHomeserver == null) {
        const message =
            'Enter a homeserver URL without credentials, query parameters, or a fragment.';
        state = const AuthUnauthenticated(message);
        return message;
      }
      final previousActiveId = ref.read(activeAccountIdProvider);
      final previousService = ref.read(matrixServiceProvider);
      final account = SavedAccount(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        label: username.trim().isEmpty ? canonicalHomeserver : username.trim(),
        homeserverUrl: canonicalHomeserver,
      );
      MatrixService? service;
      try {
        await _cancelSessionProblemSubscription();
        await _suspendService(previousService);
        if (!_isCurrent(generation)) {
          return 'The active account changed while signing in. Try again.';
        }
        await ref.read(accountsControllerProvider).add(account);
        if (!_isCurrent(generation, accountId: account.id)) {
          return 'The active account changed while signing in. Try again.';
        }
        final loginService = ref.read(matrixServiceProvider);
        service = loginService;
        final userId = await loginService.login(
          homeserverUrl: canonicalHomeserver,
          username: username,
          password: password,
        );
        if (!_isCurrent(
          generation,
          accountId: account.id,
          service: loginService,
        )) {
          return 'The active account changed while signing in. Try again.';
        }
        await ref
            .read(accountsControllerProvider)
            .update(
              account.copyWith(
                label: userId,
                homeserverUrl: canonicalHomeserver,
                userId: userId,
                deviceId: loginService is ReauthenticatingMatrixService
                    ? (loginService as ReauthenticatingMatrixService)
                          .currentDeviceId
                    : null,
                localCleanupRequired: false,
              ),
            );
        await _setAuthenticated(
          userId,
          generation: generation,
          accountId: account.id,
          service: loginService,
        );
        return null;
      } on Object catch (error) {
        var message = friendlyLoginError(error);
        try {
          await service?.logout();
        } on Object {
          // The account cleaner below remains authoritative for local state.
        }
        try {
          await ref.read(accountsControllerProvider).forget(account.id);
        } on Object {
          message = '$message ${_cleanupRetryMessage(account)}';
          // The account remains saved so Accounts > Forget can retry cleanup.
        }
        if (!_isCurrent(generation)) return message;
        final canRestorePrevious =
            previousActiveId != null &&
            ref
                .read(accountsProvider)
                .any((saved) => saved.id == previousActiveId);
        if (canRestorePrevious) {
          await ref.read(accountsControllerProvider).switchTo(previousActiveId);
        }
        if (restorePreviousAccountOnFailure && canRestorePrevious) {
          state = const AuthRestoring();
          await _restore(generation, expectedAccountId: previousActiveId);
        } else {
          state = AuthUnauthenticated(message);
        }
        return message;
      }
    });
  }

  /// Re-authenticates the active saved account without creating a duplicate
  /// switcher entry.
  Future<void> reauthenticateActive({
    required String username,
    required String password,
  }) {
    return _serialize((generation) async {
      final account = ref.read(activeAccountProvider);
      if (account == null) {
        state = const AuthUnauthenticated();
        return;
      }
      state = const AuthAuthenticating();
      final service = ref.read(matrixServiceProvider);
      try {
        final deviceId = account.deviceId;
        final userId =
            service is ReauthenticatingMatrixService && deviceId != null
            ? await (service as ReauthenticatingMatrixService).reauthenticate(
                homeserverUrl: account.homeserverUrl,
                username: username,
                password: password,
                deviceId: deviceId,
              )
            : await service.login(
                homeserverUrl: account.homeserverUrl,
                username: username,
                password: password,
              );
        if (!_isCurrent(generation, accountId: account.id, service: service)) {
          return;
        }
        if (account.userId != null && account.userId != userId) {
          try {
            await service.logout();
          } on Object {
            // The identity mismatch is the actionable failure.
          }
          if (_isCurrent(generation, accountId: account.id, service: service)) {
            state = _reauthState(
              account,
              'Those credentials belong to $userId, not ${account.userId}. Sign in with the saved account.',
            );
          }
          return;
        }
        final currentDeviceId = service is ReauthenticatingMatrixService
            ? (service as ReauthenticatingMatrixService).currentDeviceId
            : deviceId;
        await ref
            .read(accountsControllerProvider)
            .update(
              account.copyWith(
                label: userId,
                userId: userId,
                deviceId: currentDeviceId,
                localCleanupRequired: false,
              ),
            );
        await _setAuthenticated(
          userId,
          generation: generation,
          accountId: account.id,
          service: service,
        );
      } on Object catch (error) {
        if (_isCurrent(generation, accountId: account.id, service: service)) {
          state = _reauthState(account, friendlyLoginError(error));
        }
      }
    });
  }

  /// Signs out of and forgets the active account, then falls back to
  /// another saved account (restoring it) if one remains, else the login
  /// page.
  Future<void> signOut() {
    return _serialize((generation) async {
      final account = ref.read(activeAccountProvider);
      final service = ref.read(matrixServiceProvider);
      state = const AuthRestoring();
      try {
        await service.logout();
      } on Object {
        // Remote logout is best effort. Account cleanup below is authoritative
        // for whether local data was removed.
      }
      if (!_isCurrent(generation)) return;
      if (account != null) {
        try {
          await ref.read(accountsControllerProvider).forget(account.id);
        } on Object {
          if (_isCurrent(generation)) {
            state = AuthUnauthenticated(_cleanupRetryMessage(account));
          }
          return;
        }
      }
      if (!_isCurrent(generation)) return;
      final nextAccountId = ref.read(activeAccountIdProvider);
      if (nextAccountId == null) {
        state = const AuthUnauthenticated();
      } else {
        state = const AuthRestoring();
        await _restore(generation, expectedAccountId: nextAccountId);
      }
    });
  }

  /// Switches to a different saved account, restoring its session.
  Future<void> switchAccount(String accountId) {
    return _serialize((generation) async {
      if (ref.read(activeAccountIdProvider) == accountId) return;
      if (!ref
          .read(accountsProvider)
          .any((account) => account.id == accountId)) {
        return;
      }
      state = const AuthRestoring();
      await _cancelSessionProblemSubscription();
      final previousService = ref.read(matrixServiceProvider);
      await _suspendService(previousService);
      if (!_isCurrent(generation, service: previousService)) return;
      await ref.read(accountsControllerProvider).switchTo(accountId);
      await _restore(generation, expectedAccountId: accountId);
    });
  }

  /// Retries restore/sync for the currently selected saved account.
  Future<void> reconnectActive() {
    return _serialize((generation) async {
      final accountId = ref.read(activeAccountIdProvider);
      state = const AuthRestoring();
      await _restore(generation, expectedAccountId: accountId);
    });
  }

  String _cleanupRetryMessage(SavedAccount account) {
    return 'You are signed out, but ManyMatrix could not remove local data for '
        '${account.label}. Close other ManyMatrix tabs, then use Accounts > '
        'Forget to retry.';
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
  int _generation = 0;
  int _refreshRequest = 0;
  final _optimisticRoomNames = <String, String>{};
  final _forgottenRoomIds = <String>{};

  @override
  Future<List<RoomSummary>> build() async {
    final generation = ++_generation;
    final request = ++_refreshRequest;
    _optimisticRoomNames.clear();
    _forgottenRoomIds.clear();
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated) return const <RoomSummary>[];

    final service = ref.watch(matrixServiceProvider);
    final subscription = service.messageEvents.listen(
      (_) => _scheduleRefresh(),
    );
    ref.onDispose(() {
      _generation += 1;
      subscription.cancel();
      _refreshDebounce?.cancel();
    });
    final rooms = await service.joinedRooms();
    if (generation != _generation ||
        request != _refreshRequest ||
        !identical(ref.read(matrixServiceProvider), service)) {
      return const <RoomSummary>[];
    }
    return _mergeOptimisticRooms(rooms);
  }

  /// Coalesces bursts of sync events into one re-fetch.
  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 250), refresh);
  }

  Future<void> refresh() async {
    if (ref.read(authControllerProvider) is! AuthAuthenticated) return;
    final generation = _generation;
    final request = ++_refreshRequest;
    final service = ref.read(matrixServiceProvider);
    try {
      final rooms = await service.joinedRooms();
      if (generation != _generation ||
          request != _refreshRequest ||
          !identical(ref.read(matrixServiceProvider), service) ||
          ref.read(authControllerProvider) is! AuthAuthenticated) {
        return;
      }
      state = AsyncData(_mergeOptimisticRooms(rooms));
    } on Object {
      // Keep showing the previous list; the next sync event retries.
    }
  }

  /// Keeps a newly created or joined room usable while the SDK catches up
  /// with the server response and its display name.
  void rememberRoom(String roomId, String displayName) {
    final trimmedName = displayName.trim();
    final name = trimmedName.isEmpty ? roomId : trimmedName;
    _forgottenRoomIds.remove(roomId);
    _optimisticRoomNames[roomId] = name;
    state = AsyncData(
      _mergeOptimisticRooms(state.valueOrNull ?? const <RoomSummary>[]),
    );
  }

  /// Hides a successfully left room until the SDK confirms it is absent.
  void forgetRoom(String roomId) {
    _optimisticRoomNames.remove(roomId);
    _forgottenRoomIds.add(roomId);
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(
      current.where((room) => room.roomId != roomId).toList(growable: false),
    );
  }

  List<RoomSummary> _mergeOptimisticRooms(List<RoomSummary> rooms) {
    final seen = <String>{};
    final merged = <RoomSummary>[];
    for (final room in rooms) {
      seen.add(room.roomId);
      if (_forgottenRoomIds.contains(room.roomId)) continue;
      final optimisticName = _optimisticRoomNames[room.roomId];
      if (optimisticName == null) {
        merged.add(room);
        continue;
      }
      if (room.isSynced || room.displayName == optimisticName) {
        _optimisticRoomNames.remove(room.roomId);
        merged.add(room);
        continue;
      }
      merged.add(
        RoomSummary(
          roomId: room.roomId,
          displayName: optimisticName,
          avatarUrl: room.avatarUrl,
          lastMessage: room.lastMessage,
          unreadCount: room.unreadCount,
          isSynced: room.isSynced,
        ),
      );
    }
    _forgottenRoomIds.removeWhere((roomId) => !seen.contains(roomId));
    for (final entry in _optimisticRoomNames.entries) {
      if (seen.contains(entry.key)) continue;
      merged.add(
        RoomSummary(
          roomId: entry.key,
          displayName: entry.value,
          unreadCount: 0,
          isSynced: false,
        ),
      );
    }
    return merged;
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
  int _generation = 0;
  int _refreshRequest = 0;

  @override
  Future<List<RoomInvite>> build() async {
    final generation = ++_generation;
    final request = ++_refreshRequest;
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated) return const <RoomInvite>[];

    final service = ref.watch(matrixServiceProvider);
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => refresh(),
    );
    ref.onDispose(() {
      _generation += 1;
      _refreshTimer?.cancel();
    });
    final invites = await service.invitedRooms();
    if (generation != _generation ||
        request != _refreshRequest ||
        !identical(ref.read(matrixServiceProvider), service)) {
      return const <RoomInvite>[];
    }
    return invites;
  }

  Future<void> refresh() async {
    if (ref.read(authControllerProvider) is! AuthAuthenticated) return;
    final generation = _generation;
    final request = ++_refreshRequest;
    final service = ref.read(matrixServiceProvider);
    try {
      final invites = await service.invitedRooms();
      if (generation != _generation ||
          request != _refreshRequest ||
          !identical(ref.read(matrixServiceProvider), service) ||
          ref.read(authControllerProvider) is! AuthAuthenticated) {
        return;
      }
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

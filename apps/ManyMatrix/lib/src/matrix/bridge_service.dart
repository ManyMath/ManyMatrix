import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:manymatrix/manymatrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/runtime.dart';
import '../platform/homeserver_policy.dart';
import 'events.dart';

/// Facade over the manymatrix FFI bridge that the rest of the app talks to.
///
/// UI and providers depend on this interface only, so tests can substitute a
/// fake without touching FFI.
abstract class MatrixService {
  /// Typed message events from the background sync thread. Broadcast.
  Stream<MessageEvent> get messageEvents;

  /// Typed reaction events from the background sync thread. Broadcast.
  Stream<ReactionEvent> get reactionEvents;

  /// Typed read-receipt events from the background sync thread. Broadcast.
  Stream<ReceiptEvent> get receiptEvents => const Stream<ReceiptEvent>.empty();

  /// Background sync/auth failures that require user recovery. Broadcast.
  Stream<SessionProblem> get sessionProblems;

  /// The logged-in user's Matrix ID, or null when logged out.
  String? get currentUserId;

  /// Restores a persisted session. Returns the user ID on success, null when
  /// no session is stored. Starts background sync on success.
  Future<String?> restoreSession();

  /// Logs in, persists the session, and starts background sync.
  /// Returns the user ID.
  Future<String> login({
    required String homeserverUrl,
    required String username,
    required String password,
  });

  /// Logs out server-side (best effort), clears the persisted session, and
  /// releases the client.
  Future<void> logout();

  /// Drops the persisted session secret. When [keepHomeserver] is true, the
  /// account remains reconnectable/re-authenticatable from the switcher.
  Future<void> clearSavedSession({bool keepHomeserver = true});

  Future<List<RoomSummary>> joinedRooms();

  Future<List<RoomInvite>> invitedRooms();

  /// Creates a new room with optional name and topic. Returns the new room's
  /// ID.
  Future<String> createRoom({String? name, String? topic});

  /// Joins a room by ID or alias. Returns the (possibly resolved) room ID.
  Future<String> joinRoom(String roomIdOrAlias);

  /// Leaves or declines a room membership.
  Future<void> leaveRoom(String roomId);

  /// Invites a user to a room.
  Future<void> invite(String roomId, String userId);

  Future<PaginatedMessages> getMessages(
    String roomId, {
    String? fromToken,
    int limit = 50,
  });

  Future<String> sendText(String roomId, String body);

  Future<String> sendHtml(String roomId, String body, String html);

  Future<String> sendNotice(String roomId, String body);

  Future<String> sendEmote(String roomId, String body);

  /// Uploads [data] and sends it as an attachment in [roomId].
  Future<String> uploadMedia(
    String roomId,
    String filename,
    String mimeType,
    Uint8List data,
  );

  /// Downloads an `mxc://` attachment, or returns null when it has no body.
  Future<Uint8List?> downloadMedia(String mxcUri);

  /// Downloads from a complete Matrix media source, including E2EE metadata.
  /// Plain-source fallback keeps existing fake/native service implementations
  /// source-compatible.
  Future<Uint8List?> downloadMediaSource(Map<String, dynamic> mediaSource) {
    final mxcUri = mediaSource['url'];
    if (mxcUri is String) return downloadMedia(mxcUri);
    throw UnsupportedError('Encrypted attachment downloads are unavailable.');
  }

  Future<void> editMessage(String roomId, String eventId, String newBody);

  Future<String> replyTo(String roomId, String eventId, String body);

  Future<String> sendThreadReply(
    String roomId,
    String threadRootId,
    String body, {
    String? inReplyToEventId,
  });

  Future<void> sendTyping(String roomId, bool typing);

  Future<void> sendReadReceipt(String roomId, String eventId);

  /// The joined member user IDs for a room.
  Future<List<String>> roomMembers(String roomId);

  /// Stable room identity details.
  Future<RoomDetails> roomDetails(String roomId);

  /// Whether end-to-end encryption is enabled for [roomId].
  Future<bool> isRoomEncrypted(String roomId);

  /// Enables end-to-end encryption for [roomId].
  Future<void> enableEncryption(String roomId);

  /// Removes [userId] from [roomId], optionally recording a reason.
  Future<void> kick(String roomId, String userId, {String? reason});

  /// Bans [userId] from [roomId], optionally recording a reason.
  Future<void> ban(String roomId, String userId, {String? reason});

  /// Redacts (deletes) [eventId] in [roomId], optionally recording a reason.
  Future<void> redact(String roomId, String eventId, {String? reason});

  /// Releases native resources. The service must not be used afterwards.
  void dispose();
}

/// Optional server-backed thread discovery, pagination, and read receipts.
/// Keeping this separate preserves compatibility with custom MatrixService
/// implementations while allowing the UI to degrade gracefully.
abstract interface class ThreadMatrixService {
  Future<List<ThreadSummary>> threadIndex({int limitPerRoom = 50});

  Future<PaginatedThreadMessages> getThreadMessages(
    String roomId,
    String threadRootEventId, {
    String? fromToken,
    int limit = 50,
  });

  Future<void> sendThreadReadReceipt(
    String roomId,
    String threadRootEventId,
    String eventId,
  );
}

/// Optional lifecycle implemented by services that can close their live
/// sync/client without deleting the saved account session.
abstract interface class SuspendableMatrixService {
  Future<void> suspend();
}

abstract interface class ReauthenticatingMatrixService {
  String? get currentDeviceId;

  Future<String> reauthenticate({
    required String homeserverUrl,
    required String username,
    required String password,
    required String deviceId,
  });
}

class InvalidPersistedMatrixSession implements Exception {
  const InvalidPersistedMatrixSession(this.message);

  final String message;

  @override
  String toString() => message;
}

void validatePersistedSessionHomeserver(
  String sessionJson,
  String expectedHomeserverUrl,
) {
  final expected = canonicalHomeserverUrl(expectedHomeserverUrl);
  try {
    final decoded = jsonDecode(sessionJson);
    final stored = decoded is Map ? decoded['homeserver'] : null;
    final canonicalStored = stored is String
        ? canonicalHomeserverUrl(stored)
        : null;
    if (expected == null || canonicalStored != expected) {
      throw const InvalidPersistedMatrixSession(
        'The saved Matrix session belongs to a different homeserver.',
      );
    }
  } on InvalidPersistedMatrixSession {
    rethrow;
  } on Object {
    throw const InvalidPersistedMatrixSession(
      'The saved Matrix session is invalid.',
    );
  }
}

String? persistedSessionDeviceId(String sessionJson) {
  try {
    final decoded = jsonDecode(sessionJson);
    final deviceId = decoded is Map ? decoded['device_id'] : null;
    return deviceId is String && deviceId.isNotEmpty ? deviceId : null;
  } on Object {
    return null;
  }
}

Future<void> clearPersistedSessionRevocationAware({
  Future<void> Function()? clearLiveSession,
  required Future<void> Function() clearStoredSession,
}) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  if (clearLiveSession != null) {
    try {
      await clearLiveSession();
    } on Object catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
  }
  try {
    await clearStoredSession();
  } on Object catch (error, stackTrace) {
    firstError ??= error;
    firstStackTrace ??= stackTrace;
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}

Future<void> cleanupFailedLoginClient({
  required bool authenticated,
  required Future<void> Function() revokeRemoteSession,
  required Future<void> Function() closeClient,
  required Future<void> Function() clearClientSession,
  required Future<void> Function() clearAccountSession,
}) async {
  if (authenticated) {
    try {
      await revokeRemoteSession();
    } on Object {
      // Startup's original error is more actionable than cleanup failures.
    }
  }
  for (final cleanup in <Future<void> Function()>[
    closeClient,
    clearClientSession,
    clearAccountSession,
  ]) {
    try {
      await cleanup();
    } on Object {
      // Best effort: callers preserve and rethrow the startup failure.
    }
  }
}

class SessionProblem {
  const SessionProblem({
    required this.message,
    required this.requiresReauth,
    this.error,
  });

  final String message;
  final bool requiresReauth;
  final Object? error;
}

/// Rejects delayed session-refresh callbacks once an account starts closing.
class SessionWriteGuard {
  int _generation = 0;
  bool _closing = true;

  int open() {
    _closing = false;
    return ++_generation;
  }

  void close() {
    _closing = true;
    _generation += 1;
  }

  bool accepts(int generation) => !_closing && generation == _generation;

  bool wasRevokedBy(int generation) =>
      _closing && _generation == generation + 1;
}

Future<void> writeSessionIfCurrent({
  required SessionWriteGuard guard,
  required int generation,
  required Future<void> Function() write,
  required Future<void> Function() remove,
}) async {
  if (!guard.accepts(generation)) return;
  await write();
  if (!guard.accepts(generation)) await remove();
}

class SessionPersistenceQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> run(Future<void> Function() operation) {
    final previous = _tail;
    final scheduled = () async {
      try {
        await previous;
      } on Object {
        // A later session rotation must be able to repair persistence.
      }
      await operation();
    }();
    _tail = scheduled.then<void>((_) {}, onError: (_, __) {});
    return scheduled;
  }

  Future<void> drain() async {
    try {
      await _tail;
    } on Object {
      // The operation's original caller observes the persistence error.
    }
  }
}

/// Holds one bridge client and drains it before a replacement is installed.
/// Keeping this small contract separate makes the no-overlap ordering testable
/// without loading a native library or browser Worker.
class BridgeClientSlot<T> {
  T? current;

  T? take() {
    final value = current;
    current = null;
    return value;
  }

  Future<void> drain(Future<void> Function(T client) close) async {
    final previous = take();
    if (previous != null) await close(previous);
  }
}

bool isInvalidMatrixSessionError(Object error) {
  if (error is InvalidPersistedMatrixSession) return true;
  final raw = error.toString();
  final lower = raw.toLowerCase();
  if (error is ManyMatrixException) {
    final errcode = '${error.details['errcode'] ?? ''}'.toUpperCase();
    if (errcode == 'M_UNKNOWN_TOKEN') return true;
  }
  return lower.contains('m_unknown_token') ||
      lower.contains('unknown token') ||
      lower.contains('refresh token') ||
      lower.contains('missing refresh token') ||
      lower.contains('invalid token');
}

String friendlySessionProblem(Object error) {
  if (isInvalidMatrixSessionError(error)) {
    return 'Your Matrix session expired. Sign in again to reconnect this account.';
  }
  if (error is ManyMatrixStorageException &&
      error.details['reason'] == 'store_active_in_another_tab') {
    return 'This Matrix account is active in another browser tab. Close that tab before reconnecting.';
  }
  return 'Matrix sync stopped. Check your connection and reconnect.';
}

/// Production [MatrixService] backed by [ManyMatrixBridge].
///
/// Scoped to one saved account, identified by [accountId]: its persisted
/// session and on-disk store path are namespaced under that id, so that
/// switching accounts (a fresh instance per account, one live at a time,
/// see `matrixServiceProvider`) never shares state between accounts.
///
/// Owns the bridge lifecycle: `initialize` once per process, `create` per
/// session, callback registration, `syncForever` after auth, and `dispose`.
class BridgeMatrixService
    implements
        MatrixService,
        ThreadMatrixService,
        SuspendableMatrixService,
        ReauthenticatingMatrixService {
  BridgeMatrixService({required String accountId}) : _accountId = accountId;

  final String _accountId;

  static bool _bridgeInitialized = false;

  String get _prefsHomeserverKey => 'manymatrix.$_accountId.homeserver';
  String get _prefsSessionKey => 'manymatrix.$_accountId.session';

  final _clientSlot = BridgeClientSlot<ManyMatrixBridge>();
  ManyMatrixBridge? get _client => _clientSlot.current;
  set _client(ManyMatrixBridge? value) => _clientSlot.current = value;
  String? _userId;
  String? _deviceId;
  final SessionWriteGuard _sessionWrites = SessionWriteGuard();
  final SessionPersistenceQueue _sessionPersistence = SessionPersistenceQueue();

  final _rawMessages = StreamController<String>.broadcast();
  final _rawReactions = StreamController<String>.broadcast();
  final _rawReceipts = StreamController<String>.broadcast();
  final _sessionProblems = StreamController<SessionProblem>.broadcast();
  late final Stream<MessageEvent> _messageEvents = messageEventStream(
    _rawMessages.stream,
  ).asBroadcastStream();
  late final Stream<ReactionEvent> _reactionEvents = reactionEventStream(
    _rawReactions.stream,
  ).asBroadcastStream();
  late final Stream<ReceiptEvent> _receiptEvents = receiptEventStream(
    _rawReceipts.stream,
  ).asBroadcastStream();

  @override
  Stream<MessageEvent> get messageEvents => _messageEvents;

  @override
  Stream<ReactionEvent> get reactionEvents => _reactionEvents;

  @override
  Stream<ReceiptEvent> get receiptEvents => _receiptEvents;

  @override
  Stream<SessionProblem> get sessionProblems => _sessionProblems.stream;

  @override
  String? get currentUserId => _userId;

  @override
  String? get currentDeviceId => _deviceId;

  Future<void> _ensureInitialized() async {
    if (_bridgeInitialized) return;
    await ManyMatrixBridge.initialize(defaultLibraryPath());
    _bridgeInitialized = true;
  }

  Future<ManyMatrixBridge> _createClient(String homeserverUrl) async {
    final canonicalHomeserver = canonicalHomeserverUrl(homeserverUrl);
    if (canonicalHomeserver == null) {
      throw StateError(
        'Homeserver URLs cannot contain credentials, queries, or fragments.',
      );
    }
    final securityError = homeserverSecurityError(canonicalHomeserver);
    if (securityError != null) throw StateError(securityError);
    _lastHomeserverUrl = canonicalHomeserver;
    await _ensureInitialized();
    return ManyMatrixBridge.create(
      canonicalHomeserver,
      defaultStorePath(_accountId),
    );
  }

  Future<void> _drainCurrentClient() async {
    _userId = null;
    _sessionWrites.close();
    final client = _clientSlot.take();
    // Web close detaches callbacks synchronously before its first await. Start
    // it before draining app-side persistence so dispose cannot close stream
    // controllers while a live Worker can still deliver events.
    final closingClient = client?.close();
    await _sessionPersistence.drain();
    await closingClient;
  }

  /// Wires callbacks and kicks off the background Rust sync thread.
  Future<void> _startSession(ManyMatrixBridge client) async {
    final generation = _sessionWrites.open();
    client.onMessage(_rawMessages.add);
    client.onReaction(_rawReactions.add);
    client.onReceipt(_rawReceipts.add);
    client.onSessionUpdate((sessionJson) {
      if (!_sessionWrites.accepts(generation)) return;
      unawaited(
        _persistSessionJson(sessionJson, generation: generation).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          _reportAsyncSessionProblem(
            generation,
            'ManyMatrix could not update the saved session.',
            error,
          );
        }),
      );
    });
    client.onSyncStatus((json) {
      if (!_sessionWrites.accepts(generation)) return;
      unawaited(
        _handleSyncStatus(json, generation).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          _reportAsyncSessionProblem(
            generation,
            'ManyMatrix could not process the sync status.',
            error,
          );
        }),
      );
    });
    _userId = await client.whoami();
    await _persistCurrentSession(client, generation: generation);
    await client.syncForever();
  }

  Future<void> _persistSessionJson(
    String sessionJson, {
    required int generation,
  }) async {
    if (matrixBridgeOwnsSessionPersistence) return;
    await _sessionPersistence.run(() async {
      if (!_sessionWrites.accepts(generation)) return;
      final prefs = await SharedPreferences.getInstance();
      if (!_sessionWrites.accepts(generation)) return;
      await writeSessionIfCurrent(
        guard: _sessionWrites,
        generation: generation,
        write: () async {
          await prefs.setString(_prefsSessionKey, sessionJson);
        },
        remove: () async {
          await prefs.remove(_prefsSessionKey);
        },
      );
    });
  }

  Future<void> _persistCurrentSession(
    ManyMatrixBridge client, {
    required int generation,
  }) async {
    if (matrixBridgeOwnsSessionPersistence) return;
    if (!_sessionWrites.accepts(generation)) return;
    final sessionJson = await client.currentSession();
    if (sessionJson != null && _sessionWrites.accepts(generation)) {
      await _persistSessionJson(sessionJson, generation: generation);
    }
  }

  Future<void> _handleSyncStatus(String json, int generation) async {
    if (!_sessionWrites.accepts(generation)) return;
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return;
    if (decoded['ok'] == true) {
      final client = _client;
      if (client != null && _sessionWrites.accepts(generation)) {
        await _persistCurrentSession(client, generation: generation);
      }
      return;
    }

    final error = _syncStatusError(decoded);
    final requiresReauth = isInvalidMatrixSessionError(error);
    Object? cleanupError;
    if (requiresReauth) {
      // Reject refresh callbacks before clearing storage. Native persistence
      // otherwise has a drain/remove/enqueue race that can resurrect a token.
      _sessionWrites.close();
      try {
        await clearSavedSession(keepHomeserver: true);
      } on Object catch (error) {
        cleanupError = error;
      }
    }
    final stillCurrent = requiresReauth
        ? _sessionWrites.wasRevokedBy(generation)
        : _sessionWrites.accepts(generation);
    if (!stillCurrent || _sessionProblems.isClosed) {
      return;
    }
    _sessionProblems.add(
      SessionProblem(
        message: cleanupError == null
            ? friendlySessionProblem(error)
            : '${friendlySessionProblem(error)} Local session cleanup did not complete; retry reconnect or Forget.',
        requiresReauth: requiresReauth,
        error: cleanupError ?? error,
      ),
    );
  }

  void _reportAsyncSessionProblem(
    int generation,
    String message,
    Object error,
  ) {
    if (!_sessionWrites.accepts(generation) || _sessionProblems.isClosed) {
      return;
    }
    _sessionProblems.add(
      SessionProblem(message: message, requiresReauth: false, error: error),
    );
  }

  Object _syncStatusError(Map<String, dynamic> status) {
    final message = status['error'] as String? ?? 'Background sync stopped';
    final details = <String, dynamic>{
      if (status['errorDetails'] is Map)
        ...(status['errorDetails'] as Map).map(
          (key, value) => MapEntry('$key', value),
        ),
      'state': status['state'],
      'method': 'sync_forever',
    };
    return manyMatrixExceptionForEnvelope(
      status['errorKind'] as String? ?? 'MatrixSdkError',
      message,
      details: details,
    );
  }

  @override
  Future<String?> restoreSession() async {
    if (!matrixRuntimeSupported) return null;
    await _drainCurrentClient();
    final prefs = await SharedPreferences.getInstance();
    final homeserverUrl = prefs.getString(_prefsHomeserverKey);
    final legacySessionJson = prefs.getString(_prefsSessionKey);
    if (matrixBridgeOwnsSessionPersistence && legacySessionJson != null) {
      // Read once into memory, then fail closed. A crash or failed migration
      // must not leave the raw access token in localStorage indefinitely.
      final removed = await prefs.remove(_prefsSessionKey);
      if (!removed) {
        throw StateError('Could not remove the legacy Matrix session.');
      }
    }
    if (homeserverUrl == null) {
      if (matrixBridgeOwnsSessionPersistence) {
        await prefs.remove(_prefsSessionKey);
      }
      return null;
    }

    final client = await _createClient(homeserverUrl);
    String? sessionJson;
    var migratingLegacySession = false;
    try {
      if (matrixBridgeOwnsSessionPersistence) {
        sessionJson = await client.loadPersistedSession();
        if (sessionJson == null && legacySessionJson != null) {
          migratingLegacySession = true;
          sessionJson = legacySessionJson;
          validatePersistedSessionHomeserver(sessionJson, homeserverUrl);
          await client.persistSession(legacySessionJson);
        }
      } else {
        sessionJson = legacySessionJson;
      }
      if (sessionJson == null) {
        try {
          await client.close();
        } on Object {
          // No session exists, so a failed close cannot make restore useful.
        }
        return null;
      }
      validatePersistedSessionHomeserver(sessionJson, homeserverUrl);
      _deviceId = persistedSessionDeviceId(sessionJson);
      await client.restore(sessionJson);
      _client = client;
      await _startSession(client);
    } on Object catch (error, stackTrace) {
      _client = null;
      _sessionWrites.close();
      try {
        await client.close();
      } on Object {
        // Preserve the actionable restore/migration failure.
      }
      if (migratingLegacySession || isInvalidMatrixSessionError(error)) {
        try {
          await clearSavedSession(keepHomeserver: true);
        } on Object {
          // Preserve the restore failure; reconnect cleanup remains retryable.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    return _userId;
  }

  @override
  Future<String> login({
    required String homeserverUrl,
    required String username,
    required String password,
  }) => _login(
    homeserverUrl: homeserverUrl,
    username: username,
    password: password,
  );

  @override
  Future<String> reauthenticate({
    required String homeserverUrl,
    required String username,
    required String password,
    required String deviceId,
  }) => _login(
    homeserverUrl: homeserverUrl,
    username: username,
    password: password,
    deviceId: deviceId,
  );

  Future<String> _login({
    required String homeserverUrl,
    required String username,
    required String password,
    String? deviceId,
  }) async {
    await _drainCurrentClient();
    final client = await _createClient(homeserverUrl);
    final canonicalHomeserver = _lastHomeserverUrl!;
    var authenticated = false;
    try {
      final sessionJson = await client.login(
        username,
        password,
        deviceId: deviceId,
      );
      authenticated = true;
      _deviceId = persistedSessionDeviceId(sessionJson);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsHomeserverKey, canonicalHomeserver);
      if (matrixBridgeOwnsSessionPersistence) {
        await prefs.remove(_prefsSessionKey);
      } else {
        // TODO(manymatrix): move native sessions to platform secure storage.
        await prefs.setString(_prefsSessionKey, sessionJson);
      }
      _client = client;
      await _startSession(client);
    } on Object catch (error, stackTrace) {
      _client = null;
      _sessionWrites.close();
      await cleanupFailedLoginClient(
        authenticated: authenticated,
        revokeRemoteSession: () => client.logout(clearPersistedSession: false),
        closeClient: client.close,
        clearClientSession: client.clearPersistedSession,
        clearAccountSession: () => clearSavedSession(keepHomeserver: false),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
    return _userId ?? username;
  }

  @override
  Future<void> logout() async {
    final client = _clientSlot.take();
    _userId = null;
    _sessionWrites.close();
    await _sessionPersistence.drain();
    if (client != null) {
      try {
        await client.logout(clearPersistedSession: false);
      } on Object {
        // Remote token invalidation is best effort; local teardown is mandatory.
      }
    }

    Object? cleanupError;
    StackTrace? cleanupStackTrace;
    Future<void> attempt(Future<void> Function() cleanup) async {
      try {
        await cleanup();
      } on Object catch (error, stackTrace) {
        cleanupError ??= error;
        cleanupStackTrace ??= stackTrace;
      }
    }

    if (client != null) {
      await attempt(client.close);
      await attempt(client.clearPersistedSession);
    }
    await attempt(() => clearSavedSession(keepHomeserver: false));
    final homeserverUrl = _lastHomeserverUrl;
    if (homeserverUrl != null) {
      await attempt(
        () => ManyMatrixBridge.clearStoredAccount(
          homeserverUrl,
          defaultStorePath(_accountId),
        ),
      );
    }
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError!, cleanupStackTrace!);
    }
  }

  String? _lastHomeserverUrl;

  @override
  Future<void> clearSavedSession({bool keepHomeserver = true}) async {
    await _sessionPersistence.drain();
    final prefs = await SharedPreferences.getInstance();
    final homeserverUrl = prefs.getString(_prefsHomeserverKey);
    if (matrixBridgeOwnsSessionPersistence && homeserverUrl != null) {
      final liveClient = _client;
      await clearPersistedSessionRevocationAware(
        clearLiveSession: liveClient?.clearPersistedSession,
        clearStoredSession: () => ManyMatrixBridge.clearStoredSession(
          homeserverUrl,
          defaultStorePath(_accountId),
        ),
      );
    }
    if (!keepHomeserver) {
      if (prefs.containsKey(_prefsHomeserverKey) &&
          !await prefs.remove(_prefsHomeserverKey)) {
        throw StateError('Could not remove Matrix homeserver metadata.');
      }
    }
    if (prefs.containsKey(_prefsSessionKey) &&
        !await prefs.remove(_prefsSessionKey)) {
      throw StateError('Could not remove the saved Matrix session.');
    }
  }

  static Future<void> clearAccountLocalData({
    required String accountId,
    required String homeserverUrl,
  }) async {
    await ManyMatrixBridge.clearStoredAccount(
      homeserverUrl,
      defaultStorePath(accountId),
    );
    final prefs = await SharedPreferences.getInstance();
    final homeserverKey = 'manymatrix.$accountId.homeserver';
    final sessionKey = 'manymatrix.$accountId.session';
    if (prefs.containsKey(homeserverKey) &&
        !await prefs.remove(homeserverKey)) {
      throw StateError('Could not remove Matrix homeserver metadata.');
    }
    if (prefs.containsKey(sessionKey) && !await prefs.remove(sessionKey)) {
      throw StateError('Could not remove the saved Matrix session.');
    }
  }

  ManyMatrixBridge get _requireClient {
    final client = _client;
    if (client == null) {
      throw StateError('Not logged in');
    }
    return client;
  }

  @override
  Future<List<RoomSummary>> joinedRooms() => _requireClient.joinedRooms();

  @override
  Future<List<RoomInvite>> invitedRooms() => _requireClient.invitedRooms();

  @override
  Future<String> createRoom({String? name, String? topic}) =>
      _requireClient.createRoom(name: name, topic: topic);

  @override
  Future<String> joinRoom(String roomIdOrAlias) =>
      _requireClient.joinRoom(roomIdOrAlias);

  @override
  Future<void> leaveRoom(String roomId) => _requireClient.leaveRoom(roomId);

  @override
  Future<void> invite(String roomId, String userId) =>
      _requireClient.invite(roomId, userId);

  @override
  Future<PaginatedMessages> getMessages(
    String roomId, {
    String? fromToken,
    int limit = 50,
  }) => _requireClient.getMessages(roomId, fromToken: fromToken, limit: limit);

  @override
  Future<String> sendText(String roomId, String body) =>
      _requireClient.sendText(roomId, body);

  @override
  Future<String> sendHtml(String roomId, String body, String html) =>
      _requireClient.sendHtml(roomId, body, html);

  @override
  Future<String> sendNotice(String roomId, String body) =>
      _requireClient.sendNotice(roomId, body);

  @override
  Future<String> sendEmote(String roomId, String body) =>
      _requireClient.sendEmote(roomId, body);

  @override
  Future<String> uploadMedia(
    String roomId,
    String filename,
    String mimeType,
    Uint8List data,
  ) => _requireClient.uploadMedia(roomId, filename, mimeType, data);

  @override
  Future<Uint8List?> downloadMedia(String mxcUri) =>
      _requireClient.downloadMedia(mxcUri);

  @override
  Future<Uint8List?> downloadMediaSource(Map<String, dynamic> mediaSource) =>
      _requireClient.downloadMediaSource(mediaSource);

  @override
  Future<void> editMessage(String roomId, String eventId, String newBody) =>
      _requireClient.editMessage(roomId, eventId, newBody);

  @override
  Future<String> replyTo(String roomId, String eventId, String body) =>
      _requireClient.replyTo(roomId, eventId, body);

  @override
  Future<String> sendThreadReply(
    String roomId,
    String threadRootId,
    String body, {
    String? inReplyToEventId,
  }) => _requireClient.sendThreadReply(
    roomId,
    threadRootId,
    body,
    inReplyToEventId: inReplyToEventId,
  );

  @override
  Future<List<ThreadSummary>> threadIndex({int limitPerRoom = 50}) =>
      _requireClient.threadIndex(limitPerRoom: limitPerRoom);

  @override
  Future<PaginatedThreadMessages> getThreadMessages(
    String roomId,
    String threadRootEventId, {
    String? fromToken,
    int limit = 50,
  }) => _requireClient.getThreadMessages(
    roomId,
    threadRootEventId,
    fromToken: fromToken,
    limit: limit,
  );

  @override
  Future<void> sendThreadReadReceipt(
    String roomId,
    String threadRootEventId,
    String eventId,
  ) => _requireClient.sendThreadReadReceipt(roomId, threadRootEventId, eventId);

  @override
  Future<void> sendTyping(String roomId, bool typing) =>
      _requireClient.sendTyping(roomId, typing);

  @override
  Future<void> sendReadReceipt(String roomId, String eventId) =>
      _requireClient.sendReadReceipt(roomId, eventId);

  @override
  Future<List<String>> roomMembers(String roomId) async {
    final json = await _requireClient.roomMembers(roomId);
    if (json == null || json.isEmpty) return const <String>[];
    final decoded = jsonDecode(json) as List<dynamic>;
    return decoded.cast<String>();
  }

  @override
  Future<RoomDetails> roomDetails(String roomId) =>
      _requireClient.roomDetails(roomId);

  @override
  Future<bool> isRoomEncrypted(String roomId) =>
      _requireClient.isRoomEncrypted(roomId);

  @override
  Future<void> enableEncryption(String roomId) =>
      _requireClient.enableEncryption(roomId);

  @override
  Future<void> kick(String roomId, String userId, {String? reason}) =>
      _requireClient.kick(roomId, userId, reason: reason);

  @override
  Future<void> ban(String roomId, String userId, {String? reason}) =>
      _requireClient.ban(roomId, userId, reason: reason);

  @override
  Future<void> redact(String roomId, String eventId, {String? reason}) =>
      _requireClient.redact(roomId, eventId, reason: reason);

  @override
  Future<void> suspend() => _drainCurrentClient();

  @override
  void dispose() {
    _sessionWrites.close();
    unawaited(() async {
      try {
        await suspend();
      } on Object {
        // Provider disposal has no caller to observe teardown errors.
      }
      await _rawMessages.close();
      await _rawReactions.close();
      await _rawReceipts.close();
      await _sessionProblems.close();
    }());
  }
}

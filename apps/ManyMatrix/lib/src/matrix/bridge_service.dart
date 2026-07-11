import 'dart:async';
import 'dart:convert';

import 'package:manymatrix/manymatrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/runtime.dart';
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
  Stream<ReceiptEvent> get receiptEvents;

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

  Future<void> editMessage(String roomId, String eventId, String newBody);

  Future<String> replyTo(String roomId, String eventId, String body);

  Future<String> sendThreadReply(
    String roomId,
    String threadRootId,
    String body,
  );

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

bool isInvalidMatrixSessionError(Object error) {
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
class BridgeMatrixService implements MatrixService {
  BridgeMatrixService({required String accountId}) : _accountId = accountId;

  final String _accountId;

  static bool _bridgeInitialized = false;

  String get _prefsHomeserverKey => 'manymatrix.$_accountId.homeserver';
  String get _prefsSessionKey => 'manymatrix.$_accountId.session';

  ManyMatrixBridge? _client;
  String? _userId;

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

  Future<void> _ensureInitialized() async {
    if (_bridgeInitialized) return;
    await ManyMatrixBridge.initialize(defaultLibraryPath());
    _bridgeInitialized = true;
  }

  Future<ManyMatrixBridge> _createClient(String homeserverUrl) async {
    await _ensureInitialized();
    return ManyMatrixBridge.create(homeserverUrl, defaultStorePath(_accountId));
  }

  /// Wires callbacks and kicks off the background Rust sync thread.
  Future<void> _startSession(ManyMatrixBridge client) async {
    client.onMessage(_rawMessages.add);
    client.onReaction(_rawReactions.add);
    client.onReceipt(_rawReceipts.add);
    client.onSessionUpdate((sessionJson) {
      unawaited(_persistSessionJson(sessionJson));
    });
    client.onSyncStatus((json) {
      unawaited(_handleSyncStatus(json));
    });
    _userId = await client.whoami();
    await _persistCurrentSession(client);
    await client.syncForever();
  }

  Future<void> _persistSessionJson(String sessionJson) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsSessionKey, sessionJson);
  }

  Future<void> _persistCurrentSession(ManyMatrixBridge client) async {
    final sessionJson = await client.currentSession();
    if (sessionJson != null) {
      await _persistSessionJson(sessionJson);
    }
  }

  Future<void> _handleSyncStatus(String json) async {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return;
    if (decoded['ok'] == true) {
      final client = _client;
      if (client != null) await _persistCurrentSession(client);
      return;
    }

    final error = _syncStatusError(decoded);
    final requiresReauth = isInvalidMatrixSessionError(error);
    if (requiresReauth) {
      await clearSavedSession(keepHomeserver: true);
    }
    _sessionProblems.add(
      SessionProblem(
        message: friendlySessionProblem(error),
        requiresReauth: requiresReauth,
        error: error,
      ),
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
    final prefs = await SharedPreferences.getInstance();
    final homeserverUrl = prefs.getString(_prefsHomeserverKey);
    final sessionJson = prefs.getString(_prefsSessionKey);
    if (homeserverUrl == null || sessionJson == null) return null;

    final client = await _createClient(homeserverUrl);
    try {
      await client.restore(sessionJson);
      await _startSession(client);
    } on Object catch (error) {
      client.dispose();
      if (isInvalidMatrixSessionError(error)) {
        await clearSavedSession(keepHomeserver: true);
      }
      rethrow;
    }
    _client = client;
    return _userId;
  }

  @override
  Future<String> login({
    required String homeserverUrl,
    required String username,
    required String password,
  }) async {
    final client = await _createClient(homeserverUrl);
    try {
      final sessionJson = await client.login(username, password);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsHomeserverKey, homeserverUrl);
      // TODO(manymatrix): persist to secure storage instead of plain prefs.
      await prefs.setString(_prefsSessionKey, sessionJson);
      await _startSession(client);
    } on Object {
      client.dispose();
      await clearSavedSession(keepHomeserver: false);
      rethrow;
    }
    _client = client;
    return _userId ?? username;
  }

  @override
  Future<void> logout() async {
    final client = _client;
    _client = null;
    _userId = null;
    await clearSavedSession(keepHomeserver: false);
    if (client == null) return;
    try {
      await client.logout();
    } on Object {
      // Best effort -- local state is gone either way.
    } finally {
      client.dispose();
    }
  }

  @override
  Future<void> clearSavedSession({bool keepHomeserver = true}) async {
    final prefs = await SharedPreferences.getInstance();
    if (!keepHomeserver) {
      await prefs.remove(_prefsHomeserverKey);
    }
    await prefs.remove(_prefsSessionKey);
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
  Future<void> editMessage(String roomId, String eventId, String newBody) =>
      _requireClient.editMessage(roomId, eventId, newBody);

  @override
  Future<String> replyTo(String roomId, String eventId, String body) =>
      _requireClient.replyTo(roomId, eventId, body);

  @override
  Future<String> sendThreadReply(
    String roomId,
    String threadRootId,
    String body,
  ) => _requireClient.sendThreadReply(roomId, threadRootId, body);

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
  void dispose() {
    _client?.dispose();
    _client = null;
    _rawMessages.close();
    _rawReactions.close();
    _rawReceipts.close();
    _sessionProblems.close();
  }
}

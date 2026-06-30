import 'dart:async';

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

  Future<List<RoomSummary>> joinedRooms();

  Future<PaginatedMessages> getMessages(
    String roomId, {
    String? fromToken,
    int limit = 50,
  });

  Future<String> sendText(String roomId, String body);

  Future<void> sendTyping(String roomId, bool typing);

  Future<void> sendReadReceipt(String roomId, String eventId);

  /// Releases native resources. The service must not be used afterwards.
  void dispose();
}

/// Production [MatrixService] backed by [ManyMatrixBridge].
///
/// Owns the bridge lifecycle: `initialize` once per process, `create` per
/// session, callback registration, `syncForever` after auth, and `dispose`.
class BridgeMatrixService implements MatrixService {
  BridgeMatrixService();

  static const _prefsHomeserverKey = 'manymatrix.homeserver';
  static const _prefsSessionKey = 'manymatrix.session';

  static bool _bridgeInitialized = false;

  ManyMatrixBridge? _client;
  String? _userId;

  final _rawMessages = StreamController<String>.broadcast();
  late final Stream<MessageEvent> _messageEvents =
      messageEventStream(_rawMessages.stream).asBroadcastStream();

  @override
  Stream<MessageEvent> get messageEvents => _messageEvents;

  @override
  String? get currentUserId => _userId;

  Future<void> _ensureInitialized() async {
    if (_bridgeInitialized) return;
    await ManyMatrixBridge.initialize(defaultLibraryPath());
    _bridgeInitialized = true;
  }

  Future<ManyMatrixBridge> _createClient(String homeserverUrl) async {
    await _ensureInitialized();
    return ManyMatrixBridge.create(homeserverUrl, defaultStorePath());
  }

  /// Wires callbacks and kicks off the background Rust sync thread.
  Future<void> _startSession(ManyMatrixBridge client) async {
    client.onMessage(_rawMessages.add);
    _userId = await client.whoami();
    await client.syncForever();
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
    } on Object {
      client.dispose();
      // The stored session no longer works; drop it so the next launch goes
      // straight to login.
      await _clearPersistedSession();
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
      await _startSession(client);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsHomeserverKey, homeserverUrl);
      // TODO(manymatrix): persist to secure storage instead of plain prefs.
      await prefs.setString(_prefsSessionKey, sessionJson);
    } on Object {
      client.dispose();
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
    await _clearPersistedSession();
    if (client == null) return;
    try {
      await client.logout();
    } on Object {
      // Best effort -- local state is gone either way.
    } finally {
      client.dispose();
    }
  }

  Future<void> _clearPersistedSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsHomeserverKey);
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
  Future<PaginatedMessages> getMessages(
    String roomId, {
    String? fromToken,
    int limit = 50,
  }) =>
      _requireClient.getMessages(roomId, fromToken: fromToken, limit: limit);

  @override
  Future<String> sendText(String roomId, String body) =>
      _requireClient.sendText(roomId, body);

  @override
  Future<void> sendTyping(String roomId, bool typing) =>
      _requireClient.sendTyping(roomId, typing);

  @override
  Future<void> sendReadReceipt(String roomId, String eventId) =>
      _requireClient.sendReadReceipt(roomId, eventId);

  @override
  void dispose() {
    _client?.dispose();
    _client = null;
    _rawMessages.close();
  }
}

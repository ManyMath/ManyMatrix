// ignore_for_file: avoid_web_libraries_in_flutter
// BridgeStatus stream: subscribe to bridgeStatus.stream for lifecycle events (R013).
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:js_interop';
import 'dart:typed_data';

import 'bridge_status.dart';
import 'models/models.dart';
import 'web_bridge_errors.dart';

@JS('chrome')
external _Chrome get _chrome;

extension type _Chrome(JSObject _) implements JSObject {
  external _ChromeRuntime get runtime;
  external _ChromeStorage get storage;
}

extension type _ChromeRuntime(JSObject _) implements JSObject {
  external JSPromise<JSAny?> sendMessage(JSAny? message);
  external JSString? get id;
  external _ChromeEvent get onMessage;
}

extension type _ChromeEvent(JSObject _) implements JSObject {
  external void addListener(JSFunction callback);
  external void removeListener(JSFunction callback);
}

extension type _ChromeStorage(JSObject _) implements JSObject {
  external _ChromeStorageLocal get local;
}

extension type _ChromeStorageLocal(JSObject _) implements JSObject {
  external JSPromise<JSAny?> get(JSAny? keys);
  external JSPromise<JSAny?> set(JSObject items);
  external JSPromise<JSAny?> remove(JSAny? keys);
}

bool _isContextInvalidated(String msg) =>
    msg.toLowerCase().contains('context invalidated');

String? _chromeRuntimeId() {
  try {
    return _chrome.runtime.id?.toDart;
  } catch (_) {
    return null;
  }
}

Future<bool> _waitForContextRestore() async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    await Future.delayed(const Duration(milliseconds: 200));
    try {
      final id = _chromeRuntimeId();
      if (id != null && id.isNotEmpty) return true;
    } catch (_) {}
  }
  return false;
}

class ManyMatrixBridge {
  final String _homeserverUrl;
  // ignore: unused_field
  final String _storePath;

  ManyMatrixBridge._(this._homeserverUrl, this._storePath);

  String get _storeName =>
      'manymatrix_${_homeserverUrl.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';

  static Future<void> initialize(String libraryPath) async {}

  static Future<ManyMatrixBridge> create(
    String homeserverUrl,
    String storePath,
  ) async {
    return ManyMatrixBridge._(homeserverUrl, storePath);
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      return await _callOnce(method, args);
    } catch (e) {
      final msg = e.toString();
      if (!_isContextInvalidated(msg)) rethrow;
      bridgeStatus.emit(BridgeStatus.reconnecting);
      developer.log(
        'extension context invalidated, waiting for reload',
        name: 'manymatrix.bridge',
      );
      final recovered = await _waitForContextRestore();
      if (!recovered) {
        bridgeStatus.emit(BridgeStatus.failed);
        throw ManyMatrixStorageException(
          'extension reload did not recover in 5s',
          details: {'method': method},
        );
      }
      final result = await _callOnce(method, args);
      bridgeStatus.emit(BridgeStatus.connected);
      developer.log('bridge recovered', name: 'manymatrix.bridge');
      return result;
    }
  }

  Future<Map<String, dynamic>> _callOnce(
    String method,
    Map<String, dynamic> args,
  ) async {
    final envelope = {'target': 'offscreen', 'method': method, 'args': args};
    final JSAny? replyJs;
    try {
      replyJs = await _chrome.runtime
          .sendMessage(envelope.jsify())
          .toDart
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw ManyMatrixStorageException(
        'no reply from offscreen',
        details: {},
      );
    }
    if (replyJs == null) {
      throw ManyMatrixStorageException(
        'no reply from offscreen',
        details: {},
      );
    }
    final reply = replyJs.dartify() as Map<String, dynamic>;
    if (reply.containsKey('ok')) {
      return reply['ok'] as Map<String, dynamic>;
    }
    if (reply.containsKey('err')) {
      final err = reply['err'] as Map<String, dynamic>;
      throw _exceptionFor(
        err['kind'] as String,
        err['message'] as String? ?? '',
        err['details'] as Map<String, dynamic>? ?? {},
      );
    }
    throw ManyMatrixSerdeException(
      'malformed reply: missing ok/err',
      details: {'raw': reply},
    );
  }

  static ManyMatrixException _exceptionFor(
    String kind,
    String message,
    Map<String, dynamic> details,
  ) {
    switch (kind) {
      case 'MatrixSdkError':
        return ManyMatrixSdkException(message, details: details);
      case 'SerdeError':
        return ManyMatrixSerdeException(message, details: details);
      case 'StorageError':
        return ManyMatrixStorageException(message, details: details);
      case 'PanicError':
        return ManyMatrixPanicException(message, details: details);
      default:
        return ManyMatrixException(kind, message, details);
    }
  }

  static final _sensitiveKeys =
      RegExp(r'password|token|recovery_key', caseSensitive: false);

  static Map<String, dynamic> _redactArgs(Map<String, dynamic> args) {
    return args.map(
      (key, value) => MapEntry(
        key,
        _sensitiveKeys.hasMatch(key) ? '<redacted>' : value,
      ),
    );
  }

  Future<Map<String, dynamic>> echo(String message) =>
      _call('dispatcher.echo', {'message': message});

  Future<void> _persistSession(String sessionJson) async {
    final obj = {'manymatrix_session': sessionJson}.jsify() as JSObject;
    await _chrome.storage.local.set(obj).toDart;
  }

  static Future<String?> loadPersistedSession() async {
    final result =
        await _chrome.storage.local.get('manymatrix_session'.toJS).toDart;
    if (result == null) return null;
    final map = (result as JSObject).dartify() as Map<String, dynamic>;
    return map['manymatrix_session'] as String?;
  }

  Future<void> _clearSession() async {
    await _chrome.storage.local.remove('manymatrix_session'.toJS).toDart;
  }

  Future<String> login(String username, String password) async {
    developer.log(
      'auth.login ${_redactArgs({'username': username, 'password': password})}',
      name: 'manymatrix.bridge',
    );
    final result = await _call('auth.login', {
      'homeserver_url': _homeserverUrl,
      'username': username,
      'password': password,
      'store_name': _storeName,
    });
    final sessionJson = result['session_json'] as String;
    await _persistSession(sessionJson);
    _resubscribeEvents();
    return sessionJson;
  }

  Future<void> restore(String sessionJson) async {
    developer.log('auth.restore', name: 'manymatrix.bridge');
    await _call('auth.restore', {
      'homeserver_url': _homeserverUrl,
      'session_json': sessionJson,
      'store_name': _storeName,
    });
    _resubscribeEvents();
  }

  Future<void> syncOnce() async {
    await _call('sync.once', {});
  }

  Future<void> syncForever() async {
    await _call('sync.start', {});
  }

  Future<List<RoomSummary>> joinedRooms() async {
    final result = await _call('rooms.list', {});
    final list = jsonDecode(result['rooms_json'] as String) as List<dynamic>;
    return list
        .map((e) => RoomSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<String> serverCapabilities() async {
    final result = await _call('server.capabilities', {});
    return result['capabilities_json'] as String;
  }

  Future<void> logout() async {
    developer.log('auth.logout', name: 'manymatrix.bridge');
    await _call('auth.logout', {});
    await _clearSession();
  }

  Future<String?> syncToken() async {
    final result = await _call('sync.status', {});
    return result['sync_token'] as String?;
  }

  Future<String> createRoom({String? name, String? topic}) async {
    final result = await _call('rooms.create', {'name': name, 'topic': topic});
    return result['room_id'] as String;
  }

  Future<String> joinRoom(String roomIdOrAlias) async {
    final result =
        await _call('rooms.join', {'room_id_or_alias': roomIdOrAlias});
    return result['room_id'] as String;
  }

  Future<void> invite(String roomId, String userId) async {
    await _call('rooms.invite', {'room_id': roomId, 'user_id': userId});
  }

  Future<void> leaveRoom(String roomId) async {
    await _call('rooms.leave', {'room_id': roomId});
  }

  Future<void> kick(String roomId, String userId, {String? reason}) async {
    await _call('rooms.kick', {
      'room_id': roomId,
      'user_id': userId,
      'reason': reason,
    });
  }

  Future<void> ban(String roomId, String userId, {String? reason}) async {
    await _call('rooms.ban', {
      'room_id': roomId,
      'user_id': userId,
      'reason': reason,
    });
  }

  Future<String?> roomName(String roomId) async {
    final result = await _call('rooms.name', {'room_id': roomId});
    return result['name'] as String?;
  }

  Future<String?> roomTopic(String roomId) async {
    final result = await _call('rooms.topic', {'room_id': roomId});
    return result['topic'] as String?;
  }

  Future<String?> roomAvatarUrl(String roomId) async {
    final result = await _call('rooms.avatar_url', {'room_id': roomId});
    return result['avatar_url'] as String?;
  }

  Future<String?> roomMembers(String roomId) async {
    final result = await _call('rooms.members', {'room_id': roomId});
    return result['members_json'] as String?;
  }

  Future<String> sendText(String roomId, String body) async {
    final result =
        await _call('messages.send_text', {'room_id': roomId, 'body': body});
    return result['event_id'] as String;
  }

  Future<String> sendHtml(String roomId, String body, String html) async {
    final result = await _call('messages.send_html', {
      'room_id': roomId,
      'body': body,
      'html': html,
    });
    return result['event_id'] as String;
  }

  Future<String> sendNotice(String roomId, String body) async {
    final result = await _call(
      'messages.send_notice',
      {'room_id': roomId, 'body': body},
    );
    return result['event_id'] as String;
  }

  Future<String> sendEmote(String roomId, String body) async {
    final result = await _call(
      'messages.send_emote',
      {'room_id': roomId, 'body': body},
    );
    return result['event_id'] as String;
  }

  Future<void> editMessage(
      String roomId, String eventId, String newBody) async {
    await _call('messages.edit', {
      'room_id': roomId,
      'event_id': eventId,
      'new_body': newBody,
    });
  }

  Future<String> replyTo(String roomId, String eventId, String body) async {
    final result = await _call('messages.reply', {
      'room_id': roomId,
      'event_id': eventId,
      'body': body,
    });
    return result['event_id'] as String;
  }

  Future<String> sendReaction(String roomId, String eventId, String key) async {
    final result = await _call('messages.react', {
      'room_id': roomId,
      'event_id': eventId,
      'key': key,
    });
    return result['event_id'] as String;
  }

  Future<void> redact(String roomId, String eventId, {String? reason}) async {
    await _call('messages.redact', {
      'room_id': roomId,
      'event_id': eventId,
      'reason': reason,
    });
  }

  Future<String> sendThreadReply(
    String roomId,
    String threadRootId,
    String body,
  ) async {
    final result = await _call('messages.thread_reply', {
      'room_id': roomId,
      'thread_root_event_id': threadRootId,
      'body': body,
    });
    return result['event_id'] as String;
  }

  Future<void> sendReadReceipt(String roomId, String eventId) async {
    await _call('rooms.read_receipt', {
      'room_id': roomId,
      'event_id': eventId,
    });
  }

  Future<void> sendTyping(String roomId, bool typing) async {
    await _call('rooms.typing', {'room_id': roomId, 'typing': typing});
  }

  Future<PaginatedMessages> getMessages(
    String roomId, {
    String? fromToken,
    int limit = 20,
  }) async {
    final result = await _call('messages.get', {
      'room_id': roomId,
      'from_token': fromToken,
      'limit': limit,
    });
    return PaginatedMessages.fromJson(
      jsonDecode(result['paginated_json'] as String) as Map<String, dynamic>,
    );
  }

  Future<void> enableEncryption(String roomId) async {
    await _call('e2ee.enable', {'room_id': roomId});
  }

  Future<String> startVerification(String userId, String deviceId) async {
    final result = await _call('e2ee.start_verification', {
      'user_id': userId,
      'device_id': deviceId,
    });
    return result['flow_id'] as String;
  }

  Future<void> acceptVerification(String userId, String flowId) async {
    await _call('e2ee.accept_verification', {
      'user_id': userId,
      'flow_id': flowId,
    });
  }

  Future<String> getSasEmojis(String userId, String flowId) async {
    final result = await _call('e2ee.sas_emojis', {
      'user_id': userId,
      'flow_id': flowId,
    });
    return result['emojis_json'] as String;
  }

  Future<void> confirmSas(String userId, String flowId) async {
    await _call('e2ee.confirm_sas', {'user_id': userId, 'flow_id': flowId});
  }

  Future<void> cancelVerification(String userId, String flowId) async {
    await _call('e2ee.cancel_verification', {
      'user_id': userId,
      'flow_id': flowId,
    });
  }

  Future<void> bootstrapCrossSigning() async {
    await _call('e2ee.bootstrap_cross_signing', {});
  }

  Future<void> setupKeyBackup() async {
    await _call('e2ee.setup_key_backup', {});
  }

  Future<void> restoreKeyBackup(String recoveryKey) async {
    await _call('e2ee.restore_key_backup', {'recovery_key': recoveryKey});
  }

  Future<String> uploadMedia(
    String roomId,
    String filename,
    String mimeType,
    Uint8List data,
  ) async {
    final result = await _call('media.upload', {
      'room_id': roomId,
      'filename': filename,
      'mime_type': mimeType,
      'data_base64': base64Encode(data),
    });
    return result['event_id'] as String;
  }

  Future<Uint8List?> downloadMedia(String mxcUri) async {
    final result = await _call('media.download', {'mxc_uri': mxcUri});
    final encoded = result['data_base64'] as String?;
    return encoded == null ? null : base64Decode(encoded);
  }

  Future<Uint8List?> getThumbnail(
    String mxcUri, {
    int width = 128,
    int height = 128,
  }) async {
    final result = await _call('media.thumbnail', {
      'mxc_uri': mxcUri,
      'width': width,
      'height': height,
    });
    final encoded = result['data_base64'] as String?;
    return encoded == null ? null : base64Decode(encoded);
  }
  Future<void> registerPusher({
    required String appId,
    required String pushKey,
    required String appDisplayName,
    required String deviceDisplayName,
    required String pushUrl,
    required String lang,
  }) async {
    await _call('pushers.register', {
      'app_id': appId,
      'push_key': pushKey,
      'app_display_name': appDisplayName,
      'device_display_name': deviceDisplayName,
      'push_url': pushUrl,
      'lang': lang,
    });
  }

  // === Event push channel ===
  //
  // The wasm dispatcher forwards sync events through offscreen.js, which
  // broadcasts them as {type: 'manymatrix-event', kind, payload} runtime
  // messages. A single chrome.runtime.onMessage listener dispatches to the
  // registered callbacks by kind.

  void Function(String json)? _onMessageCallback;
  void Function(String json)? _onReactionCallback;
  void Function(String json)? _onReceiptCallback;
  JSFunction? _eventListener;
  bool _eventsSubscribed = false;

  bool get _hasEventCallbacks =>
      _onMessageCallback != null ||
      _onReactionCallback != null ||
      _onReceiptCallback != null;

  void _handleRuntimeMessage(JSAny? message, JSAny? sender, JSAny? reply) {
    final data = message.dartify();
    if (data is! Map || data['type'] != 'manymatrix-event') return;
    final kind = data['kind'] as String?;
    final payload = data['payload'] as String?;
    if (kind == null || payload == null) return;
    switch (kind) {
      case 'message':
        _onMessageCallback?.call(payload);
      case 'reaction':
        _onReactionCallback?.call(payload);
      case 'receipt':
        _onReceiptCallback?.call(payload);
    }
  }

  void _ensureEventChannel() {
    if (_eventListener == null) {
      final listener = _handleRuntimeMessage.toJS;
      _chrome.runtime.onMessage.addListener(listener);
      _eventListener = listener;
    }
    if (_eventsSubscribed) return;
    _eventsSubscribed = true;
    unawaited(
      _call('events.subscribe', {}).catchError((Object e) {
        _eventsSubscribed = false;
        developer.log(
          'events.subscribe failed: $e',
          name: 'manymatrix.bridge',
        );
        return <String, dynamic>{};
      }),
    );
  }

  // Handlers attach to the wasm-side client instance, which login/restore
  // replace, so an active subscription must be re-established.
  void _resubscribeEvents() {
    _eventsSubscribed = false;
    if (_hasEventCallbacks) _ensureEventChannel();
  }

  /// Register a callback for incoming message events.
  ///
  /// The callback receives a JSON-serialized MessageEvent string.
  void onMessage(void Function(String json) callback) {
    _onMessageCallback = callback;
    _ensureEventChannel();
  }

  /// Register a callback for incoming reaction events.
  ///
  /// The callback receives a JSON-serialized ReactionEvent string.
  void onReaction(void Function(String json) callback) {
    _onReactionCallback = callback;
    _ensureEventChannel();
  }

  /// Register a callback for incoming read receipt events.
  ///
  /// The callback receives a JSON-serialized ReceiptEvent string.
  void onReceipt(void Function(String json) callback) {
    _onReceiptCallback = callback;
    _ensureEventChannel();
  }

  void dispose() {
    final listener = _eventListener;
    if (listener != null) {
      _chrome.runtime.onMessage.removeListener(listener);
      _eventListener = null;
    }
    _onMessageCallback = null;
    _onReactionCallback = null;
    _onReceiptCallback = null;
    _eventsSubscribed = false;
  }
}

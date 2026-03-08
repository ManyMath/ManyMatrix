// ignore_for_file: avoid_web_libraries_in_flutter
// BridgeStatus stream: subscribe to bridgeStatus.stream for lifecycle events (R013).
import 'dart:async';
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

const _webUnsupportedMessage =
    'ManyMatrix web/extension runtime is unavailable in this checkout.';

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
      replyJs = await _chrome.runtime.sendMessage(envelope.jsify()).toDart
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

  Future<T> _unsupported<T>() {
    return Future<T>.error(UnsupportedError(_webUnsupportedMessage));
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
    return sessionJson;
  }

  Future<void> restore(String sessionJson) async {
    developer.log('auth.restore', name: 'manymatrix.bridge');
    await _call('auth.restore', {
      'homeserver_url': _homeserverUrl,
      'session_json': sessionJson,
      'store_name': _storeName,
    });
  }

  Future<void> syncOnce() async {
    await _call('sync.once', {});
  }

  Future<void> syncForever() async {
    await _call('sync.start', {});
  }
  Future<List<RoomSummary>> joinedRooms() => _unsupported();
  Future<String> serverCapabilities() => _unsupported();
  Future<void> logout() async {
    developer.log('auth.logout', name: 'manymatrix.bridge');
    await _call('auth.logout', {});
    await _clearSession();
  }

  Future<String?> syncToken() async {
    final result = await _call('sync.status', {});
    return result['sync_token'] as String?;
  }
  Future<String> createRoom({String? name, String? topic}) => _unsupported();
  Future<String> joinRoom(String roomIdOrAlias) => _unsupported();
  Future<void> invite(String roomId, String userId) => _unsupported();
  Future<void> leaveRoom(String roomId) => _unsupported();
  Future<void> kick(String roomId, String userId, {String? reason}) =>
      _unsupported();
  Future<void> ban(String roomId, String userId, {String? reason}) =>
      _unsupported();
  Future<String?> roomName(String roomId) => _unsupported();
  Future<String?> roomTopic(String roomId) => _unsupported();
  Future<String?> roomAvatarUrl(String roomId) => _unsupported();
  Future<String?> roomMembers(String roomId) => _unsupported();
  Future<String> sendText(String roomId, String body) => _unsupported();
  Future<String> sendHtml(String roomId, String body, String html) =>
      _unsupported();
  Future<String> sendNotice(String roomId, String body) => _unsupported();
  Future<String> sendEmote(String roomId, String body) => _unsupported();
  Future<void> editMessage(String roomId, String eventId, String newBody) =>
      _unsupported();
  Future<String> replyTo(String roomId, String eventId, String body) =>
      _unsupported();
  Future<String> sendReaction(String roomId, String eventId, String key) =>
      _unsupported();
  Future<void> redact(String roomId, String eventId, {String? reason}) =>
      _unsupported();
  Future<String> sendThreadReply(
    String roomId,
    String threadRootId,
    String body,
  ) =>
      _unsupported();
  Future<void> sendReadReceipt(String roomId, String eventId) => _unsupported();
  Future<void> sendTyping(String roomId, bool typing) => _unsupported();
  Future<PaginatedMessages> getMessages(
    String roomId, {
    String? fromToken,
    int limit = 20,
  }) =>
      _unsupported();
  Future<void> enableEncryption(String roomId) => _unsupported();
  Future<String> startVerification(String userId, String deviceId) =>
      _unsupported();
  Future<void> acceptVerification(String userId, String flowId) =>
      _unsupported();
  Future<String> getSasEmojis(String userId, String flowId) => _unsupported();
  Future<void> confirmSas(String userId, String flowId) => _unsupported();
  Future<void> cancelVerification(String userId, String flowId) =>
      _unsupported();
  Future<void> bootstrapCrossSigning() => _unsupported();
  Future<void> setupKeyBackup() => _unsupported();
  Future<void> restoreKeyBackup(String recoveryKey) => _unsupported();
  Future<String> uploadMedia(
    String roomId,
    String filename,
    String mimeType,
    Uint8List data,
  ) =>
      _unsupported();
  Future<Uint8List?> downloadMedia(String mxcUri) => _unsupported();
  Future<Uint8List?> getThumbnail(
    String mxcUri, {
    int width = 128,
    int height = 128,
  }) =>
      _unsupported();
  Future<void> registerPusher({
    required String appId,
    required String pushKey,
    required String appDisplayName,
    required String deviceDisplayName,
    required String pushUrl,
    required String lang,
  }) =>
      _unsupported();

  void onMessage(void Function(String json) callback) {}
  void onReaction(void Function(String json) callback) {}
  void onReceipt(void Function(String json) callback) {}
  void dispose() {}
}

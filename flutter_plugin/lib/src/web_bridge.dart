// ignore_for_file: avoid_web_libraries_in_flutter
// BridgeStatus stream: subscribe to bridgeStatus.stream for lifecycle events (R013).
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'bridge_status.dart';
import 'custom_event_listeners.dart';
import 'models/models.dart';
import 'store_cleanup.dart';
import 'web_bridge_errors.dart';
import 'web_rpc_timeout.dart';

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

Map<String, dynamic> _stringMap(Object? value) {
  if (value is! Map) {
    throw ManyMatrixSerdeException(
      'malformed bridge message: expected an object',
      details: {'valueType': value.runtimeType.toString()},
    );
  }
  return value.map((key, item) => MapEntry('$key', item));
}

ManyMatrixException _transportException(Object? value) {
  final error = _stringMap(value);
  return manyMatrixExceptionForEnvelope(
    error['kind'] as String? ?? 'StorageError',
    error['message'] as String? ?? 'ManyMatrix browser runtime failed',
    details: error['details'] is Map
        ? _stringMap(error['details'])
        : const <String, dynamic>{},
  );
}

Future<void> _scrubLegacyExtensionStorage({
  String? expectedHomeserverUrl,
  String? scopedSessionKey,
  required bool ensure,
}) async {
  final message = <String, Object?>{
    'type': 'manymatrix-legacy-storage',
    'action': ensure ? 'ensure' : 'scrub',
    if (expectedHomeserverUrl != null)
      'expected_homeserver_url': expectedHomeserverUrl,
    if (scopedSessionKey != null) 'scoped_session_key': scopedSessionKey,
  };
  final JSAny? replyJs;
  try {
    replyJs = await _chrome.runtime
        .sendMessage(message.jsify())
        .toDart
        .timeout(const Duration(seconds: 30));
  } on TimeoutException {
    throw ManyMatrixStorageException(
      'The ManyMatrix extension did not finish legacy storage cleanup.',
      details: const {'reason': 'legacy_storage_cleanup_timeout'},
    );
  }
  if (replyJs == null) {
    throw ManyMatrixStorageException(
      'The ManyMatrix extension did not answer legacy storage cleanup.',
      details: const {'reason': 'legacy_storage_cleanup_no_reply'},
    );
  }
  final reply = _stringMap(replyJs.dartify());
  if (reply.containsKey('ok')) return;
  if (reply.containsKey('err')) throw _transportException(reply['err']);
  throw ManyMatrixSerdeException(
    'malformed legacy storage cleanup reply',
    details: const {'reason': 'legacy_storage_cleanup_malformed_reply'},
  );
}

typedef _TransportEventHandler = void Function(String kind, String payload);

abstract interface class _WebTransport {
  set onEvent(_TransportEventHandler? handler);

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> args,
  );

  Future<void> close();
}

class _WebStoreLease {
  _WebStoreLease._(this._release, this._holding);

  final Completer<void> _release;
  final Future<JSAny?> _holding;

  static Future<_WebStoreLease> acquire(String storeName) async {
    final release = Completer<void>();
    final granted = Completer<bool>();
    var abandoned = false;
    final callback = ((JSAny? lock) {
      // Nobody owns a grant that arrives after the timeout below, so hand
      // the lock straight back instead of pinning it for the tab's lifetime.
      if (abandoned) return null;
      if (!granted.isCompleted) granted.complete(lock != null);
      if (lock == null) return null;
      return release.future.then<JSAny?>((_) => null).toJS;
    }).toJS;
    final Future<JSAny?> holding;
    try {
      holding = web.window.navigator.locks
          .request(
            'manymatrix-store-$storeName',
            <String, Object?>{
              'mode': 'exclusive',
              'ifAvailable': true,
            }.jsify() as JSObject,
            callback,
          )
          .toDart;
    } on Object catch (error) {
      throw ManyMatrixStorageException(
        'This browser cannot enforce exclusive Matrix account storage.',
        details: {'store': storeName, 'cause': '$error'},
      );
    }
    // A request rejected before granting fails acquisition now. Listening
    // here also keeps a rejection nobody awaits from going unhandled.
    unawaited(
      holding.then<void>(
        (_) {},
        onError: (Object error, StackTrace _) {
          if (granted.isCompleted) return;
          granted.completeError(
            ManyMatrixStorageException(
              'This browser cannot enforce exclusive Matrix account storage.',
              details: {'store': storeName, 'cause': '$error'},
            ),
          );
        },
      ),
    );
    final bool acquired;
    try {
      acquired = await granted.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      abandoned = true;
      throw ManyMatrixStorageException(
        'The browser did not grant exclusive access to the local Matrix '
        'store in time. Retry in a moment.',
        details: {'reason': 'store_lock_timeout', 'store': storeName},
      );
    }
    if (!acquired) {
      await holding;
      throw ManyMatrixStorageException(
        'This Matrix account is active in another browser tab. Close that tab before reconnecting.',
        details: {'reason': 'store_active_in_another_tab', 'store': storeName},
      );
    }
    return _WebStoreLease._(release, holding);
  }

  Future<void> release() async {
    if (!_release.isCompleted) _release.complete();
    await _holding;
  }
}

class _ExtensionTransport implements _WebTransport {
  _ExtensionTransport._(this._clientId)
      : _ownerId = web.window.crypto.randomUUID();

  static Future<_ExtensionTransport> create(String clientId) async {
    final transport = _ExtensionTransport._(clientId);
    await transport._claim(recovering: false);
    transport._heartbeatTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(transport._heartbeat()),
    );
    return transport;
  }

  final String _clientId;
  final String _ownerId;
  _TransportEventHandler? _onEvent;
  JSFunction? _eventListener;
  Timer? _heartbeatTimer;
  bool _disposed = false;
  bool _workerReplacementPending = false;

  Future<void> _claim({required bool recovering}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      try {
        await _callOnce('bridge.claim', {'recovering': recovering});
        return;
      } on ManyMatrixException catch (error) {
        if (error.details['reason'] != 'owner_active' ||
            DateTime.now().isAfter(deadline)) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  Future<void> _heartbeat() async {
    if (_disposed) return;
    try {
      await _callOnce('bridge.heartbeat', const <String, dynamic>{});
    } on Object {
      // The next user operation reports ownership/context loss explicitly.
    }
  }

  @override
  set onEvent(_TransportEventHandler? handler) {
    _onEvent = handler;
    if (handler != null && _eventListener == null && !_disposed) {
      final listener = _handleRuntimeMessage.toJS;
      _chrome.runtime.onMessage.addListener(listener);
      _eventListener = listener;
    }
  }

  void _handleRuntimeMessage(JSAny? message, JSAny? sender, JSAny? reply) {
    final data = message.dartify();
    if (data is! Map || data['type'] != 'manymatrix-event') return;
    if (data['client_id'] != _clientId || data['owner_id'] != _ownerId) return;
    final kind = data['kind'];
    final payload = data['payload'];
    if (kind is String && payload is String) _onEvent?.call(kind, payload);
  }

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> args,
  ) async {
    if (_disposed) {
      throw StateError('ManyMatrix bridge is disposed');
    }
    return _callSerialized(method, args);
  }

  Future<Map<String, dynamic>> _callSerialized(
    String method,
    Map<String, dynamic> args,
  ) async {
    if (_disposed) throw StateError('ManyMatrix bridge is disposed');
    if (_workerReplacementPending) throw _recoveredWorkerError(method);
    try {
      return await _callOnce(method, args);
    } catch (error) {
      if (_isRecoveryPending(error)) {
        _workerReplacementPending = true;
        throw _recoveredWorkerError(method);
      }
      if (_isStaleOwner(error)) {
        if (_disposed) throw StateError('ManyMatrix bridge is disposed');
        _workerReplacementPending = true;
        try {
          await _claim(recovering: true);
        } on Object {
          _workerReplacementPending = false;
          rethrow;
        }
        throw _recoveredWorkerError(method);
      }
      if (!_isContextInvalidated(error.toString())) rethrow;
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
      if (_disposed) throw StateError('ManyMatrix bridge is disposed');
      _workerReplacementPending = true;
      try {
        await _claim(recovering: true);
      } on Object {
        _workerReplacementPending = false;
        rethrow;
      }
      bridgeStatus.emit(BridgeStatus.connected);
      developer.log('bridge recovered', name: 'manymatrix.bridge');
      throw _recoveredWorkerError(method);
    }
  }

  ManyMatrixStorageException _recoveredWorkerError(String method) =>
      ManyMatrixStorageException(
        'The extension Worker was replaced and must restore its session.',
        details: {'reason': 'worker_replaced', 'method': method},
      );

  bool _isStaleOwner(Object error) =>
      error is ManyMatrixException && error.details['reason'] == 'stale_owner';

  bool _isRecoveryPending(Object error) =>
      error is ManyMatrixException &&
      error.details['reason'] == 'recovery_pending';

  void _acknowledgeWorkerRecovery() {
    _workerReplacementPending = false;
  }

  Future<Map<String, dynamic>> _callOnce(
    String method,
    Map<String, dynamic> args,
  ) async {
    final envelope = {
      'target': 'offscreen',
      'client_id': _clientId,
      'owner_id': _ownerId,
      'method': method,
      'args': args,
    };
    final JSAny? replyJs;
    try {
      replyJs = await _chrome.runtime
          .sendMessage(envelope.jsify())
          .toDart
          .timeout(webRpcTimeout(method, args));
    } on TimeoutException {
      throw ManyMatrixStorageException(
        'no reply from the ManyMatrix extension runtime',
        details: {'method': method},
      );
    }
    if (replyJs == null) {
      throw ManyMatrixStorageException(
        'no reply from the ManyMatrix extension runtime',
        details: {'method': method},
      );
    }
    final reply = _stringMap(replyJs.dartify());
    if (reply.containsKey('ok')) return _stringMap(reply['ok']);
    if (reply.containsKey('err')) throw _transportException(reply['err']);
    throw ManyMatrixSerdeException(
      'malformed reply: missing ok/err',
      details: {'method': method},
    );
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final listener = _eventListener;
    if (listener != null) {
      _chrome.runtime.onMessage.removeListener(listener);
      _eventListener = null;
    }
    _onEvent = null;
    try {
      await _chrome.runtime
          .sendMessage({
            'target': 'offscreen',
            'client_id': _clientId,
            'owner_id': _ownerId,
            'method': 'bridge.dispose',
            'args': const <String, dynamic>{},
          }.jsify())
          .toDart
          .timeout(const Duration(seconds: 5));
    } on Object {
      // The extension context may already be closing. Its offscreen
      // document is destroyed by Chrome in that case.
    }
  }
}

class _WorkerTransport implements _WebTransport {
  _WorkerTransport._(this._worker) {
    _messageListener = _handleMessage.toJS;
    _messageErrorListener = _handleMessageError.toJS;
    _errorListener = _handleWorkerError.toJS;
    _worker.onmessage = _messageListener;
    _worker.onmessageerror = _messageErrorListener;
    _worker.onerror = _errorListener;
  }

  static Future<_WorkerTransport> create(String workerName) async {
    final web.Worker worker;
    try {
      worker = web.Worker(
        'manymatrix_worker.js'.toJS,
        web.WorkerOptions(type: 'module', name: workerName),
      );
    } on Object catch (error) {
      throw ManyMatrixStorageException(
        'Could not start the ManyMatrix web worker. Serve the complete '
        'release build over HTTP or HTTPS.',
        details: {'cause': '$error'},
      );
    }
    final transport = _WorkerTransport._(worker);
    try {
      await transport._ready.future.timeout(const Duration(seconds: 30));
      return transport;
    } on TimeoutException {
      await transport.close();
      throw ManyMatrixStorageException(
        'The ManyMatrix web worker did not initialize in 30 seconds. Verify '
        'that manymatrix_worker.js, pkg/manymatrix_web.js, and the WASM file '
        'are deployed together over HTTP or HTTPS.',
        details: {'worker': workerName},
      );
    } on Object {
      await transport.close();
      rethrow;
    }
  }

  final web.Worker _worker;
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _closed = Completer<void>();
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  late final JSFunction _messageListener;
  late final JSFunction _messageErrorListener;
  late final JSFunction _errorListener;
  _TransportEventHandler? _onEvent;
  int _nextRequestId = 1;
  bool _started = false;
  bool _disposed = false;
  ManyMatrixPanicException? _fatal;
  Future<void>? _closeFuture;

  @override
  set onEvent(_TransportEventHandler? handler) => _onEvent = handler;

  static ManyMatrixException _decodeFailure(Object error) =>
      error is ManyMatrixException
          ? error
          : ManyMatrixSerdeException(
              'Could not decode a ManyMatrix worker message',
              details: {'cause': '$error'},
            );

  void _handleMessage(web.MessageEvent event) {
    try {
      _handleMessageData(_stringMap(event.data.dartify()));
    } on Object catch (error) {
      // Replies with a readable id are failed individually in
      // _handleMessageData, so this message names no request. Only an
      // unreadable startup handshake is fatal to the transport.
      final failure = _decodeFailure(error);
      if (!_started && !_ready.isCompleted) {
        _ready.completeError(failure);
        bridgeStatus.emit(BridgeStatus.failed);
        return;
      }
      developer.log(
        'dropped an undecodable worker message: $failure',
        name: 'manymatrix.bridge',
      );
    }
  }

  void _handleMessageData(Map<String, dynamic> message) {
    final type = message['type'];
    if (type == 'manymatrix-ready') {
      _started = true;
      if (!_ready.isCompleted) _ready.complete();
      bridgeStatus.emit(BridgeStatus.connected);
      return;
    }
    if (type == 'manymatrix-fatal') {
      _markFatal(_fatalException(message['error']));
      return;
    }
    if (type == 'manymatrix-init-error') {
      final error = _transportException(message['error']);
      if (!_ready.isCompleted) _ready.completeError(error);
      _failPending(error);
      bridgeStatus.emit(BridgeStatus.failed);
      return;
    }
    if (type == 'manymatrix-event') {
      final kind = message['kind'];
      final payload = message['payload'];
      if (kind is String && payload is String) {
        try {
          _onEvent?.call(kind, payload);
        } catch (error, stackTrace) {
          // A throwing app callback is not a transport failure.
          Zone.current.handleUncaughtError(error, stackTrace);
        }
      }
      return;
    }
    if (type == 'manymatrix-closed') {
      if (!_closed.isCompleted) _closed.complete();
      return;
    }

    final requestId = message['id'];
    if (requestId is! num) return;
    final completer = _pending.remove(requestId.toInt());
    if (completer == null) return;
    try {
      if (type == 'manymatrix-result') {
        completer.complete(_stringMap(message['ok']));
      } else if (type == 'manymatrix-error') {
        completer.completeError(_transportException(message['error']));
      } else {
        completer.completeError(
          ManyMatrixSerdeException(
            'unknown worker reply type',
            details: {'type': '$type'},
          ),
        );
      }
    } on Object catch (error) {
      // Only this reply is unreadable; other requests are unaffected.
      completer.completeError(_decodeFailure(error));
    }
  }

  // One message could not be deserialized. Its request id is unknown, so that
  // request runs into its deadline; before the handshake it fails startup.
  void _handleMessageError(web.Event event) {
    final error = ManyMatrixSerdeException(
      'Could not deserialize a ManyMatrix worker message',
      details: const {'reason': 'worker_message_error'},
    );
    if (!_started) {
      if (!_ready.isCompleted) _ready.completeError(error);
      bridgeStatus.emit(BridgeStatus.failed);
      return;
    }
    developer.log('$error', name: 'manymatrix.bridge');
  }

  void _handleWorkerError(web.Event event) {
    event.preventDefault();
    if (_started) {
      // The module loaded, so this is a runtime fault the Worker did not
      // report itself (it posts manymatrix-fatal for those it catches), not a
      // deployment problem.
      final cause = '${event['message'].dartify() ?? event.type}';
      _markFatal(
        ManyMatrixPanicException(
          'The ManyMatrix web worker stopped after a Rust panic or trap: '
          '$cause',
          details: {'reason': 'runtime_fatal', 'cause': cause},
        ),
      );
      return;
    }
    final error = ManyMatrixStorageException(
      'The ManyMatrix web worker could not load. Verify that '
      'manymatrix_worker.js, pkg/manymatrix_web.js, and the WASM file are '
      'deployed together and served with correct MIME types.',
      details: const <String, dynamic>{},
    );
    if (!_ready.isCompleted) _ready.completeError(error);
    if (!_closed.isCompleted) _closed.complete();
    _failPending(error);
    bridgeStatus.emit(BridgeStatus.failed);
  }

  static ManyMatrixPanicException _fatalException(Object? value) {
    try {
      final error = _transportException(value);
      return ManyMatrixPanicException(error.message, details: error.details);
    } on ManyMatrixException {
      return ManyMatrixPanicException(
        'The ManyMatrix WASM runtime stopped after a Rust panic or trap.',
        details: const {'reason': 'runtime_fatal'},
      );
    }
  }

  // A panic aborts the WASM instance (panic=abort), so nothing it held is
  // usable: fail what is pending and refuse every later call. This transport
  // has no replacement path; the owner must create a new bridge.
  void _markFatal(ManyMatrixPanicException error) {
    if (_disposed || _fatal != null) return;
    _fatal = error;
    if (!_ready.isCompleted) _ready.completeError(error);
    _failPending(error);
    // The Worker closes itself after reporting a fault; terminate it anyway
    // in case it could not.
    _worker.terminate();
    if (!_closed.isCompleted) _closed.complete();
    bridgeStatus.emit(BridgeStatus.failed);
    _onEvent?.call(
      'runtime_fatal',
      jsonEncode({
        'kind': error.kind,
        'message': error.message,
        'details': error.details,
      }),
    );
  }

  void _throwIfFatal(String method) {
    final fatal = _fatal;
    if (fatal == null) return;
    throw ManyMatrixPanicException(
      'The ManyMatrix web runtime stopped after a Rust panic or trap and '
      'cannot run $method. Close this bridge and create a new one.',
      details: {...fatal.details, 'reason': 'runtime_fatal', 'method': method},
    );
  }

  void _failPending(Object error) {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> args,
  ) async {
    if (_disposed) throw StateError('ManyMatrix bridge is disposed');
    await _ready.future;
    // close() may have run during that await. It already failed the pending
    // requests, so a request registered now would sit out its full deadline.
    if (_disposed) throw StateError('ManyMatrix bridge was disposed');
    _throwIfFatal(method);
    final requestId = _nextRequestId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    _worker.postMessage(
      <String, Object?>{
        'type': 'manymatrix-call',
        'id': requestId,
        'method': method,
        'args': args,
      }.jsify(),
    );
    final timeout = webRpcTimeout(method, args);
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(requestId);
      throw ManyMatrixStorageException(
        'The ManyMatrix web worker did not answer in '
        '${timeout.inSeconds} seconds.',
        details: {'method': method},
      );
    }
  }

  @override
  Future<void> close() {
    final activeClose = _closeFuture;
    if (activeClose != null) return activeClose;
    final future = _closeWorker();
    _closeFuture = future;
    return future;
  }

  Future<void> _closeWorker() async {
    if (_disposed) return;
    _disposed = true;
    _onEvent = null;
    _failPending(StateError('ManyMatrix bridge was disposed'));
    _worker.postMessage({'type': 'manymatrix-close'}.jsify());
    await _terminateAfterClose();
  }

  Future<void> _terminateAfterClose() async {
    try {
      await _closed.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // A failed module import may prevent the close acknowledgement.
    } finally {
      // Always enforce termination so an account cannot retain a ghost loop.
      _worker.terminate();
    }
  }
}

Future<_WebTransport> _createTransport(
  String workerName, {
  String? extensionClientId,
}) async {
  if (_chromeRuntimeId()?.isNotEmpty ?? false) {
    return _ExtensionTransport.create(extensionClientId ?? workerName);
  }
  return _WorkerTransport.create(workerName);
}

class ManyMatrixBridge {
  final String _homeserverUrl;
  final String _storePath;
  final _WebTransport _transport;
  final _WebStoreLease? _storeLease;
  String? _currentSessionJson;
  int _sessionGeneration = 0;
  bool _closing = false;
  bool _revokingSession = false;
  bool _syncRunning = false;
  Future<void> _sessionPersistence = Future<void>.value();
  Future<void>? _closeFuture;
  Future<void>? _transportRecovery;

  ManyMatrixBridge._(
    this._homeserverUrl,
    this._storePath,
    this._transport,
    this._storeLease,
  ) {
    _transport.onEvent = _handleTransportEvent;
  }

  static String _storeNameFor(String homeserverUrl, String storePath) =>
      'manymatrix_${storePath.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_')}_'
      '${Uri.parse(homeserverUrl).host.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_')}';

  String get _storeName => _storeNameFor(_homeserverUrl, _storePath);

  static String _sessionKeyFor(String storeName) =>
      'manymatrix_session_$storeName';

  String get _sessionKey => _sessionKeyFor(_storeName);

  static bool _initialized = false;
  static Future<void>? _initializing;
  static final Map<String, Future<void>> _closingStores =
      <String, Future<void>>{};

  static Future<void> initialize(String libraryPath) async {
    if (_initialized) return;
    final active = _initializing;
    if (active != null) return active;
    final future = _probeRuntime();
    _initializing = future;
    try {
      await future;
      _initialized = true;
      bridgeStatus.emit(BridgeStatus.connected);
    } finally {
      _initializing = null;
    }
  }

  static Future<void> _probeRuntime() async {
    if (_chromeRuntimeId()?.isNotEmpty ?? false) {
      await _scrubLegacyExtensionStorage(ensure: true);
    }
    final transport = await _createTransport('manymatrix-runtime-probe');
    try {
      final echo = await transport.call('dispatcher.echo', {
        'message': 'runtime-probe',
      });
      if (echo['message'] != 'runtime-probe') {
        throw ManyMatrixSerdeException(
          'ManyMatrix web runtime returned an invalid probe response',
          details: const <String, dynamic>{},
        );
      }
    } finally {
      await transport.close();
    }
  }

  static Future<ManyMatrixBridge> create(
    String homeserverUrl,
    String storePath, {
    String? customCaCertificatePath,
  }) async {
    if (customCaCertificatePath != null && customCaCertificatePath.isNotEmpty) {
      throw ManyMatrixException(
        'ConfigurationError',
        'Custom CA certificate paths are supported only by the native ManyMatrix bridge',
        {
          'transport': 'web',
          'option': 'customCaCertificatePath',
        },
      );
    }
    final namespace = storePath.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    final storeName = _storeNameFor(homeserverUrl, storePath);
    final extensionMode = _chromeRuntimeId()?.isNotEmpty ?? false;
    if (extensionMode) {
      await _scrubLegacyExtensionStorage(
        expectedHomeserverUrl: homeserverUrl,
        ensure: true,
      );
    }
    final lease =
        extensionMode ? null : await _WebStoreLease.acquire(storeName);
    try {
      final transport = await _createTransport(
        'manymatrix-$namespace',
        extensionClientId: storeName,
      );
      return ManyMatrixBridge._(
        homeserverUrl,
        storePath,
        transport,
        lease,
      );
    } on Object {
      await lease?.release();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> args,
  ) async {
    final recovery = _transportRecovery;
    if (recovery != null) {
      try {
        await recovery;
      } on Object {
        // The call that started the recovery reports its failure. This one
        // runs against whatever state the replacement Worker ended up in.
      }
    }
    try {
      return await _transport.call(method, args);
    } on ManyMatrixException catch (error) {
      if (error.details['reason'] != 'worker_replaced') rethrow;
      await _restoreAfterTransportRecovery();
      return _transport.call(method, args);
    }
  }

  Future<void> _restoreAfterTransportRecovery() {
    final active = _transportRecovery;
    if (active != null) return active;
    final future = _recoverReplacedWorker();
    _transportRecovery = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_transportRecovery, future)) _transportRecovery = null;
        },
        onError: (Object _, StackTrace __) {
          if (identical(_transportRecovery, future)) _transportRecovery = null;
        },
      ),
    );
    return future;
  }

  // Rebuilds this bridge's state on a replacement extension Worker, which
  // starts without a Rust client and gated behind recovery_pending.
  Future<void> _recoverReplacedWorker() async {
    final transport = _transport;
    if (transport is! _ExtensionTransport) {
      throw StateError('Worker recovery is only valid in extension mode.');
    }
    Future<void> recoveryCall(String method, Map<String, dynamic> args) =>
        transport._callOnce('bridge.recovery_call', {
          'method': method,
          'args': args,
        });

    final sessionJson = _currentSessionJson;
    final restartSync = _syncRunning;
    // Nothing registered on the old Worker survives. Each flag is set again
    // only once the replacement has confirmed it.
    _eventsSubscribed = false;
    _customEvents.resetSubscriptions();
    _syncRunning = false;
    Object? failure;
    StackTrace? failureStack;
    try {
      if (sessionJson != null) {
        await recoveryCall('auth.restore', {
          'homeserver_url': _homeserverUrl,
          'session_json': sessionJson,
          'store_name': _storeName,
        });
        if (_hasEventCallbacks) {
          await recoveryCall('events.subscribe', <String, dynamic>{});
          _eventsSubscribed = true;
        }
        for (final eventType in _customEvents.eventTypes) {
          await recoveryCall('events.subscribe_custom', {
            'event_type': eventType,
          });
          _customEvents.markSubscribed(eventType);
        }
        if (restartSync) {
          await recoveryCall('sync.start', <String, dynamic>{});
          _syncRunning = true;
        }
      } else if (restartSync) {
        throw ManyMatrixStorageException(
          'The extension Worker was replaced without a session to restore, '
          'so background sync was not restarted.',
          details: const {'reason': 'no_session_to_restore'},
        );
      }
    } on Object catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
    }
    // Lift the gate even when the restore failed: the Worker is then simply
    // signed out, whereas leaving it gated made every later call re-run the
    // failing restore.
    try {
      await transport._callOnce(
        'bridge.recovery_complete',
        const <String, dynamic>{},
      );
    } on Object catch (error) {
      // Typically stale_owner: the next call re-claims and recovers again.
      developer.log(
        'bridge.recovery_complete failed: $error',
        name: 'manymatrix.bridge',
      );
    }
    transport._acknowledgeWorkerRecovery();
    if (failure == null) return;
    final matrixError = failure is ManyMatrixException ? failure : null;
    _onSyncStatusCallback?.call(
      jsonEncode({
        'state': 'transport_restore_failed',
        'ok': false,
        'error': '$failure',
        if (matrixError != null) 'errorKind': matrixError.kind,
        if (matrixError != null) 'errorDetails': matrixError.details,
      }),
    );
    Error.throwWithStackTrace(failure, failureStack!);
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

  Future<void> _persistSession(
    String sessionJson, {
    int? generation,
  }) {
    if (_closing || (generation != null && generation != _sessionGeneration)) {
      return Future<void>.value();
    }
    final acceptedGeneration = generation ?? _sessionGeneration;
    final previous = _sessionPersistence;
    final operation = () async {
      try {
        await previous;
      } on Object {
        // A later refresh write must still be able to repair persistence.
      }
      if (_revokingSession) return;
      _currentSessionJson = sessionJson;
      if (_transport is _ExtensionTransport) {
        final obj = {_sessionKey: sessionJson}.jsify() as JSObject;
        await _chrome.storage.local.set(obj).toDart;
        if (_revokingSession) {
          await _chrome.storage.local.remove(_sessionKey.toJS).toDart;
          return;
        }
        if (acceptedGeneration != _sessionGeneration) return;
      } else {
        web.window.sessionStorage.setItem(_sessionKey, sessionJson);
      }
      _onSessionUpdateCallback?.call(sessionJson);
    }();
    _sessionPersistence = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> _clearSession() async {
    _revokingSession = true;
    _currentSessionJson = null;
    await _sessionPersistence;
    if (_transport is _ExtensionTransport) {
      await _scrubLegacyExtensionStorage(
        expectedHomeserverUrl: _homeserverUrl,
        scopedSessionKey: _sessionKey,
        ensure: false,
      );
    } else {
      web.window.sessionStorage.removeItem(_sessionKey);
    }
  }

  /// Stores a migrated session in the transport-appropriate secret store.
  Future<void> persistSession(String sessionJson) =>
      _persistSession(sessionJson);

  /// Loads a session for this account without copying it into localStorage.
  Future<String?> loadPersistedSession() async {
    final String? sessionJson;
    if (_transport is _ExtensionTransport) {
      final result = await _chrome.storage.local.get(_sessionKey.toJS).toDart;
      final decoded = result?.dartify();
      sessionJson = decoded is Map ? decoded[_sessionKey] as String? : null;
    } else {
      sessionJson = web.window.sessionStorage.getItem(_sessionKey);
    }
    _currentSessionJson = sessionJson;
    return sessionJson;
  }

  Future<void> clearPersistedSession() => _clearSession();

  /// Removes browser state for an account after its Worker has closed.
  static Future<void> clearStoredAccount(
    String homeserverUrl,
    String storePath,
  ) async {
    final storeName = _storeNameFor(homeserverUrl, storePath);
    final closing = _closingStores[storeName];
    if (closing != null) await closing;
    await clearStoredSession(homeserverUrl, storePath);
    await _deleteIndexedDbStores(storeName);
  }

  static Future<void> clearStoredSession(
    String homeserverUrl,
    String storePath,
  ) async {
    final sessionKey = _sessionKeyFor(
      _storeNameFor(homeserverUrl, storePath),
    );
    web.window.sessionStorage.removeItem(sessionKey);
    web.window.localStorage.removeItem(sessionKey);
    if (_chromeRuntimeId()?.isNotEmpty ?? false) {
      await _scrubLegacyExtensionStorage(
        expectedHomeserverUrl: homeserverUrl,
        scopedSessionKey: sessionKey,
        ensure: false,
      );
    }
  }

  static Future<void> _deleteIndexedDbStores(String storeName) async {
    final names = <String>{
      storeName,
      '$storeName::matrix-sdk-state',
      '$storeName::matrix-sdk-crypto',
      '$storeName::matrix-sdk-crypto-meta',
    };
    Object? enumerationFailure;
    try {
      final databases = await web.window.indexedDB.databases().toDart;
      final decoded = databases.dartify();
      for (final info in decoded is List ? decoded : const <Object?>[]) {
        if (info is! Map) continue;
        final name = info['name'];
        if (name is! String) continue;
        if (name.startsWith(storeName) ||
            name.startsWith('backup-$storeName-')) {
          names.add(name);
        }
      }
    } on Object catch (error) {
      // Deterministic stores are still attempted below. We cannot prove that
      // timestamped matrix-sdk backup stores were removed without enumeration,
      // so cleanup remains retryable instead of reporting a false success.
      enumerationFailure = error;
    }
    await deleteAllMatrixStores(
      names: names,
      delete: _deleteIndexedDb,
      enumerationFailure: enumerationFailure,
    );
  }

  static Future<void> _deleteIndexedDb(String name) async {
    final request = web.window.indexedDB.deleteDatabase(name);
    final completer = Completer<void>();
    request.onsuccess = ((web.Event _) {
      if (!completer.isCompleted) completer.complete();
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(
          ManyMatrixStorageException(
            'Could not delete the local Matrix store.',
            details: {'database': name, 'cause': '${request.error}'},
          ),
        );
      }
    }).toJS;
    request.onblocked = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(
          ManyMatrixStorageException(
            'The local Matrix store is still open in another tab.',
            details: {'database': name},
          ),
        );
      }
    }).toJS;
    await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw ManyMatrixStorageException(
        'Timed out deleting the local Matrix store.',
        details: {'database': name},
      ),
    );
  }

  Future<String> login(
    String username,
    String password, {
    String? deviceId,
  }) async {
    _closing = false;
    _revokingSession = false;
    final generation = ++_sessionGeneration;
    developer.log(
      'auth.login ${_redactArgs({'username': username, 'password': password})}',
      name: 'manymatrix.bridge',
    );
    final result = await _call('auth.login', {
      'homeserver_url': _homeserverUrl,
      'username': username,
      'password': password,
      if (deviceId != null) 'device_id': deviceId,
      'store_name': _storeName,
    });
    final sessionJson = result['session_json'] as String;
    await _persistSession(sessionJson, generation: generation);
    _resubscribeEvents();
    return sessionJson;
  }

  Future<void> restore(String sessionJson) async {
    _closing = false;
    _revokingSession = false;
    _sessionGeneration += 1;
    developer.log('auth.restore', name: 'manymatrix.bridge');
    await _call('auth.restore', {
      'homeserver_url': _homeserverUrl,
      'session_json': sessionJson,
      'store_name': _storeName,
    });
    _currentSessionJson = sessionJson;
    _resubscribeEvents();
  }

  Future<String?> currentSession() async => _currentSessionJson;

  Future<void> syncOnce({Duration? timeout}) async {
    if (timeout != null && timeout.inMilliseconds < 0) {
      throw ArgumentError.value(timeout, 'timeout', 'must be non-negative');
    }
    await _call('sync.once', {
      if (timeout != null) 'timeout_ms': timeout.inMilliseconds,
    });
  }

  Future<void> syncForever() async {
    try {
      final result = await _call('sync.start', {});
      final alreadyRunning = result['already_running'] == true;
      _syncRunning = true;
      _onSyncStatusCallback?.call(jsonEncode({
        'state': alreadyRunning ? 'already_running' : 'running',
        'ok': true,
      }));
    } catch (error) {
      _onSyncStatusCallback?.call(jsonEncode({
        'state': 'start_failed',
        'ok': false,
        'error': '$error',
      }));
      rethrow;
    }
  }

  Future<void> stopSync() async {
    await _call('sync.stop', {});
    _syncRunning = false;
  }

  Future<List<RoomSummary>> joinedRooms() async {
    final result = await _call('rooms.list', {});
    final list = jsonDecode(result['rooms_json'] as String) as List<dynamic>;
    return list
        .map((e) => RoomSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<RoomInvite>> invitedRooms() async {
    final result = await _call('rooms.invited', {});
    final list = jsonDecode(result['invites_json'] as String) as List<dynamic>;
    return list
        .map((item) => RoomInvite.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<String> serverCapabilities() async {
    final result = await _call('server.capabilities', {});
    return result['capabilities_json'] as String;
  }

  Future<void> logout({bool clearPersistedSession = true}) async {
    _closing = true;
    _revokingSession = true;
    _sessionGeneration += 1;
    developer.log('auth.logout', name: 'manymatrix.bridge');
    try {
      try {
        await stopSync();
      } on Object {
        // Logout still invalidates the remote token when sync cancellation
        // itself fails.
      }
      await _call('auth.logout', {});
    } finally {
      if (clearPersistedSession) {
        await close();
        await _clearSession();
      }
    }
  }

  Future<String?> syncToken() async {
    final result = await _call('sync.status', {});
    return result['sync_token'] as String?;
  }

  Future<String?> whoami() async {
    final result = await _call('auth.whoami', {});
    return result['user_id'] as String?;
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

  Future<void> setCustomEventPowerLevels(
    String roomId,
    String eventType, {
    required int requiredPowerLevel,
    Map<String, int> userPowerLevels = const {},
  }) async {
    await _call('rooms.set_custom_event_power_levels', {
      'room_id': roomId,
      'event_type': eventType,
      'required_power_level': requiredPowerLevel,
      'user_power_levels': userPowerLevels,
    });
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

  Future<RoomDetails> roomDetails(String roomId) async {
    final result = await _call('rooms.details', {'room_id': roomId});
    return RoomDetails.fromJson(
      jsonDecode(result['details_json'] as String) as Map<String, dynamic>,
    );
  }

  Future<String?> roomPowerLevels(String roomId) async {
    final result = await _call('rooms.power_levels', {'room_id': roomId});
    return result['power_levels_json'] as String?;
  }

  Future<void> setRoomInvitePowerLevel(
    String roomId, {
    required int requiredPowerLevel,
    Map<String, int> userPowerLevels = const {},
  }) async {
    await _call('rooms.set_invite_power_level', {
      'room_id': roomId,
      'required_power_level': requiredPowerLevel,
      'user_power_levels': userPowerLevels,
    });
  }

  Future<bool> isRoomEncrypted(String roomId) async {
    final result = await _call('e2ee.is_encrypted', {'room_id': roomId});
    return result['encrypted'] as bool;
  }

  Future<String> sendText(String roomId, String body) async {
    final result =
        await _call('messages.send_text', {'room_id': roomId, 'body': body});
    return result['event_id'] as String;
  }

  /// Send a message-like event of an arbitrary [eventType] with arbitrary JSON
  /// [content] to a room. Returns the event ID.
  ///
  /// Use it for an app-specific event type (e.g. `io.example.foo`) with its
  /// own content schema. Pair with [onCustomEvent] to receive it.
  Future<String> sendCustomEvent(
    String roomId,
    String eventType,
    Map<String, dynamic> content,
  ) async {
    // Round-trip through JSON so unsupported values fail here exactly as they
    // do on the native bridge, instead of being mangled by jsify.
    final jsonContent = jsonDecode(jsonEncode(content)) as Map<String, dynamic>;
    final result = await _call('messages.send_custom_event', {
      'room_id': roomId,
      'event_type': eventType,
      'content': jsonContent,
    });
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
    String body, {
    String? inReplyToEventId,
  }) async {
    final result = await _call('messages.thread_reply', {
      'room_id': roomId,
      'thread_root_event_id': threadRootId,
      'in_reply_to_event_id': inReplyToEventId ?? threadRootId,
      'body': body,
    });
    return result['event_id'] as String;
  }

  Future<List<ThreadSummary>> threadIndex({int limitPerRoom = 50}) async {
    final result = await _call('threads.index', {
      'limit_per_room': limitPerRoom,
    });
    return (jsonDecode(result['threads_json'] as String) as List<dynamic>)
        .map((value) => ThreadSummary.fromJson(value as Map<String, dynamic>))
        .toList();
  }

  Future<PaginatedThreadMessages> getThreadMessages(
    String roomId,
    String threadRootEventId, {
    String? fromToken,
    int limit = 50,
  }) async {
    final result = await _call('threads.messages', {
      'room_id': roomId,
      'thread_root_event_id': threadRootEventId,
      'from_token': fromToken,
      'limit': limit,
    });
    return PaginatedThreadMessages.fromJson(
      jsonDecode(result['paginated_json'] as String) as Map<String, dynamic>,
    );
  }

  Future<void> sendThreadReadReceipt(
    String roomId,
    String threadRootEventId,
    String eventId,
  ) async {
    await _call('threads.read_receipt', {
      'room_id': roomId,
      'thread_root_event_id': threadRootEventId,
      'event_id': eventId,
    });
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

  Future<void> startSas(String userId, String flowId) async {
    await _call('e2ee.start_sas', {'user_id': userId, 'flow_id': flowId});
  }

  Future<void> acceptSas(String userId, String flowId) async {
    await _call('e2ee.accept_sas', {'user_id': userId, 'flow_id': flowId});
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

  Future<String> enableRecovery() async {
    final result = await _call('e2ee.enable_recovery', {});
    return result['recovery_key'] as String;
  }

  Future<void> waitForBackupUpload() async {
    await _call('e2ee.wait_for_backup_upload', {});
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

  /// Download and, when required, decrypt a complete Matrix media source.
  Future<Uint8List?> downloadMediaSource(
    Map<String, dynamic> mediaSource,
  ) async {
    final result = await _call('media.download', {
      'media_source': mediaSource,
    });
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
  // Both transports normalize pushed events to `(kind, payload)`: the module
  // Worker posts them directly, while the extension broadcasts them through
  // chrome.runtime from its offscreen document.

  void Function(String json)? _onMessageCallback;
  void Function(String json)? _onReactionCallback;
  void Function(String json)? _onReceiptCallback;
  void Function(String json)? _onSyncStatusCallback;
  void Function(String json)? _onSessionUpdateCallback;
  final CustomEventListeners _customEvents = CustomEventListeners();
  bool _eventsSubscribed = false;

  bool get _hasEventCallbacks =>
      _onMessageCallback != null ||
      _onReactionCallback != null ||
      _onReceiptCallback != null ||
      _onSyncStatusCallback != null ||
      _onSessionUpdateCallback != null;

  void _handleTransportEvent(String kind, String payload) {
    switch (kind) {
      case 'message':
        _onMessageCallback?.call(payload);
      case 'reaction':
        _onReactionCallback?.call(payload);
      case 'receipt':
        _onReceiptCallback?.call(payload);
      case 'custom_event':
        _customEvents.dispatch(payload);
      case 'runtime_fatal':
        _handleRuntimeFatal(payload);
      case 'sync_status':
        _onSyncStatusCallback?.call(payload);
      case 'session_update':
        final generation = _sessionGeneration;
        unawaited(
          _persistSession(payload, generation: generation).catchError((
            Object error,
            StackTrace stackTrace,
          ) {
            _onSyncStatusCallback?.call(
              jsonEncode({
                'state': 'session_persistence_failed',
                'ok': false,
                'error': '$error',
              }),
            );
          }),
        );
    }
  }

  // The Worker's WASM instance aborted, taking its Rust client, sync loop,
  // and event handlers with it. Extension mode re-claims a fresh Worker on
  // the next call and restores the session; the module Worker transport
  // fails every later call.
  void _handleRuntimeFatal(String payload) {
    _eventsSubscribed = false;
    _customEvents.resetSubscriptions();
    if (!_syncRunning) return;
    // Report the dead loop like a failed sync exit instead of restarting it
    // during recovery, where a panic inside sync would just repeat.
    _syncRunning = false;
    var error = const <String, dynamic>{};
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map) error = _stringMap(decoded);
    } on FormatException {
      // Report the generic status below.
    }
    final message = error['message'];
    final details = error['details'];
    _onSyncStatusCallback?.call(
      jsonEncode({
        'state': 'exited',
        'ok': false,
        'error': message is String
            ? message
            : 'The ManyMatrix web runtime stopped after a Rust panic or trap.',
        'errorKind': 'PanicError',
        'errorDetails':
            details is Map ? details : const {'reason': 'runtime_fatal'},
      }),
    );
  }

  void _ensureEventChannel() {
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

  void _ensureCustomEventSubscription(String eventType) {
    final token = _customEvents.beginSubscription(eventType);
    if (token == null) return;
    unawaited(
      _call('events.subscribe_custom', {'event_type': eventType}).catchError((
        Object e,
      ) {
        _customEvents.subscriptionFailed(eventType, token);
        developer.log(
          'events.subscribe_custom failed for $eventType: $e',
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
    _customEvents.resetSubscriptions();
    for (final eventType in _customEvents.eventTypes) {
      _ensureCustomEventSubscription(eventType);
    }
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

  /// Register a callback for incoming custom (non-standard) message-like
  /// events whose event type matches [eventType] exactly. Pairs with
  /// [sendCustomEvent].
  ///
  /// The callback receives a JSON-serialized CustomEvent string (`event_id`,
  /// `room_id`, `sender`, `event_type`, `content`, `timestamp`). Like the
  /// native bridge, every call adds a listener rather than replacing one, so
  /// several callbacks (and several event types) can be registered.
  void onCustomEvent(String eventType, void Function(String json) callback) {
    _customEvents.addListener(eventType, callback);
    _ensureCustomEventSubscription(eventType);
  }

  void onSyncStatus(void Function(String json) callback) {
    _onSyncStatusCallback = callback;
    _ensureEventChannel();
  }

  void onSessionUpdate(void Function(String sessionJson) callback) {
    _onSessionUpdateCallback = callback;
    _ensureEventChannel();
  }

  void _detachCallbacks() {
    _transport.onEvent = null;
    _onMessageCallback = null;
    _onReactionCallback = null;
    _onReceiptCallback = null;
    _onSyncStatusCallback = null;
    _onSessionUpdateCallback = null;
    _customEvents.clear();
    _eventsSubscribed = false;
  }

  Future<void> close() {
    final activeClose = _closeFuture;
    if (activeClose != null) return activeClose;
    _closing = true;
    _syncRunning = false;
    _sessionGeneration += 1;
    _detachCallbacks();
    final future = () async {
      try {
        await _transport.close();
        await _sessionPersistence;
      } finally {
        await _storeLease?.release();
      }
    }();
    _closeFuture = future;
    _closingStores[_storeName] = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_closingStores[_storeName], future)) {
            _closingStores.remove(_storeName);
          }
        },
        onError: (Object _, StackTrace __) {
          if (identical(_closingStores[_storeName], future)) {
            _closingStores.remove(_storeName);
          }
        },
      ),
    );
    return future;
  }

  void dispose() {
    unawaited(close().catchError((Object _, StackTrace __) {}));
  }
}

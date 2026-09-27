const Duration _defaultWebRpcTimeout = Duration(seconds: 30);
const Duration _longWebRpcTimeout = Duration(minutes: 5);

// matrix-sdk's default long-poll timeout, used when sync.once has no
// timeout_ms.
const Duration _defaultSyncTimeout = Duration(seconds: 30);

// Room on top of the long-poll for the request itself, plus a background
// sync round that may still hold the client's sync guard (up to ~35 s).
const Duration _syncOnceAllowance = Duration(seconds: 40);

// Methods whose work is bounded by key backup size or server round trips
// rather than one request.
const Set<String> _longRunningMethods = {
  'auth.restore',
  'e2ee.bootstrap_cross_signing',
  'e2ee.enable_recovery',
  'e2ee.restore_key_backup',
  'e2ee.wait_for_backup_upload',
};

/// The transport deadline for one web RPC.
///
/// [args] is consulted for `sync.once` (its `timeout_ms`) and for
/// `bridge.recovery_call`, whose deadline is that of the wrapped call.
Duration webRpcTimeout(
  String method, [
  Map<String, dynamic> args = const <String, dynamic>{},
]) {
  if (method == 'bridge.recovery_call') {
    final inner = args['method'];
    final innerArgs = args['args'];
    return webRpcTimeout(
      inner is String ? inner : '',
      innerArgs is Map<String, dynamic> ? innerArgs : const {},
    );
  }
  if (method.startsWith('media.') || _longRunningMethods.contains(method)) {
    return _longWebRpcTimeout;
  }
  if (method == 'sync.once') {
    final timeoutMs = args['timeout_ms'];
    final syncTimeout = timeoutMs is int && timeoutMs >= 0
        ? Duration(milliseconds: timeoutMs)
        : _defaultSyncTimeout;
    return syncTimeout + _syncOnceAllowance;
  }
  return _defaultWebRpcTimeout;
}

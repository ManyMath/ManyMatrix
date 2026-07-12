const Duration _defaultWebRpcTimeout = Duration(seconds: 30);
const Duration _mediaWebRpcTimeout = Duration(minutes: 5);

Duration webRpcTimeout(String method) =>
    method.startsWith('media.') ? _mediaWebRpcTimeout : _defaultWebRpcTimeout;

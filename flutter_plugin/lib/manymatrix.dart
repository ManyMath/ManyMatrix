/// ManyMatrix Flutter plugin public API.
library;

export 'src/bridge_status.dart'
    show BridgeStatus, BridgeStatusNotifier, bridgeStatus;
export 'src/native_bridge.dart'
    if (dart.library.js_interop) 'src/web_bridge.dart' show ManyMatrixBridge;
export 'src/models/models.dart';
export 'src/web_bridge_errors.dart';

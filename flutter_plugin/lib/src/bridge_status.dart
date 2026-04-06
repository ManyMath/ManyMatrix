import 'dart:async';

enum BridgeStatus { connected, reconnecting, failed }

class BridgeStatusNotifier {
  final StreamController<BridgeStatus> _controller =
      StreamController<BridgeStatus>.broadcast();
  BridgeStatus _current = BridgeStatus.connected;

  Stream<BridgeStatus> get stream => _controller.stream;
  BridgeStatus get current => _current;

  void emit(BridgeStatus status) {
    if (_current == status) return;
    _current = status;
    _controller.add(status);
  }

  void dispose() {
    _controller.close();
  }
}

final bridgeStatus = BridgeStatusNotifier();

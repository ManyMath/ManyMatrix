import 'package:flutter_test/flutter_test.dart';
import 'package:manymatrix/manymatrix.dart';

void main() {
  test('ManyMatrixBridge class exists and has expected API', () {
    // Verify the class exists and has the expected type reference.
    // Cannot test actual FFI without native library loaded.
    expect(ManyMatrixBridge, isNotNull);
  });

  test('ManyMatrixBridge exposes sync status callback API', () {
    void acceptsSyncStatusRegistrar(
      void Function(ManyMatrixBridge, void Function(String)) registrar,
    ) {
      expect(registrar,
          isA<void Function(ManyMatrixBridge, void Function(String))>());
    }

    acceptsSyncStatusRegistrar(
      (bridge, callback) => bridge.onSyncStatus(callback),
    );
  });
}

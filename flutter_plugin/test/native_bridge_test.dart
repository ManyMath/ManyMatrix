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

  test('native error mapper returns structured exception types', () {
    final serde = manyMatrixExceptionForNativeError(
      'invalid content_json: expected value',
      method: 'send_custom_event',
    );
    expect(serde, isA<ManyMatrixSerdeException>());
    expect(serde.kind, 'SerdeError');
    expect(serde.details['method'], 'send_custom_event');

    final sdk = manyMatrixExceptionForEnvelope(
      'MatrixSdkError',
      'M_FORBIDDEN: not allowed',
      details: const {'method': 'invite'},
    );
    expect(sdk, isA<ManyMatrixSdkException>());
    expect(sdk.details['method'], 'invite');
  });
}

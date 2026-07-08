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

  test('ManyMatrixBridge exposes custom event power-level API', () {
    void acceptsPowerLevelConfigurator(
      Future<void> Function(ManyMatrixBridge) configure,
    ) {
      expect(configure, isA<Future<void> Function(ManyMatrixBridge)>());
    }

    acceptsPowerLevelConfigurator(
      (bridge) => bridge.setCustomEventPowerLevels(
        '!room:example.org',
        'io.manymath.playback',
        requiredPowerLevel: 50,
        userPowerLevels: const {'@leader:example.org': 50},
      ),
    );
  });

  test('ManyMatrixBridge exposes room power-level snapshot API', () {
    void acceptsPowerLevelReader(
      Future<String?> Function(ManyMatrixBridge) read,
    ) {
      expect(read, isA<Future<String?> Function(ManyMatrixBridge)>());
    }

    acceptsPowerLevelReader(
      (bridge) => bridge.roomPowerLevels('!room:example.org'),
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

  test('Matrix SDK error mapper preserves Matrix errcodes', () {
    final native = manyMatrixExceptionForNativeError(
      'matrix SDK error: [404 / M_NOT_FOUND] user was not found',
      method: 'invite',
    );
    expect(native, isA<ManyMatrixSdkException>());
    expect(native.details['errcode'], 'M_NOT_FOUND');
    expect(native.details['method'], 'invite');

    final web = manyMatrixExceptionForEnvelope(
      'MatrixSdkError',
      '[403 / M_FORBIDDEN] invite denied',
      details: const {'transport': 'web', 'status_code': 403},
    );
    expect(web, isA<ManyMatrixSdkException>());
    expect(web.details['errcode'], 'M_FORBIDDEN');
    expect(web.details['status_code'], 403);
    expect(web.details['transport'], 'web');

    final preserved = manyMatrixExceptionForEnvelope(
      'MatrixSdkError',
      '[403 / M_FORBIDDEN] invite denied',
      details: const {'errcode': 'M_LIMIT_EXCEEDED'},
    );
    expect(preserved.details['errcode'], 'M_LIMIT_EXCEEDED');
  });

  test('native error mapper parses structured FFI error envelopes', () {
    final native = manyMatrixExceptionForNativeError(
      '{"manymatrix_ffi_error":1,"kind":"MatrixSdkError","message":"[403 / M_FORBIDDEN] invite denied","details":{"status_code":403,"errcode":"M_FORBIDDEN"}}',
      method: 'invite',
    );

    expect(native, isA<ManyMatrixSdkException>());
    expect(native.message, '[403 / M_FORBIDDEN] invite denied');
    expect(native.details['transport'], 'native_ffi');
    expect(native.details['method'], 'invite');
    expect(native.details['status_code'], 403);
    expect(native.details['errcode'], 'M_FORBIDDEN');
  });
}

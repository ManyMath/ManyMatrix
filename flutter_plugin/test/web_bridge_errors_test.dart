import 'package:flutter_test/flutter_test.dart';
import 'package:manymatrix/src/web_bridge_errors.dart';

void main() {
  test('a PanicError envelope maps to ManyMatrixPanicException', () {
    final error = manyMatrixExceptionForEnvelope(
      'PanicError',
      'The ManyMatrix WASM runtime stopped after a Rust panic or trap: '
          'RuntimeError: unreachable',
      details: {'reason': 'runtime_fatal'},
    );

    expect(error, isA<ManyMatrixPanicException>());
    expect(error.kind, 'PanicError');
    expect(error.details['reason'], 'runtime_fatal');
  });

  test('native error text mentioning a panic still maps to PanicError', () {
    final error = manyMatrixExceptionForNativeError(
      'thread panicked at core/src/client.rs:1:1',
      method: 'sync_once',
    );

    expect(error, isA<ManyMatrixPanicException>());
    expect(error.details['method'], 'sync_once');
  });
}

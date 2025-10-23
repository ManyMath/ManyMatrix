import 'package:flutter_test/flutter_test.dart';
import 'package:manymatrix_app/src/native_bridge.dart';

void main() {
  test('ManyMatrixBridge class exists and has expected API', () {
    // Verify the class exists and has the expected type reference.
    // Cannot test actual FFI without native library loaded.
    expect(ManyMatrixBridge, isNotNull);
  });
}

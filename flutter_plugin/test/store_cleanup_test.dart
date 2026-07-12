import 'package:flutter_test/flutter_test.dart';
import 'package:manymatrix/src/store_cleanup.dart';
import 'package:manymatrix/src/web_bridge_errors.dart';

void main() {
  test('store cleanup attempts every database and aggregates failures',
      () async {
    final attempted = <String>[];

    await expectLater(
      deleteAllMatrixStores(
        names: const <String>['state', 'crypto', 'meta'],
        delete: (name) async {
          attempted.add(name);
          if (name != 'crypto') throw StateError('$name blocked');
        },
      ),
      throwsA(
        isA<ManyMatrixStorageException>().having(
          (error) => error.details['failures'],
          'failures',
          containsPair('state', contains('blocked')),
        ),
      ),
    );

    expect(attempted, const <String>['state', 'crypto', 'meta']);
  });

  test('missing database enumeration remains an explicit retryable failure',
      () async {
    final attempted = <String>[];

    await expectLater(
      deleteAllMatrixStores(
        names: const <String>['state', 'crypto'],
        delete: (name) async => attempted.add(name),
        enumerationFailure: UnsupportedError('databases() unavailable'),
      ),
      throwsA(isA<ManyMatrixStorageException>()),
    );

    expect(attempted, const <String>['state', 'crypto']);
  });
}

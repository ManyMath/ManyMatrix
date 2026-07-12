import 'web_bridge_errors.dart';

Future<void> deleteAllMatrixStores({
  required Iterable<String> names,
  required Future<void> Function(String name) delete,
  Object? enumerationFailure,
}) async {
  final failures = <String, String>{};
  if (enumerationFailure != null) {
    failures['<backup enumeration>'] = '$enumerationFailure';
  }
  for (final name in names) {
    try {
      await delete(name);
    } on Object catch (error) {
      failures[name] = '$error';
    }
  }
  if (failures.isNotEmpty) {
    throw ManyMatrixStorageException(
      'Could not remove every local Matrix store. Close other ManyMatrix '
      'tabs and retry.',
      details: <String, dynamic>{'failures': failures},
    );
  }
}

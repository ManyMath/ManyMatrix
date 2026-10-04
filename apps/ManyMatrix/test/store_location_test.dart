import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:manymatrix_app/src/platform/store_location.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late Directory root;
  late Directory legacyRoot;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('store_location_test_');
    root = Directory(p.join(sandbox.path, 'support', 'stores'));
    legacyRoot = Directory(p.join(sandbox.path, 'tmp', 'stores'));
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  AccountStoreLocator locator({Directory? legacy, List<Object>? errors}) =>
      AccountStoreLocator(
        root: () async => root,
        legacyRoot: legacy,
        onMigrationError: (error, _) => errors?.add(error),
      );

  void writeLegacyStore(String name) {
    final store = Directory(p.join(legacyRoot.path, name, 'crypto'))
      ..createSync(recursive: true);
    File(p.join(store.path, 'keys.sqlite3')).writeAsStringSync('olm');
    File(p.join(legacyRoot.path, name, 'state.sqlite3')).writeAsStringSync('s');
  }

  test('creates a separate directory per account under the root', () async {
    final stores = locator();

    final first = await stores.pathFor('1700000000000000');
    final second = await stores.pathFor('@bob:example.org');

    expect(first, p.join(root.path, '1700000000000000'));
    expect(second, p.join(root.path, '_bob_example.org'));
    expect(Directory(first).existsSync(), isTrue);
    expect(Directory(second).existsSync(), isTrue);
  });

  test('moves a legacy store to the new root once', () async {
    writeLegacyStore('acct');
    final errors = <Object>[];
    final stores = locator(legacy: legacyRoot, errors: errors);

    final path = await stores.pathFor('acct');

    expect(path, p.join(root.path, 'acct'));
    expect(
      File(p.join(path, 'crypto', 'keys.sqlite3')).readAsStringSync(),
      'olm',
    );
    expect(File(p.join(path, 'state.sqlite3')).readAsStringSync(), 's');
    expect(Directory(p.join(legacyRoot.path, 'acct')).existsSync(), isFalse);
    expect(errors, isEmpty);
  });

  test('keeps an existing new store over a legacy one', () async {
    writeLegacyStore('acct');
    final current = Directory(p.join(root.path, 'acct'))
      ..createSync(recursive: true);
    File(p.join(current.path, 'state.sqlite3')).writeAsStringSync('current');

    final path = await locator(legacy: legacyRoot).pathFor('acct');

    expect(path, current.path);
    expect(File(p.join(path, 'state.sqlite3')).readAsStringSync(), 'current');
    expect(Directory(p.join(legacyRoot.path, 'acct')).existsSync(), isTrue);
  });

  test('only migrates the requested account', () async {
    writeLegacyStore('a');
    writeLegacyStore('b');

    await locator(legacy: legacyRoot).pathFor('a');

    expect(Directory(p.join(root.path, 'a')).existsSync(), isTrue);
    expect(Directory(p.join(root.path, 'b')).existsSync(), isFalse);
    expect(Directory(p.join(legacyRoot.path, 'b')).existsSync(), isTrue);
  });

  test('concurrent lookups share one migration', () async {
    writeLegacyStore('acct');
    final stores = locator(legacy: legacyRoot);

    final paths = await Future.wait(<Future<String>>[
      stores.pathFor('acct'),
      stores.pathFor('acct'),
    ]);

    expect(paths, everyElement(p.join(root.path, 'acct')));
    expect(
      File(p.join(root.path, 'acct', 'state.sqlite3')).readAsStringSync(),
      's',
    );
  });

  test(
    'a failed move keeps using the legacy store instead of an empty one',
    () async {
      writeLegacyStore('acct');
      // A file where the root directory should be makes every move fail.
      root.parent.createSync(recursive: true);
      File(root.path).writeAsStringSync('not a directory');
      final errors = <Object>[];
      var resolved = 0;
      final stores = AccountStoreLocator(
        root: () async {
          resolved += 1;
          return root;
        },
        legacyRoot: legacyRoot,
        onMigrationError: (error, _) => errors.add(error),
      );

      final path = await stores.pathFor('acct');

      expect(path, p.join(legacyRoot.path, 'acct'));
      expect(File(p.join(path, 'state.sqlite3')).readAsStringSync(), 's');
      expect(errors, hasLength(1));
      expect(resolved, 1);

      // The move is not retried within the same process.
      File(root.path).deleteSync();
      expect(await stores.pathFor('acct'), path);
      expect(errors, hasLength(1));
    },
  );

  test('copies the store when it cannot be renamed across devices', () async {
    writeLegacyStore('acct');
    final legacy = p.join(legacyRoot.path, 'acct');
    final errors = <Object>[];
    final stores = AccountStoreLocator(
      root: () async => root,
      legacyRoot: legacyRoot,
      onMigrationError: (error, _) => errors.add(error),
      rename: (source, newPath) async {
        if (source.path == legacy) {
          throw FileSystemException('Invalid cross-device link', source.path);
        }
        await source.rename(newPath);
      },
    );

    final path = await stores.pathFor('acct');

    expect(path, p.join(root.path, 'acct'));
    expect(
      File(p.join(path, 'crypto', 'keys.sqlite3')).readAsStringSync(),
      'olm',
    );
    expect(File(p.join(path, 'state.sqlite3')).readAsStringSync(), 's');
    expect(Directory(legacy).existsSync(), isFalse);
    expect(Directory('$path.migrating').existsSync(), isFalse);
    expect(errors, isEmpty);
  });

  test('a failed copy leaves the legacy store intact and in use', () async {
    writeLegacyStore('acct');
    final legacy = p.join(legacyRoot.path, 'acct');
    final errors = <Object>[];
    final stores = AccountStoreLocator(
      root: () async => root,
      legacyRoot: legacyRoot,
      onMigrationError: (error, _) => errors.add(error),
      rename: (source, newPath) async =>
          throw FileSystemException('Invalid cross-device link', source.path),
    );

    final path = await stores.pathFor('acct');

    expect(path, legacy);
    expect(File(p.join(legacy, 'state.sqlite3')).readAsStringSync(), 's');
    expect(Directory(p.join(root.path, 'acct')).existsSync(), isFalse);
    expect(
      Directory(p.join(root.path, 'acct.migrating')).existsSync(),
      isFalse,
    );
    expect(errors, hasLength(1));
  });

  test('a missing legacy store resolves to a fresh directory', () async {
    final errors = <Object>[];

    final path = await locator(
      legacy: legacyRoot,
      errors: errors,
    ).pathFor('acct');

    expect(path, p.join(root.path, 'acct'));
    expect(Directory(path).existsSync(), isTrue);
    expect(errors, isEmpty);
  });
}

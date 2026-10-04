import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

/// Directory, under a store root, holding one subdirectory per account.
const String accountStoresDirectoryName = 'manymatrix_app_store';

/// The per-account store directory name. Each account gets its own, so
/// accounts never share a store (sharing one would corrupt each other's
/// state).
String accountStoreDirectoryName(String accountId) =>
    accountId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

/// Resolves the directory holding each account's Matrix SDK store, which
/// includes the E2EE crypto store.
///
/// Earlier builds kept stores under the system temp directory, which many
/// systems clear on reboot. The first time an account is resolved in this
/// process, a store found under [legacyRoot] is moved to [root] if the
/// account has none there yet.
class AccountStoreLocator {
  AccountStoreLocator({
    required this.root,
    this.legacyRoot,
    this.onMigrationError,
    @visibleForTesting Future<void> Function(Directory, String)? rename,
  }) : _rename = rename ?? _renameDirectory;

  /// Resolves the directory account stores live in.
  final Future<Directory> Function() root;

  /// Where earlier builds kept account stores, or null to skip migration.
  final Directory? legacyRoot;

  /// Called when a legacy store could not be moved. Migration is best effort
  /// and never fails path resolution.
  final void Function(Object error, StackTrace stackTrace)? onMigrationError;

  final Future<void> Function(Directory source, String newPath) _rename;

  // At most one migration per account directory per process. Concurrent
  // callers await the same one, so none opens a store that is mid-move.
  final _migrations = <String, Future<void>>{};

  /// The store directory for [accountId], created if missing.
  Future<String> pathFor(String accountId) async {
    final name = accountStoreDirectoryName(accountId);
    final target = Directory(p.join((await root()).path, name));
    final legacyRoot = this.legacyRoot;
    if (legacyRoot != null) {
      final legacy = Directory(p.join(legacyRoot.path, name));
      await (_migrations[name] ??= _migrate(legacy, target));
      if (!await target.exists() && await legacy.exists()) {
        // The move failed. An empty store would pair the saved device ID with
        // fresh keys, so keep using the old one until a later launch moves it.
        return legacy.path;
      }
    }
    await target.create(recursive: true);
    return target.path;
  }

  Future<void> _migrate(Directory legacy, Directory target) async {
    try {
      if (await target.exists() || !await legacy.exists()) return;
      await target.parent.create(recursive: true);
      try {
        await _rename(legacy, target.path);
        return;
      } on FileSystemException {
        // Usually a cross-device rename (the temp dir is often a tmpfs).
      }
      // Copy into a staging directory so a partial copy never looks like a
      // complete store.
      final staging = Directory('${target.path}.migrating');
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
        await _copyDirectory(legacy, staging);
        await _rename(staging, target.path);
      } on Object {
        try {
          if (await staging.exists()) await staging.delete(recursive: true);
        } on Object {
          // The next attempt deletes it first.
        }
        rethrow;
      }
      await legacy.delete(recursive: true);
    } on Object catch (error, stackTrace) {
      onMigrationError?.call(error, stackTrace);
    }
  }
}

Future<void> _renameDirectory(Directory source, String newPath) =>
    source.rename(newPath);

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final destinationPath = p.join(destination.path, p.basename(entity.path));
    if (entity is Link) {
      await Link(destinationPath).create(await entity.target());
    } else if (entity is Directory) {
      await _copyDirectory(entity, Directory(destinationPath));
    } else if (entity is File) {
      await entity.copy(destinationPath);
    }
  }
}

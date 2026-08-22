import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/runtime.dart';
import '../platform/homeserver_policy.dart';
import 'bridge_service.dart';

const _prefsAccountsKey = 'manymatrix.accounts';
const _prefsActiveIdKey = 'manymatrix.accounts.activeId';

/// One saved Matrix login, identified by [id] so switching/removal doesn't
/// depend on matching homeserver+userId (a user may re-add an account under
/// a fresh id after forgetting it).
class SavedAccount {
  const SavedAccount({
    required this.id,
    required this.label,
    required this.homeserverUrl,
    this.userId,
    this.deviceId,
    this.localCleanupRequired = false,
  });

  /// Stable identifier, generated once when the account is added. Also used
  /// to scope the account's on-disk store path (see [defaultStorePath]).
  final String id;

  /// User-facing name shown in the switcher (e.g. "Work").
  final String label;

  final String homeserverUrl;

  /// The Matrix user ID once known (set after a successful login/restore).
  final String? userId;

  /// Non-secret Matrix device identity used to reopen the existing E2EE store
  /// during password reauthentication.
  final String? deviceId;

  /// The legacy locator was too malformed to derive an IndexedDB namespace.
  /// The account remains visible so the user can explicitly Forget it.
  final bool localCleanupRequired;

  SavedAccount copyWith({
    String? label,
    String? homeserverUrl,
    String? userId,
    String? deviceId,
    bool? localCleanupRequired,
  }) {
    return SavedAccount(
      id: id,
      label: label ?? this.label,
      homeserverUrl: homeserverUrl ?? this.homeserverUrl,
      userId: userId ?? this.userId,
      deviceId: deviceId ?? this.deviceId,
      localCleanupRequired: localCleanupRequired ?? this.localCleanupRequired,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    'homeserverUrl': homeserverUrl,
    'userId': userId,
    'deviceId': deviceId,
    if (localCleanupRequired) 'localCleanupRequired': true,
  };

  factory SavedAccount.fromJson(Map<String, Object?> json) {
    return SavedAccount(
      id: json['id']! as String,
      label: json['label']! as String,
      homeserverUrl: json['homeserverUrl']! as String,
      userId: json['userId'] as String?,
      deviceId: json['deviceId'] as String?,
      localCleanupRequired: json['localCleanupRequired'] == true,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SavedAccount &&
        other.id == id &&
        other.label == label &&
        other.homeserverUrl == homeserverUrl &&
        other.userId == userId &&
        other.deviceId == deviceId &&
        other.localCleanupRequired == localCleanupRequired;
  }

  @override
  int get hashCode => Object.hash(
    id,
    label,
    homeserverUrl,
    userId,
    deviceId,
    localCleanupRequired,
  );
}

/// All saved accounts, in add order. Empty until [accountsLoaderProvider]
/// restores any previously-persisted accounts (unlike ManyTier's
/// connections, there is no built-in default: an empty list means "show
/// the login page").
final accountsProvider = StateProvider<List<SavedAccount>>(
  (ref) => const <SavedAccount>[],
);

/// The id of the currently-active account, or null before the loader runs /
/// when no accounts are saved.
final activeAccountIdProvider = StateProvider<String?>((ref) => null);

/// The currently-active account's saved settings, or null when none is
/// active (no accounts saved yet).
final activeAccountProvider = Provider<SavedAccount?>((ref) {
  final accounts = ref.watch(accountsProvider);
  final activeId = ref.watch(activeAccountIdProvider);
  for (final account in accounts) {
    if (account.id == activeId) return account;
  }
  return null;
});

abstract interface class AccountsMetadataRepository {
  Future<void> save(List<SavedAccount> accounts, String? activeId);
}

class SharedPreferencesAccountsMetadataRepository
    implements AccountsMetadataRepository {
  Future<void> _tail = Future<void>.value();

  @override
  Future<void> save(List<SavedAccount> accounts, String? activeId) {
    final previous = _tail;
    final operation = () async {
      try {
        await previous;
      } on Object {
        // A later mutation must be able to repair a failed durable write.
      }
      final prefs = await SharedPreferences.getInstance();
      final accountsSaved = await prefs.setString(
        _prefsAccountsKey,
        jsonEncode(accounts.map((account) => account.toJson()).toList()),
      );
      if (!accountsSaved) {
        throw StateError('Could not save Matrix account metadata.');
      }
      final activeSaved = activeId == null
          ? await prefs.remove(_prefsActiveIdKey)
          : await prefs.setString(_prefsActiveIdKey, activeId);
      if (!activeSaved) {
        throw StateError('Could not save the active Matrix account.');
      }
    }();
    _tail = operation.then<void>((_) {}, onError: (_, __) {});
    return operation;
  }
}

final accountsMetadataRepositoryProvider = Provider<AccountsMetadataRepository>(
  (ref) => SharedPreferencesAccountsMetadataRepository(),
);

final rejectedAccountLocalDataCleanerProvider =
    Provider<Future<void> Function(String accountId, String homeserverUrl)>((
      ref,
    ) {
      return (accountId, homeserverUrl) =>
          BridgeMatrixService.clearAccountLocalData(
            accountId: accountId,
            homeserverUrl: homeserverUrl,
          );
    });

Future<void> scrubLegacyBrowserSessions({
  required SharedPreferences preferences,
  required String? activeId,
  required bool browserOwnsSessionPersistence,
}) async {
  if (!browserOwnsSessionPersistence) return;
  final activeSessionKey = activeId == null
      ? null
      : 'manymatrix.$activeId.session';
  final keysToScrub = preferences
      .getKeys()
      .where(
        (key) =>
            key.startsWith('manymatrix.') &&
            key.endsWith('.session') &&
            key != activeSessionKey,
      )
      .toList();
  for (final key in keysToScrub) {
    final removed = await preferences.remove(key);
    if (!removed) {
      throw StateError('Could not remove a legacy Matrix session.');
    }
  }
}

/// Loads previously persisted accounts, if any, and seeds
/// [accountsProvider]/[activeAccountIdProvider] exactly once. `app.dart`
/// reads this via `ref.watch` so the load kicks off at startup; the
/// `AsyncValue` itself is discarded, only the one-time side effect of
/// updating the providers above matters.
final accountsLoaderProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_prefsAccountsKey);
  var accounts = <SavedAccount>[];
  var loadedAccounts = <SavedAccount>[];
  final rejectedAccounts = <(SavedAccount, String)>[];
  final unlocatableAccounts = <SavedAccount>[];
  var metadataChanged = false;
  if (raw != null) {
    try {
      final decoded = jsonDecode(raw) as List<Object?>;
      loadedAccounts = decoded
          .map((e) => SavedAccount.fromJson(e! as Map<String, Object?>))
          .toList();
      for (final account in loadedAccounts) {
        final canonical = canonicalHomeserverUrl(account.homeserverUrl);
        if (canonical == null) {
          final cleanupUrl = homeserverUrlForCleanup(account.homeserverUrl);
          if (cleanupUrl == null) {
            unlocatableAccounts.add(account);
            metadataChanged = true;
            continue;
          }
          rejectedAccounts.add((account, cleanupUrl));
          metadataChanged = true;
          continue;
        }
        if (canonical != account.homeserverUrl) metadataChanged = true;
        accounts.add(account.copyWith(homeserverUrl: canonical));
      }
    } catch (_) {
      // Corrupt prefs value (e.g. from a future format): start with no
      // saved accounts rather than crashing at startup.
      accounts = <SavedAccount>[];
      loadedAccounts = <SavedAccount>[];
      rejectedAccounts.clear();
      unlocatableAccounts.clear();
      metadataChanged = true;
    }
  }
  for (final account in unlocatableAccounts) {
    final homeserverKey = 'manymatrix.${account.id}.homeserver';
    final sessionKey = 'manymatrix.${account.id}.session';
    if (prefs.containsKey(homeserverKey) &&
        !await prefs.remove(homeserverKey)) {
      throw StateError('Could not scrub invalid Matrix account metadata.');
    }
    if (prefs.containsKey(sessionKey) && !await prefs.remove(sessionKey)) {
      throw StateError('Could not scrub an invalid Matrix session.');
    }
    accounts.add(
      account.copyWith(
        homeserverUrl: 'https://invalid.localhost',
        localCleanupRequired: true,
      ),
    );
  }
  for (final rejected in rejectedAccounts) {
    await ref.read(rejectedAccountLocalDataCleanerProvider)(
      rejected.$1.id,
      rejected.$2,
    );
  }
  final originalPreferenceKeys = prefs.getKeys();
  final accountsById = <String, SavedAccount>{
    for (final account in accounts) account.id: account,
  };

  // The per-account homeserver is the URL that restore uses. When a
  // valid older value differs from list metadata, preserve that session's
  // authority and reconcile both copies to it. This also makes Forget delete
  // the same store that restore opened.
  for (var index = 0; index < accounts.length; index += 1) {
    var account = accounts[index];
    final homeserverKey = 'manymatrix.${account.id}.homeserver';
    final storedHomeserver = prefs.getString(homeserverKey);
    final canonicalStored = storedHomeserver == null
        ? null
        : canonicalHomeserverUrl(storedHomeserver);
    if (storedHomeserver != null && canonicalStored == null) {
      final cleanupUrl = homeserverUrlForCleanup(storedHomeserver);
      if (cleanupUrl == null) {
        final sessionKey = 'manymatrix.${account.id}.session';
        if (prefs.containsKey(homeserverKey) &&
            !await prefs.remove(homeserverKey)) {
          throw StateError('Could not scrub invalid Matrix account metadata.');
        }
        if (prefs.containsKey(sessionKey) && !await prefs.remove(sessionKey)) {
          throw StateError('Could not scrub an invalid Matrix session.');
        }
        account = account.copyWith(localCleanupRequired: true);
        accounts[index] = account;
        accountsById[account.id] = account;
        metadataChanged = true;
      } else {
        await ref.read(rejectedAccountLocalDataCleanerProvider)(
          account.id,
          cleanupUrl,
        );
      }
    }
    final authoritative = canonicalStored ?? account.homeserverUrl;
    if (authoritative != account.homeserverUrl) {
      final reconciled = account.copyWith(homeserverUrl: authoritative);
      accounts[index] = reconciled;
      accountsById[account.id] = reconciled;
      metadataChanged = true;
    }
    if (!await prefs.setString(homeserverKey, authoritative)) {
      throw StateError('Could not sanitize Matrix homeserver metadata.');
    }
  }

  String accountIdFromKey(String key, String suffix) =>
      key.substring('manymatrix.'.length, key.length - suffix.length);

  for (final key in originalPreferenceKeys.where(
    (key) => key.startsWith('manymatrix.') && key.endsWith('.homeserver'),
  )) {
    final id = accountIdFromKey(key, '.homeserver');
    if (accountsById.containsKey(id)) continue;
    final storedHomeserver = prefs.getString(key);
    final cleanupUrl = storedHomeserver == null
        ? null
        : homeserverUrlForCleanup(storedHomeserver);
    if (cleanupUrl == null) {
      final sessionKey = 'manymatrix.$id.session';
      if (prefs.containsKey(key) && !await prefs.remove(key)) {
        throw StateError('Could not scrub orphaned Matrix account metadata.');
      }
      if (prefs.containsKey(sessionKey) && !await prefs.remove(sessionKey)) {
        throw StateError('Could not scrub an orphaned Matrix session.');
      }
      continue;
    }
    await ref.read(rejectedAccountLocalDataCleanerProvider)(id, cleanupUrl);
  }
  for (final key in originalPreferenceKeys.where(
    (key) => key.startsWith('manymatrix.') && key.endsWith('.session'),
  )) {
    final id = accountIdFromKey(key, '.session');
    if (accountsById.containsKey(id)) continue;
    if (!prefs.containsKey(key)) continue;
    if (!await prefs.remove(key)) {
      throw StateError('Could not remove an orphaned Matrix session.');
    }
  }

  final activeId = prefs.getString(_prefsActiveIdKey);
  final activeIsValid = accounts.any((a) => a.id == activeId);
  final selectedActiveId = activeIsValid
      ? activeId
      : (accounts.isNotEmpty ? accounts.first.id : null);
  if (selectedActiveId != activeId) metadataChanged = true;
  await scrubLegacyBrowserSessions(
    preferences: prefs,
    activeId: selectedActiveId,
    browserOwnsSessionPersistence: matrixBridgeOwnsSessionPersistence,
  );
  if (metadataChanged) {
    await ref
        .read(accountsMetadataRepositoryProvider)
        .save(accounts, selectedActiveId);
  }
  ref.read(accountsProvider.notifier).state = accounts;
  ref.read(activeAccountIdProvider.notifier).state = selectedActiveId;
});

/// Deletes account-scoped secrets and SDK state before metadata is removed.
final accountLocalDataCleanerProvider =
    Provider<Future<void> Function(SavedAccount)>((ref) {
      return (account) async {
        if (!account.localCleanupRequired) {
          await BridgeMatrixService.clearAccountLocalData(
            accountId: account.id,
            homeserverUrl: account.homeserverUrl,
          );
          return;
        }
        final prefs = await SharedPreferences.getInstance();
        for (final key in <String>[
          'manymatrix.${account.id}.homeserver',
          'manymatrix.${account.id}.session',
        ]) {
          if (prefs.containsKey(key) && !await prefs.remove(key)) {
            throw StateError('Could not purge invalid Matrix account data.');
          }
        }
      };
    });

/// Mutations over the saved-accounts list: add/switch/forget/update.
class AccountsController {
  AccountsController(this._ref);

  final Ref _ref;
  Future<void> _mutationTail = Future<void>.value();

  Future<void> _mutate(Future<void> Function() mutation) {
    final previous = _mutationTail;
    final operation = () async {
      try {
        await previous;
      } on Object {
        // Failed persistence must not block a later retry.
      }
      await mutation();
    }();
    _mutationTail = operation.then<void>((_) {}, onError: (_, __) {});
    return operation;
  }

  Future<void> _persistAndPublish(
    List<SavedAccount> accounts,
    String? activeId,
  ) async {
    await _ref
        .read(accountsMetadataRepositoryProvider)
        .save(accounts, activeId);
    _ref.read(accountsProvider.notifier).state = accounts;
    _ref.read(activeAccountIdProvider.notifier).state = activeId;
  }

  /// Adds a saved account durably, then switches to it.
  Future<void> add(SavedAccount account) => _mutate(() async {
    final next = <SavedAccount>[..._ref.read(accountsProvider), account];
    await _persistAndPublish(next, account.id);
  });

  /// Switches the active account to [id]. No-op if [id] isn't saved.
  Future<void> switchTo(String id) => _mutate(() async {
    final accounts = _ref.read(accountsProvider);
    if (!accounts.any((account) => account.id == id)) return;
    await _persistAndPublish(accounts, id);
  });

  /// Removes the saved account with [id]. If it was active, switches to the
  /// first remaining account (or clears the active id if none are left).
  Future<void> forget(String id) => _mutate(() async {
    final account = _ref
        .read(accountsProvider)
        .where((candidate) => candidate.id == id)
        .firstOrNull;
    if (account == null) return;
    await _ref.read(accountLocalDataCleanerProvider)(account);
    final remaining = _ref
        .read(accountsProvider)
        .where((candidate) => candidate.id != id)
        .toList();
    final currentActiveId = _ref.read(activeAccountIdProvider);
    final nextActiveId = currentActiveId == id
        ? (remaining.isNotEmpty ? remaining.first.id : null)
        : currentActiveId;
    await _persistAndPublish(remaining, nextActiveId);
  });

  /// Replaces the saved account matching `updated.id` in place (e.g. once
  /// `whoami()` resolves the real user id after login).
  Future<void> update(SavedAccount updated) => _mutate(() async {
    final next = <SavedAccount>[
      for (final account in _ref.read(accountsProvider))
        if (account.id == updated.id) updated else account,
    ];
    await _persistAndPublish(next, _ref.read(activeAccountIdProvider));
  });
}

final accountsControllerProvider = Provider<AccountsController>((ref) {
  return AccountsController(ref);
});

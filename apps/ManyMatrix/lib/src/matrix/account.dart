import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  });

  /// Stable identifier, generated once when the account is added. Also used
  /// to scope the account's on-disk store path (see [defaultStorePath]).
  final String id;

  /// User-facing name shown in the switcher (e.g. "Work").
  final String label;

  final String homeserverUrl;

  /// The Matrix user ID once known (set after a successful login/restore).
  final String? userId;

  SavedAccount copyWith({String? label, String? homeserverUrl, String? userId}) {
    return SavedAccount(
      id: id,
      label: label ?? this.label,
      homeserverUrl: homeserverUrl ?? this.homeserverUrl,
      userId: userId ?? this.userId,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'label': label,
        'homeserverUrl': homeserverUrl,
        'userId': userId,
      };

  factory SavedAccount.fromJson(Map<String, Object?> json) {
    return SavedAccount(
      id: json['id']! as String,
      label: json['label']! as String,
      homeserverUrl: json['homeserverUrl']! as String,
      userId: json['userId'] as String?,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SavedAccount &&
        other.id == id &&
        other.label == label &&
        other.homeserverUrl == homeserverUrl &&
        other.userId == userId;
  }

  @override
  int get hashCode => Object.hash(id, label, homeserverUrl, userId);
}

/// All saved accounts, in add order. Empty until [accountsLoaderProvider]
/// restores any previously-persisted accounts (unlike ManyTier's
/// connections, there is no built-in default: an empty list means "show
/// the login page").
final accountsProvider =
    StateProvider<List<SavedAccount>>((ref) => const <SavedAccount>[]);

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

/// Loads previously persisted accounts, if any, and seeds
/// [accountsProvider]/[activeAccountIdProvider] exactly once. `app.dart`
/// reads this via `ref.watch` so the load kicks off at startup; the
/// `AsyncValue` itself is discarded, only the one-time side effect of
/// updating the providers above matters.
final accountsLoaderProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_prefsAccountsKey);
  var accounts = <SavedAccount>[];
  if (raw != null) {
    try {
      final decoded = jsonDecode(raw) as List<Object?>;
      accounts = decoded
          .map((e) => SavedAccount.fromJson(e! as Map<String, Object?>))
          .toList();
    } catch (_) {
      // Corrupt prefs value (e.g. from a future format): start with no
      // saved accounts rather than crashing at startup.
      accounts = <SavedAccount>[];
    }
  }
  ref.read(accountsProvider.notifier).state = accounts;
  final activeId = prefs.getString(_prefsActiveIdKey);
  final activeIsValid = accounts.any((a) => a.id == activeId);
  ref.read(activeAccountIdProvider.notifier).state =
      activeIsValid ? activeId : (accounts.isNotEmpty ? accounts.first.id : null);
});

/// Persists the account list and active id on every change.
final accountsPersistenceProvider = Provider<void>((ref) {
  ref.listen<List<SavedAccount>>(accountsProvider, (previous, next) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsAccountsKey,
      jsonEncode(next.map((a) => a.toJson()).toList()),
    );
  }, fireImmediately: false);
  ref.listen<String?>(activeAccountIdProvider, (previous, next) async {
    final prefs = await SharedPreferences.getInstance();
    if (next == null) {
      await prefs.remove(_prefsActiveIdKey);
    } else {
      await prefs.setString(_prefsActiveIdKey, next);
    }
  }, fireImmediately: false);
});

/// Mutations over the saved-accounts list: add/switch/forget/update.
class AccountsController {
  AccountsController(this._ref);

  final Ref _ref;

  /// Adds a new saved account and switches to it immediately.
  void add(SavedAccount account) {
    final next = <SavedAccount>[..._ref.read(accountsProvider), account];
    _ref.read(accountsProvider.notifier).state = next;
    _ref.read(activeAccountIdProvider.notifier).state = account.id;
  }

  /// Switches the active account to [id]. No-op if [id] isn't saved.
  void switchTo(String id) {
    if (!_ref.read(accountsProvider).any((a) => a.id == id)) return;
    _ref.read(activeAccountIdProvider.notifier).state = id;
  }

  /// Removes the saved account with [id]. If it was active, switches to the
  /// first remaining account (or clears the active id if none are left).
  void forget(String id) {
    final remaining =
        _ref.read(accountsProvider).where((a) => a.id != id).toList();
    _ref.read(accountsProvider.notifier).state = remaining;
    if (_ref.read(activeAccountIdProvider) == id) {
      _ref.read(activeAccountIdProvider.notifier).state =
          remaining.isNotEmpty ? remaining.first.id : null;
    }
  }

  /// Replaces the saved account matching `updated.id` in place (e.g. once
  /// `whoami()` resolves the real user id after login).
  void update(SavedAccount updated) {
    final next = <SavedAccount>[
      for (final account in _ref.read(accountsProvider))
        if (account.id == updated.id) updated else account,
    ];
    _ref.read(accountsProvider.notifier).state = next;
  }
}

final accountsControllerProvider = Provider<AccountsController>((ref) {
  return AccountsController(ref);
});

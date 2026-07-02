import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix_app/src/matrix/account.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';

void main() {
  group('SavedAccount', () {
    test('round-trips through JSON', () {
      const account = SavedAccount(
        id: '1',
        label: '@alice:example.org',
        homeserverUrl: 'https://example.org',
        userId: '@alice:example.org',
      );
      final decoded = SavedAccount.fromJson(account.toJson());
      expect(decoded, account);
    });

    test('copyWith overrides only the given fields', () {
      const account = SavedAccount(
        id: '1',
        label: 'Work',
        homeserverUrl: 'https://example.org',
      );
      final updated = account.copyWith(userId: '@alice:example.org');
      expect(updated.id, '1');
      expect(updated.label, 'Work');
      expect(updated.homeserverUrl, 'https://example.org');
      expect(updated.userId, '@alice:example.org');
    });
  });

  group('AccountsController', () {
    test('add appends and switches to the new account', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      const b = SavedAccount(id: 'b', label: 'B', homeserverUrl: 'https://b');

      container.read(accountsControllerProvider).add(a);
      container.read(accountsControllerProvider).add(b);

      expect(container.read(accountsProvider), [a, b]);
      expect(container.read(activeAccountIdProvider), 'b');
      expect(container.read(activeAccountProvider), b);
    });

    test('switchTo changes the active account', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      const b = SavedAccount(id: 'b', label: 'B', homeserverUrl: 'https://b');
      container.read(accountsControllerProvider).add(a);
      container.read(accountsControllerProvider).add(b);

      container.read(accountsControllerProvider).switchTo('a');

      expect(container.read(activeAccountIdProvider), 'a');
      expect(container.read(activeAccountProvider), a);
    });

    test('switchTo is a no-op for an unknown id', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      container.read(accountsControllerProvider).add(a);

      container.read(accountsControllerProvider).switchTo('missing');

      expect(container.read(activeAccountIdProvider), 'a');
    });

    test('forget removes the account and falls back to another when active',
        () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      const b = SavedAccount(id: 'b', label: 'B', homeserverUrl: 'https://b');
      container.read(accountsControllerProvider).add(a);
      container.read(accountsControllerProvider).add(b);
      container.read(accountsControllerProvider).switchTo('a');

      container.read(accountsControllerProvider).forget('a');

      expect(container.read(accountsProvider), [b]);
      expect(container.read(activeAccountIdProvider), 'b');
    });

    test('forgetting the only account clears the active id', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      container.read(accountsControllerProvider).add(a);

      container.read(accountsControllerProvider).forget('a');

      expect(container.read(accountsProvider), isEmpty);
      expect(container.read(activeAccountIdProvider), isNull);
      expect(container.read(activeAccountProvider), isNull);
    });

    test('forgetting a non-active account leaves the active one alone', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      const b = SavedAccount(id: 'b', label: 'B', homeserverUrl: 'https://b');
      container.read(accountsControllerProvider).add(a);
      container.read(accountsControllerProvider).add(b);
      container.read(accountsControllerProvider).switchTo('a');

      container.read(accountsControllerProvider).forget('b');

      expect(container.read(accountsProvider), [a]);
      expect(container.read(activeAccountIdProvider), 'a');
    });

    test('update replaces the matching account in place', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      container.read(accountsControllerProvider).add(a);

      container
          .read(accountsControllerProvider)
          .update(a.copyWith(userId: '@alice:example.org'));

      expect(container.read(accountsProvider).single.userId,
          '@alice:example.org');
    });
  });

  group('matrixServiceProvider', () {
    test('rebuilds to a new instance when the active account changes', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      const b = SavedAccount(id: 'b', label: 'B', homeserverUrl: 'https://b');
      container.read(accountsControllerProvider).add(a);
      final serviceForA = container.read(matrixServiceProvider);

      container.read(accountsControllerProvider).add(b);
      final serviceForB = container.read(matrixServiceProvider);

      expect(identical(serviceForA, serviceForB), isFalse);
    });
  });
}

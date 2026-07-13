import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix_app/src/matrix/account.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ControlledAccountsRepository implements AccountsMetadataRepository {
  final saved = <(List<SavedAccount>, String?)>[];
  final firstSaveStarted = Completer<void>();
  final releaseFirstSave = Completer<void>();
  bool reject = false;

  @override
  Future<void> save(List<SavedAccount> accounts, String? activeId) async {
    saved.add((List<SavedAccount>.from(accounts), activeId));
    if (saved.length == 1 && !firstSaveStarted.isCompleted) {
      firstSaveStarted.complete();
      await releaseFirstSave.future;
    }
    if (reject) throw StateError('durable write rejected');
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

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
    test('add appends and switches to the new account', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      const b = SavedAccount(id: 'b', label: 'B', homeserverUrl: 'https://b');

      await container.read(accountsControllerProvider).add(a);
      await container.read(accountsControllerProvider).add(b);

      expect(container.read(accountsProvider), [a, b]);
      expect(container.read(activeAccountIdProvider), 'b');
      expect(container.read(activeAccountProvider), b);
    });

    test('switchTo changes the active account', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      const b = SavedAccount(id: 'b', label: 'B', homeserverUrl: 'https://b');
      await container.read(accountsControllerProvider).add(a);
      await container.read(accountsControllerProvider).add(b);

      await container.read(accountsControllerProvider).switchTo('a');

      expect(container.read(activeAccountIdProvider), 'a');
      expect(container.read(activeAccountProvider), a);
    });

    test('switchTo is a no-op for an unknown id', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      await container.read(accountsControllerProvider).add(a);

      await container.read(accountsControllerProvider).switchTo('missing');

      expect(container.read(activeAccountIdProvider), 'a');
    });

    test(
      'forget removes the account and falls back to another when active',
      () async {
        final container = ProviderContainer(
          overrides: <Override>[
            accountLocalDataCleanerProvider.overrideWithValue((_) async {}),
          ],
        );
        addTearDown(container.dispose);
        const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
        const b = SavedAccount(id: 'b', label: 'B', homeserverUrl: 'https://b');
        await container.read(accountsControllerProvider).add(a);
        await container.read(accountsControllerProvider).add(b);
        await container.read(accountsControllerProvider).switchTo('a');

        await container.read(accountsControllerProvider).forget('a');

        expect(container.read(accountsProvider), [b]);
        expect(container.read(activeAccountIdProvider), 'b');
      },
    );

    test('forgetting the only account clears the active id', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          accountLocalDataCleanerProvider.overrideWithValue((_) async {}),
        ],
      );
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      await container.read(accountsControllerProvider).add(a);

      await container.read(accountsControllerProvider).forget('a');

      expect(container.read(accountsProvider), isEmpty);
      expect(container.read(activeAccountIdProvider), isNull);
      expect(container.read(activeAccountProvider), isNull);
    });

    test('forgetting a non-active account cleans its local data', () async {
      final cleaned = <SavedAccount>[];
      final container = ProviderContainer(
        overrides: <Override>[
          accountLocalDataCleanerProvider.overrideWithValue((account) async {
            cleaned.add(account);
          }),
        ],
      );
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      const b = SavedAccount(id: 'b', label: 'B', homeserverUrl: 'https://b');
      await container.read(accountsControllerProvider).add(a);
      await container.read(accountsControllerProvider).add(b);
      await container.read(accountsControllerProvider).switchTo('a');

      await container.read(accountsControllerProvider).forget('b');

      expect(container.read(accountsProvider), [a]);
      expect(container.read(activeAccountIdProvider), 'a');
      expect(cleaned, <SavedAccount>[b]);
    });

    test('cleanup failure retains account metadata for a retry', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          accountLocalDataCleanerProvider.overrideWithValue((_) async {
            throw StateError('database still open');
          }),
        ],
      );
      addTearDown(container.dispose);
      const account = SavedAccount(
        id: 'a',
        label: 'A',
        homeserverUrl: 'https://a',
      );
      await container.read(accountsControllerProvider).add(account);

      await expectLater(
        container.read(accountsControllerProvider).forget(account.id),
        throwsStateError,
      );

      expect(container.read(accountsProvider), const <SavedAccount>[account]);
      expect(container.read(activeAccountIdProvider), account.id);
    });

    test('mutations serialize durable writes in invocation order', () async {
      final repository = _ControlledAccountsRepository();
      final container = ProviderContainer(
        overrides: <Override>[
          accountsMetadataRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      const b = SavedAccount(id: 'b', label: 'B', homeserverUrl: 'https://b');

      final first = container.read(accountsControllerProvider).add(a);
      await repository.firstSaveStarted.future;
      final second = container.read(accountsControllerProvider).add(b);
      await pumpEventQueue();

      expect(repository.saved, hasLength(1));
      expect(repository.saved.single.$1, <SavedAccount>[a]);
      expect(repository.saved.single.$2, 'a');
      expect(container.read(accountsProvider), isEmpty);

      repository.releaseFirstSave.complete();
      await Future.wait(<Future<void>>[first, second]);

      expect(repository.saved, hasLength(2));
      expect(repository.saved[0].$1, <SavedAccount>[a]);
      expect(repository.saved[0].$2, 'a');
      expect(repository.saved[1].$1, <SavedAccount>[a, b]);
      expect(repository.saved[1].$2, 'b');
      expect(container.read(accountsProvider), <SavedAccount>[a, b]);
      expect(container.read(activeAccountIdProvider), 'b');
    });

    test('rejected durable forget does not publish metadata removal', () async {
      final repository = _ControlledAccountsRepository()..reject = true;
      repository.releaseFirstSave.complete();
      final container = ProviderContainer(
        overrides: <Override>[
          accountsMetadataRepositoryProvider.overrideWithValue(repository),
          accountLocalDataCleanerProvider.overrideWithValue((_) async {}),
        ],
      );
      addTearDown(container.dispose);
      const account = SavedAccount(
        id: 'a',
        label: 'A',
        homeserverUrl: 'https://a',
      );
      container.read(accountsProvider.notifier).state = const <SavedAccount>[
        account,
      ];
      container.read(activeAccountIdProvider.notifier).state = account.id;

      await expectLater(
        container.read(accountsControllerProvider).forget(account.id),
        throwsStateError,
      );

      expect(container.read(accountsProvider), const <SavedAccount>[account]);
      expect(container.read(activeAccountIdProvider), account.id);
    });

    test('update replaces the matching account in place', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      await container.read(accountsControllerProvider).add(a);

      await container
          .read(accountsControllerProvider)
          .update(a.copyWith(userId: '@alice:example.org'));

      expect(
        container.read(accountsProvider).single.userId,
        '@alice:example.org',
      );
    });
  });

  test('browser startup scrubs inactive and pending legacy sessions', () async {
    const active = SavedAccount(
      id: 'active',
      label: 'Active',
      homeserverUrl: 'https://active.example',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'manymatrix.active.session': '{"access_token":"active-secret"}',
      'manymatrix.inactive.session': '{"access_token":"inactive-secret"}',
      'manymatrix._pending.session': '{"access_token":"pending-secret"}',
      'manymatrix.orphan.session': '{"access_token":"orphan-secret"}',
    });
    final preferences = await SharedPreferences.getInstance();

    await scrubLegacyBrowserSessions(
      preferences: preferences,
      activeId: active.id,
      browserOwnsSessionPersistence: true,
    );

    expect(preferences.getString('manymatrix.active.session'), isNotNull);
    expect(preferences.getString('manymatrix.inactive.session'), isNull);
    expect(preferences.getString('manymatrix._pending.session'), isNull);
    expect(preferences.getString('manymatrix.orphan.session'), isNull);
  });

  test('account loader removes unsafe legacy homeserver metadata', () async {
    const safe = SavedAccount(
      id: 'safe',
      label: 'Safe',
      homeserverUrl: 'HTTPS://Matrix.Example/base/',
    );
    const unsafe = SavedAccount(
      id: 'unsafe',
      label: 'Unsafe',
      homeserverUrl: 'https://user:pass@example.org?access_token=secret',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'manymatrix.accounts': jsonEncode(<Map<String, Object?>>[
        safe.toJson(),
        unsafe.toJson(),
      ]),
      'manymatrix.accounts.activeId': unsafe.id,
      'manymatrix.unsafe.homeserver': unsafe.homeserverUrl,
      'manymatrix.unsafe.session': '{"access_token":"secret"}',
    });
    final preferences = await SharedPreferences.getInstance();
    final cleaned = <(String, String)>[];
    final container = ProviderContainer(
      overrides: <Override>[
        rejectedAccountLocalDataCleanerProvider.overrideWithValue((
          accountId,
          homeserverUrl,
        ) async {
          cleaned.add((accountId, homeserverUrl));
          await preferences.remove('manymatrix.$accountId.homeserver');
          await preferences.remove('manymatrix.$accountId.session');
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(accountsLoaderProvider.future);

    expect(container.read(accountsProvider), <SavedAccount>[
      safe.copyWith(homeserverUrl: 'https://matrix.example/base'),
    ]);
    expect(container.read(activeAccountIdProvider), safe.id);
    expect(cleaned, <(String, String)>[(unsafe.id, 'https://example.org')]);
    expect(preferences.getString('manymatrix.unsafe.homeserver'), isNull);
    expect(preferences.getString('manymatrix.unsafe.session'), isNull);
    expect(
      preferences.getString('manymatrix.accounts'),
      isNot(contains('pass')),
    );
    expect(
      preferences.getString('manymatrix.accounts'),
      isNot(contains('secret')),
    );
  });

  test(
    'account loader keeps an unlocatable account visible for explicit cleanup',
    () async {
      const account = SavedAccount(
        id: 'broken',
        label: 'Broken account',
        homeserverUrl: 'not a homeserver at all',
        userId: '@alice:example.org',
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        'manymatrix.accounts': jsonEncode(<Map<String, Object?>>[
          account.toJson(),
        ]),
        'manymatrix.accounts.activeId': account.id,
        'manymatrix.broken.homeserver': account.homeserverUrl,
        'manymatrix.broken.session': '{"access_token":"secret"}',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(accountsLoaderProvider.future);

      final recovered = container.read(accountsProvider).single;
      expect(recovered.id, account.id);
      expect(recovered.homeserverUrl, 'https://invalid.localhost');
      expect(recovered.localCleanupRequired, isTrue);
      expect(container.read(activeAccountIdProvider), account.id);

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('manymatrix.broken.session'), isNull);
      expect(
        preferences.getString('manymatrix.accounts'),
        isNot(contains('not a homeserver')),
      );
      expect(
        preferences.getString('manymatrix.accounts'),
        contains('localCleanupRequired'),
      );
    },
  );

  test('account loader reconciles restore and metadata homeservers', () async {
    const account = SavedAccount(
      id: 'saved',
      label: 'Saved',
      homeserverUrl: 'https://metadata.example',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'manymatrix.accounts': jsonEncode(<Map<String, Object?>>[
        account.toJson(),
      ]),
      'manymatrix.accounts.activeId': account.id,
      'manymatrix.saved.homeserver': 'HTTPS://Session.Example/base/',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(accountsLoaderProvider.future);

    expect(
      container.read(accountsProvider).single.homeserverUrl,
      'https://session.example/base',
    );
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('manymatrix.saved.homeserver'),
      'https://session.example/base',
    );
    expect(
      preferences.getString('manymatrix.accounts'),
      contains('https://session.example/base'),
    );
  });

  test('account loader cleans an unsafe per-account restore URL', () async {
    const account = SavedAccount(
      id: 'saved',
      label: 'Saved',
      homeserverUrl: 'https://metadata.example',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'manymatrix.accounts': jsonEncode(<Map<String, Object?>>[
        account.toJson(),
      ]),
      'manymatrix.accounts.activeId': account.id,
      'manymatrix.saved.homeserver':
          'https://user:secret@old.example?access_token=secret',
      'manymatrix.saved.session': '{"access_token":"secret"}',
    });
    final preferences = await SharedPreferences.getInstance();
    final cleaned = <(String, String)>[];
    final container = ProviderContainer(
      overrides: <Override>[
        rejectedAccountLocalDataCleanerProvider.overrideWithValue((
          accountId,
          homeserverUrl,
        ) async {
          cleaned.add((accountId, homeserverUrl));
          await preferences.remove('manymatrix.$accountId.homeserver');
          await preferences.remove('manymatrix.$accountId.session');
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(accountsLoaderProvider.future);

    expect(cleaned, <(String, String)>[('saved', 'https://old.example')]);
    expect(
      preferences.getString('manymatrix.saved.homeserver'),
      account.homeserverUrl,
    );
    expect(preferences.getString('manymatrix.saved.session'), isNull);
    expect(container.read(accountsProvider), <SavedAccount>[account]);
  });

  test(
    'corrupt account metadata is durably replaced after orphan cleanup',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'manymatrix.accounts': '{not-json',
        'manymatrix.accounts.activeId': 'orphan',
        'manymatrix.orphan.homeserver': 'https://orphan.example',
        'manymatrix.orphan.session': '{"access_token":"secret"}',
      });
      final preferences = await SharedPreferences.getInstance();
      final cleaned = <(String, String)>[];
      final container = ProviderContainer(
        overrides: <Override>[
          rejectedAccountLocalDataCleanerProvider.overrideWithValue((
            accountId,
            homeserverUrl,
          ) async {
            cleaned.add((accountId, homeserverUrl));
            await preferences.remove('manymatrix.$accountId.homeserver');
            await preferences.remove('manymatrix.$accountId.session');
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(accountsLoaderProvider.future);

      expect(cleaned, <(String, String)>[('orphan', 'https://orphan.example')]);
      expect(preferences.getString('manymatrix.accounts'), '[]');
      expect(preferences.getString('manymatrix.accounts.activeId'), isNull);
      expect(preferences.getString('manymatrix.orphan.session'), isNull);
    },
  );

  test(
    'corrupt metadata scrubs an unlocatable orphan session without crashing',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'manymatrix.accounts': '{not-json',
        'manymatrix.accounts.activeId': 'orphan',
        'manymatrix.orphan.homeserver': 'not a homeserver',
        'manymatrix.orphan.session': '{"access_token":"secret"}',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(accountsLoaderProvider.future);

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('manymatrix.accounts'), '[]');
      expect(preferences.getString('manymatrix.accounts.activeId'), isNull);
      expect(preferences.getString('manymatrix.orphan.homeserver'), isNull);
      expect(preferences.getString('manymatrix.orphan.session'), isNull);
      expect(container.read(accountsProvider), isEmpty);
    },
  );

  group('matrixServiceProvider', () {
    test(
      'rebuilds to a new instance when the active account changes',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
        const b = SavedAccount(id: 'b', label: 'B', homeserverUrl: 'https://b');
        await container.read(accountsControllerProvider).add(a);
        final serviceForA = container.read(matrixServiceProvider);

        await container.read(accountsControllerProvider).add(b);
        final serviceForB = container.read(matrixServiceProvider);

        expect(identical(serviceForA, serviceForB), isFalse);
      },
    );

    test('selected room is scoped to the active account', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const a = SavedAccount(id: 'a', label: 'A', homeserverUrl: 'https://a');
      const b = SavedAccount(id: 'b', label: 'B', homeserverUrl: 'https://b');
      await container.read(accountsControllerProvider).add(a);
      container.read(selectedRoomIdProvider.notifier).state = '!room:a';

      await container.read(accountsControllerProvider).add(b);

      expect(container.read(activeAccountIdProvider), 'b');
      expect(container.read(selectedRoomIdProvider), isNull);
    });
  });
}

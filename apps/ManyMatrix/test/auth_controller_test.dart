import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:manymatrix/manymatrix.dart';
import 'package:manymatrix_app/src/matrix/account.dart';
import 'package:manymatrix_app/src/matrix/auth.dart';
import 'package:manymatrix_app/src/matrix/bridge_service.dart';
import 'package:manymatrix_app/src/matrix/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingMatrixService
    implements
        MatrixService,
        SuspendableMatrixService,
        ReauthenticatingMatrixService {
  _RecordingMatrixService({
    this.restoreUserId,
    this.loginUserId,
    this.restoreError,
    this.loginError,
    this.logoutError,
    this.restoreCompleter,
    this.suspendCompleter,
    this.deviceId,
  });

  final String? restoreUserId;
  final String? loginUserId;
  final Object? restoreError;
  final Object? loginError;
  final Object? logoutError;
  final Completer<String?>? restoreCompleter;
  final Completer<void>? suspendCompleter;
  final String? deviceId;

  int restoreCalls = 0;
  int loginCalls = 0;
  int logoutCalls = 0;
  int suspendCalls = 0;
  int reauthenticateCalls = 0;
  String? reauthenticatedDeviceId;
  String? lastHomeserverUrl;
  String? lastUsername;
  String? lastPassword;
  final _sessionProblems = StreamController<SessionProblem>.broadcast();

  @override
  Stream<MessageEvent> get messageEvents => const Stream<MessageEvent>.empty();

  @override
  Stream<ReactionEvent> get reactionEvents =>
      const Stream<ReactionEvent>.empty();

  @override
  Stream<ReceiptEvent> get receiptEvents => const Stream<ReceiptEvent>.empty();

  @override
  Stream<SessionProblem> get sessionProblems => _sessionProblems.stream;

  void emitSessionProblem(SessionProblem problem) {
    _sessionProblems.add(problem);
  }

  @override
  String? get currentUserId => restoreUserId ?? loginUserId;

  @override
  String? get currentDeviceId => deviceId;

  @override
  Future<String?> restoreSession() async {
    restoreCalls += 1;
    final error = restoreError;
    if (error != null) throw error;
    final delayed = restoreCompleter;
    if (delayed != null) return delayed.future;
    return restoreUserId;
  }

  @override
  Future<String> login({
    required String homeserverUrl,
    required String username,
    required String password,
  }) async {
    loginCalls += 1;
    lastHomeserverUrl = homeserverUrl;
    lastUsername = username;
    lastPassword = password;
    final error = loginError;
    if (error != null) throw error;
    return loginUserId ?? '@$username:example.org';
  }

  @override
  Future<void> clearSavedSession({bool keepHomeserver = true}) async {}

  @override
  Future<void> logout() async {
    logoutCalls += 1;
    final error = logoutError;
    if (error != null) throw error;
  }

  @override
  Future<void> suspend() async {
    suspendCalls += 1;
    await suspendCompleter?.future;
  }

  @override
  Future<String> reauthenticate({
    required String homeserverUrl,
    required String username,
    required String password,
    required String deviceId,
  }) async {
    reauthenticateCalls += 1;
    reauthenticatedDeviceId = deviceId;
    return login(
      homeserverUrl: homeserverUrl,
      username: username,
      password: password,
    );
  }

  @override
  void dispose() {
    _sessionProblems.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object> _savedAccountPrefs(SavedAccount account) {
  return <String, Object>{
    'manymatrix.accounts': jsonEncode(<Map<String, Object?>>[account.toJson()]),
    'manymatrix.accounts.activeId': account.id,
  };
}

Map<String, Object> _savedAccountsPrefs(
  List<SavedAccount> accounts,
  String activeId,
) {
  return <String, Object>{
    'manymatrix.accounts': jsonEncode(
      accounts.map((account) => account.toJson()).toList(),
    ),
    'manymatrix.accounts.activeId': activeId,
  };
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'restore skips stale pending service when no account is active',
    () async {
      final service = _RecordingMatrixService(
        restoreUserId: '@stale:example.org',
      );
      final container = ProviderContainer(
        overrides: <Override>[matrixServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      expect(container.read(authControllerProvider), isA<AuthRestoring>());
      await pumpEventQueue();

      expect(
        container.read(authControllerProvider),
        isA<AuthUnauthenticated>(),
      );
      expect(service.restoreCalls, 0);
    },
  );

  test('session write guard rejects a callback delayed past close', () async {
    final guard = SessionWriteGuard();
    final generation = guard.open();
    final release = Completer<void>();
    var persisted = false;
    final delayedWrite = () async {
      await release.future;
      if (guard.accepts(generation)) persisted = true;
    }();

    guard.close();
    release.complete();
    await delayedWrite;

    expect(persisted, isFalse);
  });

  test('session write finishing after close removes the late secret', () async {
    final guard = SessionWriteGuard();
    final generation = guard.open();
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    String? persisted;

    final writing = writeSessionIfCurrent(
      guard: guard,
      generation: generation,
      write: () async {
        writeStarted.complete();
        await releaseWrite.future;
        persisted = '{"access_token":"late"}';
      },
      remove: () async {
        persisted = null;
      },
    );
    await writeStarted.future;
    guard.close();
    releaseWrite.complete();
    await writing;

    expect(persisted, isNull);
  });

  test('old session cleanup cannot delete a queued new generation', () async {
    final guard = SessionWriteGuard();
    final queue = SessionPersistenceQueue();
    final oldGeneration = guard.open();
    final oldWriteStarted = Completer<void>();
    final releaseOldWrite = Completer<void>();
    String? persisted;

    final oldWrite = queue.run(
      () => writeSessionIfCurrent(
        guard: guard,
        generation: oldGeneration,
        write: () async {
          oldWriteStarted.complete();
          await releaseOldWrite.future;
          persisted = 'old';
        },
        remove: () async {
          persisted = null;
        },
      ),
    );
    await oldWriteStarted.future;
    guard.close();
    final newGeneration = guard.open();
    final newWrite = queue.run(
      () => writeSessionIfCurrent(
        guard: guard,
        generation: newGeneration,
        write: () async {
          persisted = 'new';
        },
        remove: () async {
          persisted = null;
        },
      ),
    );

    releaseOldWrite.complete();
    await Future.wait(<Future<void>>[oldWrite, newWrite]);

    expect(persisted, 'new');
  });

  test('persisted sessions must match the selected homeserver', () {
    final session = jsonEncode(<String, Object?>{
      'homeserver': 'HTTPS://Matrix.Example/',
      'access_token': 'secret',
    });

    expect(
      () =>
          validatePersistedSessionHomeserver(session, 'https://matrix.example'),
      returnsNormally,
    );
    expect(
      () =>
          validatePersistedSessionHomeserver(session, 'https://other.example'),
      throwsA(isA<InvalidPersistedMatrixSession>()),
    );
    expect(
      () => validatePersistedSessionHomeserver(
        '{not-json',
        'https://matrix.example',
      ),
      throwsA(isA<InvalidPersistedMatrixSession>()),
    );
  });

  test(
    'session revocation drains the live bridge before static cleanup',
    () async {
      final liveStarted = Completer<void>();
      final releaseLive = Completer<void>();
      final order = <String>[];

      final clearing = clearPersistedSessionRevocationAware(
        clearLiveSession: () async {
          order.add('live-start');
          liveStarted.complete();
          await releaseLive.future;
          order.add('live-finish');
        },
        clearStoredSession: () async {
          order.add('static');
        },
      );
      await liveStarted.future;
      expect(order, <String>['live-start']);

      releaseLive.complete();
      await clearing;

      expect(order, <String>['live-start', 'live-finish', 'static']);
    },
  );

  test(
    'post-auth startup failure revokes the remote session before cleanup',
    () async {
      final order = <String>[];

      await cleanupFailedLoginClient(
        authenticated: true,
        revokeRemoteSession: () async {
          order.add('logout');
          throw StateError('remote logout failed');
        },
        closeClient: () async {
          order.add('close');
        },
        clearClientSession: () async {
          order.add('clear-client');
        },
        clearAccountSession: () async {
          order.add('clear-account');
        },
      );

      expect(order, <String>[
        'logout',
        'close',
        'clear-client',
        'clear-account',
      ]);
    },
  );

  test('bridge replacement waits for the previous client to close', () async {
    final slot = BridgeClientSlot<String>()..current = 'old-worker';
    final releaseClose = Completer<void>();
    final closed = <String>[];

    final replace = () async {
      await slot.drain((client) async {
        closed.add(client);
        await releaseClose.future;
      });
      slot.current = 'new-worker';
    }();
    await pumpEventQueue();

    expect(closed, <String>['old-worker']);
    expect(slot.current, isNull);

    releaseClose.complete();
    await replace;
    expect(slot.current, 'new-worker');
  });

  test('failed remote logout still cleans and forgets the account', () async {
    const account = SavedAccount(
      id: 'saved',
      label: '@alice:example.org',
      homeserverUrl: 'https://example.org',
      userId: '@alice:example.org',
    );
    final service = _RecordingMatrixService(
      restoreUserId: account.userId,
      logoutError: Exception('remote logout failed'),
    );
    final cleaned = <SavedAccount>[];
    SharedPreferences.setMockInitialValues(_savedAccountPrefs(account));
    final container = ProviderContainer(
      overrides: <Override>[
        matrixServiceProvider.overrideWithValue(service),
        accountLocalDataCleanerProvider.overrideWithValue((value) async {
          cleaned.add(value);
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(authControllerProvider);
    await pumpEventQueue();

    await container.read(authControllerProvider.notifier).signOut();

    expect(service.logoutCalls, 1);
    expect(cleaned, <SavedAccount>[account]);
    expect(container.read(accountsProvider), isEmpty);
    expect(container.read(activeAccountIdProvider), isNull);
    expect(container.read(authControllerProvider), isA<AuthUnauthenticated>());
  });

  test(
    'failed local cleanup signs out visibly and retains a retryable account',
    () async {
      const account = SavedAccount(
        id: 'saved',
        label: '@alice:example.org',
        homeserverUrl: 'https://example.org',
        userId: '@alice:example.org',
      );
      final service = _RecordingMatrixService(restoreUserId: account.userId);
      SharedPreferences.setMockInitialValues(_savedAccountPrefs(account));
      final container = ProviderContainer(
        overrides: <Override>[
          matrixServiceProvider.overrideWithValue(service),
          accountLocalDataCleanerProvider.overrideWithValue((_) async {
            throw StateError('IndexedDB is blocked by another tab');
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(authControllerProvider);
      await pumpEventQueue();

      await container.read(authControllerProvider.notifier).signOut();

      final auth = container.read(authControllerProvider);
      expect(auth, isA<AuthUnauthenticated>());
      expect(
        (auth as AuthUnauthenticated).error,
        contains('Accounts > Forget to retry'),
      );
      expect(container.read(accountsProvider), const <SavedAccount>[account]);
      expect(container.read(activeAccountIdProvider), account.id);
    },
  );

  test('sign-in scopes the native service to the saved account id', () async {
    final services = <String, _RecordingMatrixService>{};
    final container = ProviderContainer(
      overrides: <Override>[
        matrixServiceProvider.overrideWith((ref) {
          final activeId = ref.watch(activeAccountIdProvider) ?? 'pending';
          return services.putIfAbsent(
            activeId,
            () => _RecordingMatrixService(loginUserId: '@alice:example.org'),
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(authControllerProvider), isA<AuthRestoring>());
    await pumpEventQueue();
    expect(container.read(authControllerProvider), isA<AuthUnauthenticated>());

    await container
        .read(authControllerProvider.notifier)
        .signIn(
          homeserverUrl: 'https://example.org',
          username: 'alice',
          password: 'secret',
        );

    final account = container.read(accountsProvider).single;
    expect(container.read(activeAccountIdProvider), account.id);
    expect(account.userId, '@alice:example.org');
    expect(account.label, '@alice:example.org');
    expect(services['pending']?.loginCalls ?? 0, 0);
    expect(services[account.id]?.loginCalls, 1);
    expect(services[account.id]?.lastHomeserverUrl, 'https://example.org');
  });

  test('account switches serialize behind an in-flight restore', () async {
    const accountA = SavedAccount(
      id: 'a',
      label: '@alice:example.org',
      homeserverUrl: 'https://a.example.org',
      userId: '@alice:example.org',
    );
    const accountB = SavedAccount(
      id: 'b',
      label: '@bob:example.org',
      homeserverUrl: 'https://b.example.org',
      userId: '@bob:example.org',
    );
    final restoreA = Completer<String?>();
    final serviceA = _RecordingMatrixService(
      restoreUserId: accountA.userId,
      restoreCompleter: restoreA,
    );
    final serviceB = _RecordingMatrixService(restoreUserId: accountB.userId);
    SharedPreferences.setMockInitialValues(
      _savedAccountsPrefs(const <SavedAccount>[
        accountA,
        accountB,
      ], accountA.id),
    );
    final container = ProviderContainer(
      overrides: <Override>[
        matrixServiceProvider.overrideWith((ref) {
          return ref.watch(activeAccountIdProvider) == accountB.id
              ? serviceB
              : serviceA;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(authControllerProvider);
    await pumpEventQueue();
    expect(serviceA.restoreCalls, 1);

    final switching = container
        .read(authControllerProvider.notifier)
        .switchAccount(accountB.id);
    expect(container.read(activeAccountIdProvider), accountA.id);

    restoreA.complete(accountA.userId);
    await switching;

    expect(container.read(activeAccountIdProvider), accountB.id);
    expect(serviceB.restoreCalls, 1);
    expect(
      container.read(authControllerProvider),
      isA<AuthAuthenticated>().having(
        (auth) => auth.userId,
        'userId',
        accountB.userId,
      ),
    );
  });

  test('account switch publishes only after the old service closes', () async {
    const accountA = SavedAccount(
      id: 'a',
      label: 'A',
      homeserverUrl: 'https://a.example.org',
      userId: '@a:a.example.org',
    );
    const accountB = SavedAccount(
      id: 'b',
      label: 'B',
      homeserverUrl: 'https://b.example.org',
      userId: '@b:b.example.org',
    );
    final oldClosed = Completer<void>();
    final serviceA = _RecordingMatrixService(
      restoreUserId: accountA.userId,
      suspendCompleter: oldClosed,
    );
    final serviceB = _RecordingMatrixService(restoreUserId: accountB.userId);
    SharedPreferences.setMockInitialValues(
      _savedAccountsPrefs(const <SavedAccount>[
        accountA,
        accountB,
      ], accountA.id),
    );
    final container = ProviderContainer(
      overrides: <Override>[
        matrixServiceProvider.overrideWith((ref) {
          return ref.watch(activeAccountIdProvider) == accountB.id
              ? serviceB
              : serviceA;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(authControllerProvider);
    await pumpEventQueue();

    final switching = container
        .read(authControllerProvider.notifier)
        .switchAccount(accountB.id);
    await pumpEventQueue();

    expect(serviceA.suspendCalls, 1);
    expect(container.read(activeAccountIdProvider), accountA.id);
    expect(serviceB.restoreCalls, 0);

    oldClosed.complete();
    await switching;

    expect(container.read(activeAccountIdProvider), accountB.id);
    expect(serviceB.restoreCalls, 1);
  });

  test('failed secondary sign-in restores the authenticated account', () async {
    const account = SavedAccount(
      id: 'saved',
      label: '@alice:example.org',
      homeserverUrl: 'https://example.org',
      userId: '@alice:example.org',
    );
    SharedPreferences.setMockInitialValues(_savedAccountPrefs(account));
    final services = <String, _RecordingMatrixService>{};
    final container = ProviderContainer(
      overrides: <Override>[
        matrixServiceProvider.overrideWith((ref) {
          final activeId = ref.watch(activeAccountIdProvider) ?? 'pending';
          return services.putIfAbsent(
            activeId,
            () => activeId == account.id
                ? _RecordingMatrixService(restoreUserId: '@alice:example.org')
                : _RecordingMatrixService(loginError: Exception('M_FORBIDDEN')),
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(authControllerProvider), isA<AuthRestoring>());
    await pumpEventQueue();
    expect(container.read(authControllerProvider), isA<AuthAuthenticated>());

    final error = await container
        .read(authControllerProvider.notifier)
        .signIn(
          homeserverUrl: 'https://other.example.org',
          username: 'bob',
          password: 'wrong',
          restorePreviousAccountOnFailure: true,
        );

    expect(error, 'Incorrect username or password.');
    expect(container.read(accountsProvider), const <SavedAccount>[account]);
    expect(container.read(activeAccountIdProvider), account.id);
    expect(
      container.read(authControllerProvider),
      isA<AuthAuthenticated>().having(
        (auth) => auth.userId,
        'userId',
        '@alice:example.org',
      ),
    );
    expect(services[account.id]!.restoreCalls, 2);
    expect(
      services.values.where((service) => service.loginCalls == 1),
      hasLength(1),
    );
  });

  test(
    'invalid restored token asks for sign-in again without forgetting account',
    () async {
      const account = SavedAccount(
        id: 'saved',
        label: '@alice:example.org',
        homeserverUrl: 'https://example.org',
        userId: '@alice:example.org',
      );
      final service = _RecordingMatrixService(
        restoreError: ManyMatrixSdkException(
          'M_UNKNOWN_TOKEN: invalid refresh token',
          details: const {'errcode': 'M_UNKNOWN_TOKEN'},
        ),
      );
      SharedPreferences.setMockInitialValues(_savedAccountPrefs(account));
      final container = ProviderContainer(
        overrides: <Override>[matrixServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      expect(container.read(authControllerProvider), isA<AuthRestoring>());
      await pumpEventQueue();

      final auth = container.read(authControllerProvider);
      expect(auth, isA<AuthNeedsReauth>());
      expect((auth as AuthNeedsReauth).accountId, 'saved');
      expect(container.read(accountsProvider), const <SavedAccount>[account]);
    },
  );

  test(
    'non-auth restore failure offers reconnect for the saved account',
    () async {
      const account = SavedAccount(
        id: 'saved',
        label: '@alice:example.org',
        homeserverUrl: 'https://example.org',
        userId: '@alice:example.org',
      );
      final service = _RecordingMatrixService(
        restoreError: Exception('connection refused'),
      );
      SharedPreferences.setMockInitialValues(_savedAccountPrefs(account));
      final container = ProviderContainer(
        overrides: <Override>[matrixServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      expect(container.read(authControllerProvider), isA<AuthRestoring>());
      await pumpEventQueue();

      final auth = container.read(authControllerProvider);
      expect(auth, isA<AuthNeedsReconnect>());
      expect((auth as AuthNeedsReconnect).accountId, 'saved');
    },
  );

  test(
    'background invalid-token problem moves authenticated account to reauth',
    () async {
      const account = SavedAccount(
        id: 'saved',
        label: '@alice:example.org',
        homeserverUrl: 'https://example.org',
        userId: '@alice:example.org',
      );
      final service = _RecordingMatrixService(
        restoreUserId: '@alice:example.org',
      );
      SharedPreferences.setMockInitialValues(_savedAccountPrefs(account));
      final container = ProviderContainer(
        overrides: <Override>[matrixServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      expect(container.read(authControllerProvider), isA<AuthRestoring>());
      await pumpEventQueue();
      expect(container.read(authControllerProvider), isA<AuthAuthenticated>());

      service.emitSessionProblem(
        SessionProblem(
          message: 'Your Matrix session expired. Sign in again.',
          requiresReauth: true,
          error: ManyMatrixSdkException(
            'M_UNKNOWN_TOKEN',
            details: const {'errcode': 'M_UNKNOWN_TOKEN'},
          ),
        ),
      );
      await pumpEventQueue();

      final auth = container.read(authControllerProvider);
      expect(auth, isA<AuthNeedsReauth>());
      expect((auth as AuthNeedsReauth).accountId, 'saved');
    },
  );

  test('password reauth reuses the saved Matrix device id', () async {
    const account = SavedAccount(
      id: 'saved',
      label: '@alice:example.org',
      homeserverUrl: 'https://example.org',
      userId: '@alice:example.org',
      deviceId: 'ALICEDEVICE',
    );
    final service = _RecordingMatrixService(
      loginUserId: account.userId,
      deviceId: account.deviceId,
    );
    SharedPreferences.setMockInitialValues(_savedAccountPrefs(account));
    final container = ProviderContainer(
      overrides: <Override>[matrixServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    container.read(authControllerProvider);
    await pumpEventQueue();

    await container
        .read(authControllerProvider.notifier)
        .reauthenticateActive(username: 'alice', password: 'correct');

    expect(service.reauthenticateCalls, 1);
    expect(service.reauthenticatedDeviceId, account.deviceId);
    expect(container.read(authControllerProvider), isA<AuthAuthenticated>());
  });

  test(
    'restore rejects a session belonging to a different saved user',
    () async {
      const account = SavedAccount(
        id: 'saved',
        label: '@alice:example.org',
        homeserverUrl: 'https://example.org',
        userId: '@alice:example.org',
      );
      final service = _RecordingMatrixService(
        restoreUserId: '@bob:example.org',
      );
      SharedPreferences.setMockInitialValues(_savedAccountPrefs(account));
      final container = ProviderContainer(
        overrides: <Override>[matrixServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      container.read(authControllerProvider);
      await pumpEventQueue();

      final state = container.read(authControllerProvider);
      expect(service.logoutCalls, 1);
      expect(state, isA<AuthNeedsReauth>());
      expect((state as AuthNeedsReauth).message, contains('@bob:example.org'));
      expect(state.message, contains('@alice:example.org'));
      expect(container.read(accountsProvider).single, account);
    },
  );

  test('password reauth rejects credentials for a different user', () async {
    const account = SavedAccount(
      id: 'saved',
      label: '@alice:example.org',
      homeserverUrl: 'https://example.org',
      userId: '@alice:example.org',
      deviceId: 'ALICEDEVICE',
    );
    final service = _RecordingMatrixService(
      loginUserId: '@bob:example.org',
      deviceId: account.deviceId,
    );
    SharedPreferences.setMockInitialValues(_savedAccountPrefs(account));
    final container = ProviderContainer(
      overrides: <Override>[matrixServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    container.read(authControllerProvider);
    await pumpEventQueue();

    await container
        .read(authControllerProvider.notifier)
        .reauthenticateActive(username: 'bob', password: 'correct');

    expect(service.logoutCalls, 1);
    expect(container.read(authControllerProvider), isA<AuthNeedsReauth>());
    expect(container.read(accountsProvider).single.userId, account.userId);
  });

  test(
    'an active web store reports the other tab as the recovery action',
    () async {
      const account = SavedAccount(
        id: 'saved',
        label: '@alice:example.org',
        homeserverUrl: 'https://example.org',
        userId: '@alice:example.org',
      );
      final service = _RecordingMatrixService(
        restoreError: ManyMatrixStorageException(
          'store is active',
          details: const <String, dynamic>{
            'reason': 'store_active_in_another_tab',
          },
        ),
      );
      SharedPreferences.setMockInitialValues(_savedAccountPrefs(account));
      final container = ProviderContainer(
        overrides: <Override>[matrixServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      container.read(authControllerProvider);
      await pumpEventQueue();

      final state = container.read(authControllerProvider);
      expect(state, isA<AuthNeedsReconnect>());
      expect(
        (state as AuthNeedsReconnect).message,
        contains('active in another browser tab'),
      );
    },
  );
}

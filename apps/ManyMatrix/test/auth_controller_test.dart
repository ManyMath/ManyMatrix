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

class _RecordingMatrixService implements MatrixService {
  _RecordingMatrixService({
    this.restoreUserId,
    this.loginUserId,
    this.restoreError,
  });

  final String? restoreUserId;
  final String? loginUserId;
  final Object? restoreError;

  int restoreCalls = 0;
  int loginCalls = 0;
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
  Future<String?> restoreSession() async {
    restoreCalls += 1;
    final error = restoreError;
    if (error != null) throw error;
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
    return loginUserId ?? '@$username:example.org';
  }

  @override
  Future<void> clearSavedSession({bool keepHomeserver = true}) async {}

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
}

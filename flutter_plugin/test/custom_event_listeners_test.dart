import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:manymatrix/src/custom_event_listeners.dart';

String _event(String eventType, {String eventId = r'$1'}) => jsonEncode({
      'event_id': eventId,
      'room_id': '!room:example.org',
      'sender': '@alice:example.org',
      'event_type': eventType,
      'content': {'value': 1},
      'timestamp': 0,
    });

void main() {
  test('dispatch delivers the raw payload to every listener for its type', () {
    final listeners = CustomEventListeners();
    final first = <String>[];
    final second = <String>[];
    final other = <String>[];
    listeners.addListener('io.example.foo', first.add);
    listeners.addListener('io.example.foo', second.add);
    listeners.addListener('io.example.bar', other.add);

    final payload = _event('io.example.foo');
    listeners.dispatch(payload);

    expect(first, [payload]);
    expect(second, [payload]);
    expect(other, isEmpty);
  });

  test('dispatch ignores unknown types and malformed payloads', () {
    final listeners = CustomEventListeners();
    final received = <String>[];
    listeners.addListener('io.example.foo', received.add);

    listeners.dispatch(_event('io.example.unrelated'));
    listeners.dispatch('not json');
    listeners.dispatch(jsonEncode(['io.example.foo']));
    listeners.dispatch(jsonEncode({'event_type': 7}));

    expect(received, isEmpty);
  });

  test('a throwing listener does not stop the others', () {
    final listeners = CustomEventListeners();
    final received = <String>[];
    final errors = <Object>[];
    listeners.addListener('io.example.foo', (_) => throw StateError('boom'));
    listeners.addListener('io.example.foo', received.add);

    runZonedGuarded(
      () => listeners.dispatch(_event('io.example.foo')),
      (error, _) => errors.add(error),
    );

    expect(received, hasLength(1));
    expect(errors.single, isA<StateError>());
  });

  test('each event type is subscribed once per client', () {
    final listeners = CustomEventListeners();
    listeners.addListener('io.example.foo', (_) {});
    listeners.addListener('io.example.foo', (_) {});

    expect(listeners.beginSubscription('io.example.foo'), isNotNull);
    expect(listeners.beginSubscription('io.example.foo'), isNull);

    listeners.resetSubscriptions();
    expect(listeners.eventTypes, ['io.example.foo']);
    expect(listeners.beginSubscription('io.example.foo'), isNotNull);
  });

  test('a failed subscription can be retried', () {
    final listeners = CustomEventListeners();
    final token = listeners.beginSubscription('io.example.foo')!;

    listeners.subscriptionFailed('io.example.foo', token);

    expect(listeners.beginSubscription('io.example.foo'), isNotNull);
  });

  test('a failure from a replaced client keeps the newer subscription', () {
    final listeners = CustomEventListeners();
    final stale = listeners.beginSubscription('io.example.foo')!;
    listeners.resetSubscriptions();
    expect(listeners.beginSubscription('io.example.foo'), isNotNull);

    listeners.subscriptionFailed('io.example.foo', stale);

    expect(listeners.beginSubscription('io.example.foo'), isNull);
  });

  test('clear drops listeners and subscriptions', () {
    final listeners = CustomEventListeners();
    final received = <String>[];
    listeners.addListener('io.example.foo', received.add);
    listeners.markSubscribed('io.example.foo');

    listeners.clear();
    listeners.dispatch(_event('io.example.foo'));

    expect(received, isEmpty);
    expect(listeners.eventTypes, isEmpty);
    expect(listeners.beginSubscription('io.example.foo'), isNotNull);
  });
}

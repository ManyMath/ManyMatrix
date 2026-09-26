import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

typedef CustomEventCallback = void Function(String json);

/// Fans the web runtime's single `custom_event` stream out to the listeners
/// registered per event type, and tracks which types the current Rust client
/// has a handler for.
///
/// The web dispatcher registers one matrix-sdk handler per event type and
/// client (`events.subscribe_custom`), so every listener for a type shares
/// that subscription. Replacing the client (login, restore, Worker recovery)
/// drops the handlers, which is what [resetSubscriptions] records.
class CustomEventListeners {
  final Map<String, List<CustomEventCallback>> _listeners = {};
  final Set<String> _subscribed = {};
  int _generation = 0;

  /// Every event type with at least one listener.
  List<String> get eventTypes => _listeners.keys.toList();

  /// Adds [callback] for [eventType] alongside any existing listeners.
  void addListener(String eventType, CustomEventCallback callback) {
    (_listeners[eventType] ??= []).add(callback);
  }

  /// Claims the subscription for [eventType] on the current client.
  ///
  /// Returns a token to pass to [subscriptionFailed] when the caller must
  /// issue `events.subscribe_custom`, or null when that already happened.
  int? beginSubscription(String eventType) =>
      _subscribed.add(eventType) ? _generation : null;

  /// Records a subscription established outside [beginSubscription].
  void markSubscribed(String eventType) => _subscribed.add(eventType);

  /// Releases the claim from [beginSubscription] so a later registration can
  /// retry. A failure that belongs to a replaced client is ignored.
  void subscriptionFailed(String eventType, int token) {
    if (token == _generation) _subscribed.remove(eventType);
  }

  /// Forgets every subscription because the Rust client was replaced.
  void resetSubscriptions() {
    _generation += 1;
    _subscribed.clear();
  }

  /// Delivers a JSON CustomEvent [payload] to the listeners for its
  /// `event_type`. A throwing listener does not stop the others.
  void dispatch(String payload) {
    final Object? eventType;
    try {
      final decoded = jsonDecode(payload);
      eventType = decoded is Map ? decoded['event_type'] : null;
    } on FormatException catch (error) {
      developer.log(
        'dropped a malformed custom event: $error',
        name: 'manymatrix.bridge',
      );
      return;
    }
    final listeners = _listeners[eventType];
    if (listeners == null) return;
    for (final listener in List.of(listeners)) {
      try {
        listener(payload);
      } catch (error, stackTrace) {
        Zone.current.handleUncaughtError(error, stackTrace);
      }
    }
  }

  /// Drops every listener and subscription.
  void clear() {
    _listeners.clear();
    resetSubscriptions();
  }
}

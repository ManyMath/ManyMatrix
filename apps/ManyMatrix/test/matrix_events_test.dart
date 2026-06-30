import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:manymatrix_app/src/matrix/events.dart';

Map<String, dynamic> _eventJson({
  String eventId = r'$evt1',
  String roomId = '!room:example.org',
}) =>
    <String, dynamic>{
      'event_id': eventId,
      'room_id': roomId,
      'sender': '@alice:example.org',
      'body': 'hello',
      'formatted_body': null,
      'msgtype': 'm.text',
      'timestamp': 1700000000000,
      'in_reply_to': null,
      'thread_root': null,
    };

void main() {
  group('tryParseMessageEvent', () {
    test('parses a valid onMessage payload', () {
      final event = tryParseMessageEvent(jsonEncode(_eventJson()));
      expect(event, isNotNull);
      expect(event!.eventId, r'$evt1');
      expect(event.roomId, '!room:example.org');
      expect(event.sender, '@alice:example.org');
      expect(event.body, 'hello');
      expect(event.msgtype, 'm.text');
      expect(event.timestamp, 1700000000000);
    });

    test('returns null for malformed JSON', () {
      expect(tryParseMessageEvent('not json'), isNull);
    });

    test('returns null for non-object JSON', () {
      expect(tryParseMessageEvent('[1, 2, 3]'), isNull);
    });

    test('returns null when required fields are missing', () {
      expect(tryParseMessageEvent('{"event_id": "x"}'), isNull);
    });

    test('returns null when a field has the wrong type', () {
      final bad = _eventJson()..['timestamp'] = 'yesterday';
      expect(tryParseMessageEvent(jsonEncode(bad)), isNull);
    });
  });

  group('messageEventStream', () {
    test('emits parsed events and drops bad payloads', () async {
      final raw = StreamController<String>();
      final events = messageEventStream(raw.stream).toList();

      raw
        ..add(jsonEncode(_eventJson(eventId: r'$a')))
        ..add('garbage')
        ..add(jsonEncode(_eventJson(eventId: r'$b')))
        ..add('{"partial": true}');
      await raw.close();

      final received = await events;
      expect(received.map((e) => e.eventId), [r'$a', r'$b']);
    });
  });
}

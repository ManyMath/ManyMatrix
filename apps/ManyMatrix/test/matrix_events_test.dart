import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:manymatrix_app/src/matrix/events.dart';

Map<String, dynamic> _eventJson({
  String eventId = r'$evt1',
  String roomId = '!room:example.org',
}) => <String, dynamic>{
  'event_id': eventId,
  'room_id': roomId,
  'sender': '@alice:example.org',
  'body': 'hello',
  'formatted_body': null,
  'msgtype': 'm.text',
  'timestamp': 1700000000000,
  'in_reply_to': null,
  'thread_root': null,
  'replaces_event_id': null,
  'edited_at': null,
};

Map<String, dynamic> _reactionJson({
  String eventId = r'$reaction1',
  String relatesToEventId = r'$evt1',
}) => <String, dynamic>{
  'event_id': eventId,
  'room_id': '!room:example.org',
  'sender': '@bob:example.org',
  'relates_to_event_id': relatesToEventId,
  'key': '+1',
  'timestamp': 1700000000001,
};

Map<String, dynamic> _receiptJson({
  String eventId = r'$evt1',
  String userId = '@bob:example.org',
  int? timestamp = 1700000000002,
}) => <String, dynamic>{
  'room_id': '!room:example.org',
  'user_id': userId,
  'event_id': eventId,
  'receipt_type': 'm.read',
  'timestamp': timestamp,
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

    test('parses replacement metadata', () {
      final event = tryParseMessageEvent(
        jsonEncode(
          _eventJson()
            ..['replaces_event_id'] = r'$original'
            ..['edited_at'] = 1700000000100,
        ),
      );

      expect(event, isNotNull);
      expect(event!.replacesEventId, r'$original');
      expect(event.editedAt, 1700000000100);
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

  group('tryParseReactionEvent', () {
    test('parses a valid onReaction payload', () {
      final event = tryParseReactionEvent(jsonEncode(_reactionJson()));
      expect(event, isNotNull);
      expect(event!.eventId, r'$reaction1');
      expect(event.roomId, '!room:example.org');
      expect(event.sender, '@bob:example.org');
      expect(event.relatesToEventId, r'$evt1');
      expect(event.key, '+1');
      expect(event.timestamp, 1700000000001);
    });

    test('returns null for malformed or incomplete payloads', () {
      expect(tryParseReactionEvent('not json'), isNull);
      expect(tryParseReactionEvent('[1, 2, 3]'), isNull);
      expect(tryParseReactionEvent('{"event_id": "x"}'), isNull);
    });
  });

  group('reactionEventStream', () {
    test('emits parsed events and drops bad payloads', () async {
      final raw = StreamController<String>();
      final events = reactionEventStream(raw.stream).toList();

      raw
        ..add(jsonEncode(_reactionJson(eventId: r'$a')))
        ..add('garbage')
        ..add(jsonEncode(_reactionJson(eventId: r'$b')))
        ..add('{"partial": true}');
      await raw.close();

      final received = await events;
      expect(received.map((e) => e.eventId), [r'$a', r'$b']);
    });
  });

  group('tryParseReceiptEvent', () {
    test('parses a valid onReceipt payload', () {
      final event = tryParseReceiptEvent(jsonEncode(_receiptJson()));
      expect(event, isNotNull);
      expect(event!.roomId, '!room:example.org');
      expect(event.userId, '@bob:example.org');
      expect(event.eventId, r'$evt1');
      expect(event.receiptType, 'm.read');
      expect(event.timestamp, 1700000000002);
    });

    test('accepts receipts with null timestamps', () {
      final event = tryParseReceiptEvent(
        jsonEncode(_receiptJson(timestamp: null)),
      );
      expect(event, isNotNull);
      expect(event!.timestamp, isNull);
    });

    test('returns null for malformed or incomplete payloads', () {
      expect(tryParseReceiptEvent('not json'), isNull);
      expect(tryParseReceiptEvent('[1, 2, 3]'), isNull);
      expect(tryParseReceiptEvent('{"event_id": "x"}'), isNull);
    });
  });

  group('receiptEventStream', () {
    test('emits parsed events and drops bad payloads', () async {
      final raw = StreamController<String>();
      final events = receiptEventStream(raw.stream).toList();

      raw
        ..add(jsonEncode(_receiptJson(eventId: r'$a')))
        ..add('garbage')
        ..add(jsonEncode(_receiptJson(eventId: r'$b')))
        ..add('{"partial": true}');
      await raw.close();

      final received = await events;
      expect(received.map((e) => e.eventId), [r'$a', r'$b']);
    });
  });
}

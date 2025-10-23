import 'package:flutter_test/flutter_test.dart';
import 'package:manymatrix_app/src/models/models.dart';

void main() {
  group('RoomSummary', () {
    test('fromJson with all fields', () {
      final json = {
        'room_id': '!abc:matrix.org',
        'display_name': 'Test Room',
        'avatar_url': 'mxc://matrix.org/abc',
        'last_message': {
          'sender': '@alice:matrix.org',
          'body': 'Hello',
          'timestamp': 1234567890,
        },
        'unread_count': 5,
      };
      final room = RoomSummary.fromJson(json);
      expect(room.roomId, '!abc:matrix.org');
      expect(room.displayName, 'Test Room');
      expect(room.avatarUrl, 'mxc://matrix.org/abc');
      expect(room.lastMessage?.body, 'Hello');
      expect(room.unreadCount, 5);
    });

    test('fromJson with null optional fields', () {
      final json = {
        'room_id': '!abc:matrix.org',
        'display_name': 'Test Room',
        'avatar_url': null,
        'last_message': null,
        'unread_count': 0,
      };
      final room = RoomSummary.fromJson(json);
      expect(room.avatarUrl, isNull);
      expect(room.lastMessage, isNull);
    });

    test('toJson round-trip', () {
      final original = RoomSummary(
        roomId: '!test:example.com',
        displayName: 'Round Trip',
        avatarUrl: 'mxc://example.com/avatar',
        lastMessage: LastMessage(
          sender: '@bob:example.com',
          body: 'Test message',
          timestamp: 9999999,
        ),
        unreadCount: 3,
      );
      final json = original.toJson();
      final restored = RoomSummary.fromJson(json);
      expect(restored.roomId, original.roomId);
      expect(restored.displayName, original.displayName);
      expect(restored.avatarUrl, original.avatarUrl);
      expect(restored.lastMessage?.sender, original.lastMessage?.sender);
      expect(restored.lastMessage?.body, original.lastMessage?.body);
      expect(restored.unreadCount, original.unreadCount);
    });
  });

  group('LastMessage', () {
    test('fromJson creates correct instance', () {
      final json = {
        'sender': '@alice:matrix.org',
        'body': 'Hello world',
        'timestamp': 1234567890,
      };
      final msg = LastMessage.fromJson(json);
      expect(msg.sender, '@alice:matrix.org');
      expect(msg.body, 'Hello world');
      expect(msg.timestamp, 1234567890);
    });

    test('toJson produces correct map', () {
      final msg = LastMessage(
        sender: '@alice:matrix.org',
        body: 'Hello',
        timestamp: 100,
      );
      final json = msg.toJson();
      expect(json['sender'], '@alice:matrix.org');
      expect(json['body'], 'Hello');
      expect(json['timestamp'], 100);
    });
  });

  group('MessageEvent', () {
    test('fromJson with all fields', () {
      final json = {
        'event_id': '\$event1',
        'room_id': '!abc:matrix.org',
        'sender': '@alice:matrix.org',
        'body': 'Hello world',
        'formatted_body': '<b>Hello world</b>',
        'msgtype': 'm.text',
        'timestamp': 1234567890,
        'in_reply_to': '\$parent',
        'thread_root': '\$thread',
      };
      final msg = MessageEvent.fromJson(json);
      expect(msg.eventId, '\$event1');
      expect(msg.sender, '@alice:matrix.org');
      expect(msg.body, 'Hello world');
      expect(msg.formattedBody, '<b>Hello world</b>');
      expect(msg.msgtype, 'm.text');
      expect(msg.timestamp, 1234567890);
      expect(msg.inReplyTo, '\$parent');
      expect(msg.threadRoot, '\$thread');
    });

    test('fromJson with null optional fields', () {
      final json = {
        'event_id': '\$event1',
        'room_id': '!abc:matrix.org',
        'sender': '@alice:matrix.org',
        'body': 'Hello',
        'formatted_body': null,
        'msgtype': 'm.text',
        'timestamp': 1234567890,
        'in_reply_to': null,
        'thread_root': null,
      };
      final msg = MessageEvent.fromJson(json);
      expect(msg.formattedBody, isNull);
      expect(msg.inReplyTo, isNull);
      expect(msg.threadRoot, isNull);
    });

    test('toJson round-trip', () {
      final original = MessageEvent(
        eventId: '\$evt',
        roomId: '!r:m.org',
        sender: '@a:m.org',
        body: 'Test',
        msgtype: 'm.text',
        timestamp: 500,
      );
      final json = original.toJson();
      final restored = MessageEvent.fromJson(json);
      expect(restored.eventId, original.eventId);
      expect(restored.body, original.body);
      expect(restored.formattedBody, isNull);
    });
  });

  group('PaginatedMessages', () {
    test('fromJson with messages and token', () {
      final json = {
        'messages': [
          {
            'event_id': '\$e1',
            'room_id': '!r:m.org',
            'sender': '@a:m.org',
            'body': 'Hi',
            'formatted_body': null,
            'msgtype': 'm.text',
            'timestamp': 100,
            'in_reply_to': null,
            'thread_root': null,
          },
        ],
        'end_token': 'token123',
      };
      final paginated = PaginatedMessages.fromJson(json);
      expect(paginated.messages.length, 1);
      expect(paginated.messages[0].body, 'Hi');
      expect(paginated.endToken, 'token123');
    });

    test('fromJson with empty messages and null token', () {
      final json = {
        'messages': <dynamic>[],
        'end_token': null,
      };
      final paginated = PaginatedMessages.fromJson(json);
      expect(paginated.messages, isEmpty);
      expect(paginated.endToken, isNull);
    });

    test('toJson round-trip', () {
      final original = PaginatedMessages(
        messages: [
          MessageEvent(
            eventId: '\$e1',
            roomId: '!r:m.org',
            sender: '@a:m.org',
            body: 'Hello',
            msgtype: 'm.text',
            timestamp: 200,
          ),
        ],
        endToken: 'tok',
      );
      final json = original.toJson();
      final restored = PaginatedMessages.fromJson(json);
      expect(restored.messages.length, 1);
      expect(restored.messages[0].body, 'Hello');
      expect(restored.endToken, 'tok');
    });
  });
}

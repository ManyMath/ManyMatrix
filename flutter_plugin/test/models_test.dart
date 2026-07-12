import 'package:flutter_test/flutter_test.dart';
import 'package:manymatrix/manymatrix.dart';

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
        'is_synced': false,
      };
      final room = RoomSummary.fromJson(json);
      expect(room.roomId, '!abc:matrix.org');
      expect(room.displayName, 'Test Room');
      expect(room.avatarUrl, 'mxc://matrix.org/abc');
      expect(room.lastMessage?.body, 'Hello');
      expect(room.unreadCount, 5);
      expect(room.isSynced, isFalse);
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
      expect(room.isSynced, isTrue);
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
        isSynced: false,
      );
      final json = original.toJson();
      final restored = RoomSummary.fromJson(json);
      expect(restored.roomId, original.roomId);
      expect(restored.displayName, original.displayName);
      expect(restored.avatarUrl, original.avatarUrl);
      expect(restored.lastMessage?.sender, original.lastMessage?.sender);
      expect(restored.lastMessage?.body, original.lastMessage?.body);
      expect(restored.unreadCount, original.unreadCount);
      expect(restored.isSynced, original.isSynced);
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
        'replaces_event_id': '\$original',
        'edited_at': 1234567900,
        'mxc_uri': 'mxc://matrix.org/media',
        'media_source': {'url': 'mxc://matrix.org/media'},
        'filename': 'proof.txt',
        'file_size': 12,
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
      expect(msg.replacesEventId, '\$original');
      expect(msg.editedAt, 1234567900);
      expect(msg.mxcUri, 'mxc://matrix.org/media');
      expect(msg.mediaSource, {'url': 'mxc://matrix.org/media'});
      expect(msg.filename, 'proof.txt');
      expect(msg.fileSize, 12);
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
        'replaces_event_id': null,
        'edited_at': null,
      };
      final msg = MessageEvent.fromJson(json);
      expect(msg.formattedBody, isNull);
      expect(msg.inReplyTo, isNull);
      expect(msg.threadRoot, isNull);
      expect(msg.replacesEventId, isNull);
      expect(msg.editedAt, isNull);
    });

    test('toJson round-trip', () {
      final original = MessageEvent(
        eventId: '\$evt',
        roomId: '!r:m.org',
        sender: '@a:m.org',
        body: 'Test',
        msgtype: 'm.text',
        timestamp: 500,
        editedAt: 600,
        mxcUri: 'mxc://m.org/file',
        filename: 'file.bin',
        fileSize: 42,
      );
      final json = original.toJson();
      final restored = MessageEvent.fromJson(json);
      expect(restored.eventId, original.eventId);
      expect(restored.body, original.body);
      expect(restored.formattedBody, isNull);
      expect(restored.editedAt, 600);
      expect(restored.mxcUri, original.mxcUri);
      expect(restored.filename, original.filename);
      expect(restored.fileSize, original.fileSize);
    });
  });

  group('ReactionEvent', () {
    test('fromJson with all fields', () {
      final json = {
        'event_id': '\$reaction1',
        'room_id': '!abc:matrix.org',
        'sender': '@bob:matrix.org',
        'relates_to_event_id': '\$event1',
        'key': '+1',
        'timestamp': 1234567891,
      };
      final reaction = ReactionEvent.fromJson(json);
      expect(reaction.eventId, '\$reaction1');
      expect(reaction.roomId, '!abc:matrix.org');
      expect(reaction.sender, '@bob:matrix.org');
      expect(reaction.relatesToEventId, '\$event1');
      expect(reaction.key, '+1');
      expect(reaction.timestamp, 1234567891);
    });

    test('toJson round-trip', () {
      final original = ReactionEvent(
        eventId: '\$reaction',
        roomId: '!r:m.org',
        sender: '@a:m.org',
        relatesToEventId: '\$target',
        key: 'ok',
        timestamp: 600,
      );
      final json = original.toJson();
      final restored = ReactionEvent.fromJson(json);
      expect(restored.eventId, original.eventId);
      expect(restored.relatesToEventId, original.relatesToEventId);
      expect(restored.key, original.key);
    });
  });

  group('ThreadSummary', () {
    test('round-trips authoritative counts and latest activity', () {
      final summary = ThreadSummary.fromJson({
        'room_id': '!product:example.org',
        'room_name': 'Product',
        'root': {
          'event_id': r'$root',
          'room_id': '!product:example.org',
          'sender': '@alice:example.org',
          'body': 'Design review',
          'formatted_body': null,
          'msgtype': 'm.text',
          'timestamp': 100,
          'in_reply_to': null,
          'thread_root': null,
          'replaces_event_id': null,
          'edited_at': null,
        },
        'latest_reply': {
          'event_id': r'$latest',
          'room_id': '!product:example.org',
          'sender': '@bob:example.org',
          'body': 'Ready to ship',
          'formatted_body': null,
          'msgtype': 'm.text',
          'timestamp': 250,
          'in_reply_to': r'$root',
          'thread_root': r'$root',
          'replaces_event_id': null,
          'edited_at': null,
        },
        'reply_count': 3,
        'unread_count': 2,
        'current_user_participated': true,
      });

      expect(summary.root.eventId, r'$root');
      expect(summary.latestReply?.eventId, r'$latest');
      expect(summary.replyCount, 3);
      expect(summary.unreadCount, 2);
      expect(summary.currentUserParticipated, isTrue);
      expect(summary.lastActivityTimestamp, 250);
      expect(ThreadSummary.fromJson(summary.toJson()).unreadCount, 2);
      expect(summary.copyWith(unreadCount: 0).unreadCount, 0);
    });

    test('preserves unavailable unread state', () {
      final summary = ThreadSummary.fromJson({
        'room_id': '!room:example.org',
        'room_name': 'Room',
        'root': {
          'event_id': r'$root',
          'room_id': '!room:example.org',
          'sender': '@alice:example.org',
          'body': 'Root',
          'formatted_body': null,
          'msgtype': 'm.text',
          'timestamp': 1,
          'in_reply_to': null,
          'thread_root': null,
          'replaces_event_id': null,
          'edited_at': null,
        },
        'latest_reply': null,
        'reply_count': 1,
        'unread_count': null,
        'current_user_participated': false,
      });

      expect(summary.unreadCount, isNull);
      expect(summary.toJson()['unread_count'], isNull);
    });

    test('paginated thread messages preserve root and token', () {
      final root = MessageEvent(
        eventId: r'$root',
        roomId: '!room:example.org',
        sender: '@alice:example.org',
        body: 'Root',
        msgtype: 'm.text',
        timestamp: 1,
      );
      final page = PaginatedThreadMessages(
        root: root,
        messages: [
          MessageEvent(
            eventId: r'$reply',
            roomId: root.roomId,
            sender: '@bob:example.org',
            body: 'Reply',
            msgtype: 'm.text',
            timestamp: 2,
            threadRoot: root.eventId,
          ),
        ],
        endToken: 'older',
      );

      final restored = PaginatedThreadMessages.fromJson(page.toJson());
      expect(restored.root.eventId, r'$root');
      expect(restored.messages.single.threadRoot, r'$root');
      expect(restored.endToken, 'older');
    });
  });

  group('ReceiptEvent', () {
    test('fromJson with all fields', () {
      final json = {
        'room_id': '!abc:matrix.org',
        'user_id': '@bob:matrix.org',
        'event_id': '\$event1',
        'receipt_type': 'm.read',
        'thread_id': '\$root',
        'timestamp': 1234567892,
      };
      final receipt = ReceiptEvent.fromJson(json);
      expect(receipt.roomId, '!abc:matrix.org');
      expect(receipt.userId, '@bob:matrix.org');
      expect(receipt.eventId, '\$event1');
      expect(receipt.receiptType, 'm.read');
      expect(receipt.threadId, '\$root');
      expect(receipt.timestamp, 1234567892);
    });

    test('fromJson accepts null timestamp', () {
      final receipt = ReceiptEvent.fromJson({
        'room_id': '!abc:matrix.org',
        'user_id': '@bob:matrix.org',
        'event_id': '\$event1',
        'receipt_type': 'm.read',
        'timestamp': null,
      });
      expect(receipt.timestamp, isNull);
    });

    test('toJson round-trip', () {
      final original = ReceiptEvent(
        roomId: '!r:m.org',
        userId: '@a:m.org',
        eventId: '\$target',
        receiptType: 'm.read',
        threadId: 'main',
        timestamp: 700,
      );
      final json = original.toJson();
      final restored = ReceiptEvent.fromJson(json);
      expect(restored.userId, original.userId);
      expect(restored.eventId, original.eventId);
      expect(restored.receiptType, original.receiptType);
      expect(restored.threadId, original.threadId);
      expect(restored.timestamp, original.timestamp);
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

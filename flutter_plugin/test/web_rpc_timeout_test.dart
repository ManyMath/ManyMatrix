import 'package:flutter_test/flutter_test.dart';
import 'package:manymatrix/src/web_rpc_timeout.dart';

void main() {
  test('media RPCs allow long uploads and downloads to finish', () {
    expect(webRpcTimeout('media.upload'), const Duration(minutes: 5));
    expect(webRpcTimeout('media.download'), const Duration(minutes: 5));
    expect(webRpcTimeout('media.thumbnail'), const Duration(minutes: 5));
  });

  test('non-media RPCs retain the normal deadline', () {
    expect(webRpcTimeout('rooms.list'), const Duration(seconds: 30));
    expect(webRpcTimeout('messages.send_text'), const Duration(seconds: 30));
    expect(webRpcTimeout('sync.start'), const Duration(seconds: 30));
  });

  test('sync.once waits out its long-poll and a background round', () {
    expect(webRpcTimeout('sync.once'), const Duration(seconds: 70));
    expect(
      webRpcTimeout('sync.once', {'timeout_ms': 0}),
      const Duration(seconds: 40),
    );
    expect(
      webRpcTimeout('sync.once', {'timeout_ms': 50000}),
      const Duration(seconds: 90),
    );
    expect(
      webRpcTimeout('sync.once', {'timeout_ms': -1}),
      const Duration(seconds: 70),
    );
  });

  test('restore and key backup RPCs get a multi-minute deadline', () {
    for (final method in [
      'auth.restore',
      'e2ee.bootstrap_cross_signing',
      'e2ee.enable_recovery',
      'e2ee.restore_key_backup',
      'e2ee.wait_for_backup_upload',
    ]) {
      expect(webRpcTimeout(method), const Duration(minutes: 5), reason: method);
    }
    expect(webRpcTimeout('e2ee.is_encrypted'), const Duration(seconds: 30));
  });

  test('a recovery call takes the deadline of the call it wraps', () {
    expect(
      webRpcTimeout('bridge.recovery_call', {
        'method': 'auth.restore',
        'args': <String, dynamic>{},
      }),
      const Duration(minutes: 5),
    );
    expect(
      webRpcTimeout('bridge.recovery_call', {
        'method': 'sync.once',
        'args': <String, dynamic>{'timeout_ms': 1000},
      }),
      const Duration(seconds: 41),
    );
    expect(
      webRpcTimeout('bridge.recovery_call', {'method': 'events.subscribe'}),
      const Duration(seconds: 30),
    );
    expect(webRpcTimeout('bridge.recovery_call'), const Duration(seconds: 30));
  });
}

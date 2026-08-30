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
  });
}

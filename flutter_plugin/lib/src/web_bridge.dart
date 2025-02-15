import 'dart:typed_data';

import 'models/models.dart';

const _webUnsupportedMessage =
    'ManyMatrix web/extension runtime is unavailable in this checkout.';

/// Build-safe web stub for branches that do not contain the WASM bridge.
///
/// This keeps the public package API compileable on web so the example app can
/// retain its browser and extension build surfaces during the v1.5 reorg.
class ManyMatrixBridge {
  ManyMatrixBridge._();

  static Future<void> initialize(String libraryPath) async {
    if (libraryPath.isNotEmpty) {
      return;
    }
  }

  static Future<ManyMatrixBridge> create(
    String homeserverUrl,
    String storePath,
  ) async {
    if (homeserverUrl.isEmpty && storePath.isEmpty) {
      throw UnsupportedError(_webUnsupportedMessage);
    }
    return ManyMatrixBridge._();
  }

  Future<T> _unsupported<T>() {
    return Future<T>.error(UnsupportedError(_webUnsupportedMessage));
  }

  Future<String> login(String username, String password) => _unsupported();
  Future<void> restore(String sessionJson) => _unsupported();
  Future<void> syncOnce() => _unsupported();
  Future<void> syncForever() => _unsupported();
  Future<List<RoomSummary>> joinedRooms() => _unsupported();
  Future<void> logout() => _unsupported();
  Future<String?> syncToken() => _unsupported();
  Future<String> createRoom({String? name, String? topic}) => _unsupported();
  Future<String> joinRoom(String roomIdOrAlias) => _unsupported();
  Future<void> invite(String roomId, String userId) => _unsupported();
  Future<void> leaveRoom(String roomId) => _unsupported();
  Future<void> kick(String roomId, String userId, {String? reason}) =>
      _unsupported();
  Future<void> ban(String roomId, String userId, {String? reason}) =>
      _unsupported();
  Future<String?> roomName(String roomId) => _unsupported();
  Future<String?> roomTopic(String roomId) => _unsupported();
  Future<String?> roomAvatarUrl(String roomId) => _unsupported();
  Future<String?> roomMembers(String roomId) => _unsupported();
  Future<String> sendText(String roomId, String body) => _unsupported();
  Future<String> sendHtml(String roomId, String body, String html) =>
      _unsupported();
  Future<String> sendNotice(String roomId, String body) => _unsupported();
  Future<String> sendEmote(String roomId, String body) => _unsupported();
  Future<void> editMessage(String roomId, String eventId, String newBody) =>
      _unsupported();
  Future<String> replyTo(String roomId, String eventId, String body) =>
      _unsupported();
  Future<String> sendReaction(String roomId, String eventId, String key) =>
      _unsupported();
  Future<void> redact(String roomId, String eventId, {String? reason}) =>
      _unsupported();
  Future<String> sendThreadReply(
    String roomId,
    String threadRootId,
    String body,
  ) => _unsupported();
  Future<void> sendReadReceipt(String roomId, String eventId) => _unsupported();
  Future<void> sendTyping(String roomId, bool typing) => _unsupported();
  Future<PaginatedMessages> getMessages(
    String roomId, {
    String? fromToken,
    int limit = 20,
  }) => _unsupported();
  Future<void> enableEncryption(String roomId) => _unsupported();
  Future<String> startVerification(String userId, String deviceId) =>
      _unsupported();
  Future<void> acceptVerification(String userId, String flowId) =>
      _unsupported();
  Future<String> getSasEmojis(String userId, String flowId) => _unsupported();
  Future<void> confirmSas(String userId, String flowId) => _unsupported();
  Future<void> cancelVerification(String userId, String flowId) =>
      _unsupported();
  Future<void> bootstrapCrossSigning() => _unsupported();
  Future<void> setupKeyBackup() => _unsupported();
  Future<void> restoreKeyBackup(String recoveryKey) => _unsupported();
  Future<String> uploadMedia(
    String roomId,
    String filename,
    String mimeType,
    Uint8List data,
  ) => _unsupported();
  Future<Uint8List?> downloadMedia(String mxcUri) => _unsupported();
  Future<Uint8List?> getThumbnail(
    String mxcUri, {
    int width = 128,
    int height = 128,
  }) => _unsupported();
  Future<void> registerPusher({
    required String appId,
    required String pushKey,
    required String appDisplayName,
    required String deviceDisplayName,
    required String pushUrl,
    required String lang,
  }) => _unsupported();

  void onMessage(void Function(String json) callback) {}
  void onReaction(void Function(String json) callback) {}
  void onReceipt(void Function(String json) callback) {}
  void dispose() {}
}

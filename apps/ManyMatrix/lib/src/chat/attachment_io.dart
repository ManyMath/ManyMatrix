import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Bounds browser memory amplification while file bytes and base64 RPC data
/// coexist in the UI isolate and Matrix Worker.
const int maxAttachmentBytes = 25 * 1024 * 1024;

class AttachmentTooLargeException implements Exception {
  const AttachmentTooLargeException(this.byteLength);

  final int byteLength;

  @override
  String toString() =>
      'This file is larger than the 25 MiB attachment limit. Choose a smaller file.';
}

class PickedAttachment {
  const PickedAttachment({
    required this.filename,
    required this.mimeType,
    required this.data,
  });

  final String filename;
  final String mimeType;
  final Uint8List data;
}

typedef AttachmentPicker = Future<PickedAttachment?> Function();
typedef AttachmentSaver =
    Future<bool> Function(String filename, String mimeType, Uint8List data);

final attachmentPickerProvider = Provider<AttachmentPicker>(
  (_) => pickAttachment,
);

final attachmentSaverProvider = Provider<AttachmentSaver>(
  (_) => saveAttachment,
);

Future<PickedAttachment?> pickAttachment() async {
  final file = await openFile();
  if (file == null) return null;
  ensureAttachmentSize(await file.length());
  return PickedAttachment(
    filename: file.name,
    mimeType: file.mimeType ?? mimeTypeForFilename(file.name),
    data: await file.readAsBytes(),
  );
}

void ensureAttachmentSize(int byteLength) {
  if (byteLength > maxAttachmentBytes) {
    throw AttachmentTooLargeException(byteLength);
  }
}

Future<bool> saveAttachment(
  String filename,
  String mimeType,
  Uint8List data,
) async {
  final file = XFile.fromData(data, name: filename, mimeType: mimeType);
  if (kIsWeb) {
    await file.saveTo('');
    return true;
  }

  final location = await getSaveLocation(suggestedName: filename);
  if (location == null) return false;
  await file.saveTo(location.path);
  return true;
}

String mimeTypeForFilename(String filename) {
  final extension = filename.toLowerCase().split('.').lastOrNull;
  return switch (extension) {
    'aac' => 'audio/aac',
    'avi' => 'video/x-msvideo',
    'csv' => 'text/csv',
    'gif' => 'image/gif',
    'htm' || 'html' => 'text/html',
    'jpeg' || 'jpg' => 'image/jpeg',
    'json' => 'application/json',
    'm4a' => 'audio/mp4',
    'mov' => 'video/quicktime',
    'mp3' => 'audio/mpeg',
    'mp4' => 'video/mp4',
    'ogg' => 'audio/ogg',
    'pdf' => 'application/pdf',
    'png' => 'image/png',
    'svg' => 'image/svg+xml',
    'txt' => 'text/plain',
    'wav' => 'audio/wav',
    'webm' => 'video/webm',
    'webp' => 'image/webp',
    'zip' => 'application/zip',
    _ => 'application/octet-stream',
  };
}

String attachmentMessageType(String mimeType) {
  if (mimeType.startsWith('image/')) return 'm.image';
  if (mimeType.startsWith('audio/')) return 'm.audio';
  if (mimeType.startsWith('video/')) return 'm.video';
  return 'm.file';
}

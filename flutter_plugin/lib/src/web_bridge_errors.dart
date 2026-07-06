class ManyMatrixException implements Exception {
  final String kind;
  final String message;
  final Map<String, dynamic> details;

  ManyMatrixException(this.kind, this.message, this.details);

  @override
  String toString() => 'ManyMatrixException($kind): $message';
}

class ManyMatrixSdkException extends ManyMatrixException {
  ManyMatrixSdkException(String message, {Map<String, dynamic>? details})
      : super('MatrixSdkError', message, details ?? {});
}

class ManyMatrixSerdeException extends ManyMatrixException {
  ManyMatrixSerdeException(String message, {Map<String, dynamic>? details})
      : super('SerdeError', message, details ?? {});
}

class ManyMatrixStorageException extends ManyMatrixException {
  ManyMatrixStorageException(String message, {Map<String, dynamic>? details})
      : super('StorageError', message, details ?? {});
}

class ManyMatrixPanicException extends ManyMatrixException {
  ManyMatrixPanicException(String message, {Map<String, dynamic>? details})
      : super('PanicError', message, details ?? {});
}

final _matrixErrcodePattern = RegExp(r'\bM_[A-Z0-9_]+\b');

String? matrixErrcodeFromMessage(String message) =>
    _matrixErrcodePattern.firstMatch(message)?.group(0);

Map<String, dynamic> _sdkDetailsWithErrcode(
  String message,
  Map<String, dynamic>? details,
) {
  final resolved = <String, dynamic>{...?details};
  if (resolved['errcode'] == null) {
    resolved['errcode'] = matrixErrcodeFromMessage(message);
  }
  resolved.removeWhere((key, value) => value == null);
  return resolved;
}

ManyMatrixException manyMatrixExceptionForEnvelope(
  String kind,
  String message, {
  Map<String, dynamic>? details,
}) {
  switch (kind) {
    case 'MatrixSdkError':
      return ManyMatrixSdkException(
        message,
        details: _sdkDetailsWithErrcode(message, details),
      );
    case 'SerdeError':
      return ManyMatrixSerdeException(message, details: details);
    case 'StorageError':
      return ManyMatrixStorageException(message, details: details);
    case 'PanicError':
      return ManyMatrixPanicException(message, details: details);
    default:
      return ManyMatrixException(kind, message, details ?? {});
  }
}

ManyMatrixException manyMatrixExceptionForNativeError(
  String message, {
  String? method,
}) {
  final lower = message.toLowerCase();
  final details = <String, dynamic>{
    'transport': 'native_ffi',
    if (method != null) 'method': method,
  };
  final errcode = matrixErrcodeFromMessage(message);
  if (errcode != null) {
    details['errcode'] = errcode;
  }
  if (lower.contains('json') ||
      lower.contains('serde') ||
      lower.contains('invalid content_json') ||
      lower.contains('id parse error')) {
    return ManyMatrixSerdeException(message, details: details);
  }
  if (lower.contains('panic')) {
    return ManyMatrixPanicException(message, details: details);
  }
  if (lower.contains('io error') ||
      lower.contains('storage') ||
      lower.contains('store') ||
      lower.contains('no native reply') ||
      lower.contains('unknown ffi method')) {
    return ManyMatrixStorageException(message, details: details);
  }
  return ManyMatrixSdkException(message, details: details);
}

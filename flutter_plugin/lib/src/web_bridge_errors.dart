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

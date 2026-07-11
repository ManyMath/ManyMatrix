String matrixUserDisplayName(String userId) {
  final trimmed = userId.trim();
  if (trimmed.isEmpty) return userId;

  final withoutSigil = trimmed.startsWith('@') ? trimmed.substring(1) : trimmed;
  final localpart = withoutSigil.split(':').first.trim();
  return localpart.isEmpty ? trimmed : localpart;
}

String matrixEventPermalink({required String roomId, required String eventId}) {
  return 'https://matrix.to/#/${Uri.encodeComponent(roomId)}/'
      '${Uri.encodeComponent(eventId)}';
}

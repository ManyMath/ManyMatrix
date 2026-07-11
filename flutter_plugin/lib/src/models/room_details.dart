class RoomDetails {
  const RoomDetails({
    required this.roomId,
    this.canonicalAlias,
    this.altAliases = const <String>[],
  });

  final String roomId;
  final String? canonicalAlias;
  final List<String> altAliases;

  factory RoomDetails.fromJson(Map<String, dynamic> json) {
    return RoomDetails(
      roomId: json['room_id'] as String,
      canonicalAlias: json['canonical_alias'] as String?,
      altAliases: (json['alt_aliases'] as List<dynamic>? ?? const <dynamic>[])
          .cast<String>(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'room_id': roomId,
        'canonical_alias': canonicalAlias,
        'alt_aliases': altAliases,
      };

  List<String> get aliases {
    final seen = <String>{};
    final values = <String>[];
    void add(String? alias) {
      if (alias == null || alias.isEmpty || !seen.add(alias)) return;
      values.add(alias);
    }

    add(canonicalAlias);
    for (final alias in altAliases) {
      add(alias);
    }
    return values;
  }
}

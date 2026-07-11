class RoomInvite {
  const RoomInvite({
    required this.roomId,
    required this.displayName,
    this.avatarUrl,
    this.topic,
    this.canonicalAlias,
    this.altAliases = const <String>[],
    this.invitedUserId,
    this.invitedDisplayName,
    this.invitedAvatarUrl,
    this.inviterUserId,
    this.inviterDisplayName,
    this.inviterAvatarUrl,
  });

  final String roomId;
  final String displayName;
  final String? avatarUrl;
  final String? topic;
  final String? canonicalAlias;
  final List<String> altAliases;
  final String? invitedUserId;
  final String? invitedDisplayName;
  final String? invitedAvatarUrl;
  final String? inviterUserId;
  final String? inviterDisplayName;
  final String? inviterAvatarUrl;

  factory RoomInvite.fromJson(Map<String, dynamic> json) {
    return RoomInvite(
      roomId: json['room_id'] as String,
      displayName: json['display_name'] as String,
      avatarUrl: json['avatar_url'] as String?,
      topic: json['topic'] as String?,
      canonicalAlias: json['canonical_alias'] as String?,
      altAliases: (json['alt_aliases'] as List<dynamic>? ?? const <dynamic>[])
          .cast<String>(),
      invitedUserId: json['invited_user_id'] as String?,
      invitedDisplayName: json['invited_display_name'] as String?,
      invitedAvatarUrl: json['invited_avatar_url'] as String?,
      inviterUserId: json['inviter_user_id'] as String?,
      inviterDisplayName: json['inviter_display_name'] as String?,
      inviterAvatarUrl: json['inviter_avatar_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'room_id': roomId,
        'display_name': displayName,
        'avatar_url': avatarUrl,
        'topic': topic,
        'canonical_alias': canonicalAlias,
        'alt_aliases': altAliases,
        'invited_user_id': invitedUserId,
        'invited_display_name': invitedDisplayName,
        'invited_avatar_url': invitedAvatarUrl,
        'inviter_user_id': inviterUserId,
        'inviter_display_name': inviterDisplayName,
        'inviter_avatar_url': inviterAvatarUrl,
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

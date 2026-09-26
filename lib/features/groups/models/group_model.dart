enum GroupJoinMode { open, inviteOnly, approval }

extension GroupJoinModeX on GroupJoinMode {
  String get value => switch (this) {
        GroupJoinMode.open => 'open',
        GroupJoinMode.inviteOnly => 'invite_only',
        GroupJoinMode.approval => 'approval',
      };

  String get label => switch (this) {
        GroupJoinMode.open => '自由参加',
        GroupJoinMode.inviteOnly => '招待制',
        GroupJoinMode.approval => '入室許可制',
      };

  static GroupJoinMode fromString(String v) => switch (v) {
        'open' => GroupJoinMode.open,
        'invite_only' => GroupJoinMode.inviteOnly,
        'approval' => GroupJoinMode.approval,
        _ => GroupJoinMode.open,
      };
}

class GroupModel {
  final String groupId;
  final String ownerId;
  final String name;
  final String? description;
  final GroupJoinMode joinMode;
  final String? iconUrl;
  final DateTime createdAt;
  final int memberCount;
  final String? ownerArea;
  final DateTime? expiresAt;
  final bool inviteRestrictedToLeader;

  const GroupModel({
    required this.groupId,
    required this.ownerId,
    required this.name,
    this.description,
    required this.joinMode,
    this.iconUrl,
    required this.createdAt,
    this.memberCount = 0,
    this.ownerArea,
    this.expiresAt,
    this.inviteRestrictedToLeader = false,
  });

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());

  factory GroupModel.fromJson(Map<String, dynamic> json) => GroupModel(
        groupId: json['group_id'] as String,
        ownerId: json['owner_id'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        joinMode: GroupJoinModeX.fromString(json['join_mode'] as String),
        iconUrl: json['icon_url'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
        memberCount: json['member_count'] as int? ?? 0,
        ownerArea: (json['owner'] as Map<String, dynamic>?)?['area'] as String?,
        expiresAt: json['expires_at'] != null
            ? DateTime.parse(json['expires_at'] as String).toLocal()
            : null,
        inviteRestrictedToLeader:
            json['invite_restricted_to_leader'] as bool? ?? false,
      );
}

/// 自分宛の未応答グループ招待1件（グループ一覧の最上部表示用）。
class InvitedGroupEntry {
  final String membershipId;
  final GroupModel group;
  const InvitedGroupEntry({required this.membershipId, required this.group});
}

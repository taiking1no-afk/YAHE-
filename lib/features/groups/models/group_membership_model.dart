enum GroupMembershipStatus { member, pending, invited }

extension GroupMembershipStatusX on GroupMembershipStatus {
  static GroupMembershipStatus fromString(String v) => switch (v) {
        'member' => GroupMembershipStatus.member,
        'pending' => GroupMembershipStatus.pending,
        'invited' => GroupMembershipStatus.invited,
        _ => GroupMembershipStatus.pending,
      };
}

class GroupMembershipModel {
  final String membershipId;
  final String groupId;
  final String userId;
  final GroupMembershipStatus status;
  final String role;
  final DateTime createdAt;
  final String? nickname;
  final String? avatarUrl;

  const GroupMembershipModel({
    required this.membershipId,
    required this.groupId,
    required this.userId,
    required this.status,
    required this.role,
    required this.createdAt,
    this.nickname,
    this.avatarUrl,
  });

  bool get isOwner => role == 'owner';
  bool get isLeader => role == 'leader';

  factory GroupMembershipModel.fromJson(Map<String, dynamic> json) =>
      GroupMembershipModel(
        membershipId: json['membership_id'] as String,
        groupId: json['group_id'] as String,
        userId: json['user_id'] as String,
        status: GroupMembershipStatusX.fromString(json['status'] as String),
        role: json['role'] as String? ?? 'member',
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
      );

  GroupMembershipModel withUser({String? nickname, String? avatarUrl}) =>
      GroupMembershipModel(
        membershipId: membershipId,
        groupId: groupId,
        userId: userId,
        status: status,
        role: role,
        createdAt: createdAt,
        nickname: nickname,
        avatarUrl: avatarUrl,
      );
}

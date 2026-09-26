enum AppNotificationType {
  match,
  likeReceived,
  customInterest,
  chatMessage,
  groupInvite,
  groupJoinRequest,
  groupInviteDeclined,
  boardInvite,
  boardJoinRequest,
  boardInviteDeclined,
  levelUp,
  groupOwnershipTransferred,
  groupMessage,
  unknown;

  static AppNotificationType fromString(String value) => switch (value) {
        'match' => AppNotificationType.match,
        'like_received' => AppNotificationType.likeReceived,
        'custom_interest' => AppNotificationType.customInterest,
        'chat_message' => AppNotificationType.chatMessage,
        'group_invite' => AppNotificationType.groupInvite,
        'group_join_request' => AppNotificationType.groupJoinRequest,
        'group_invite_declined' => AppNotificationType.groupInviteDeclined,
        'board_invite' => AppNotificationType.boardInvite,
        'board_join_request' => AppNotificationType.boardJoinRequest,
        'board_invite_declined' => AppNotificationType.boardInviteDeclined,
        'level_up' => AppNotificationType.levelUp,
        'group_ownership_transferred' =>
          AppNotificationType.groupOwnershipTransferred,
        'group_message' => AppNotificationType.groupMessage,
        _ => AppNotificationType.unknown,
      };
}

class AppNotificationModel {
  final String notificationId;
  final AppNotificationType type;
  final Map<String, dynamic> payload;
  final String? relatedUserId;
  final bool isRead;
  final DateTime createdAt;

  const AppNotificationModel({
    required this.notificationId,
    required this.type,
    required this.payload,
    this.relatedUserId,
    required this.isRead,
    required this.createdAt,
  });

  factory AppNotificationModel.fromJson(Map<String, dynamic> json) =>
      AppNotificationModel(
        notificationId: json['notification_id'] as String,
        type: AppNotificationType.fromString(json['type'] as String),
        payload: (json['payload'] as Map<String, dynamic>?) ?? const {},
        relatedUserId: json['related_user_id'] as String?,
        isRead: json['is_read'] as bool? ?? false,
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
      );
}

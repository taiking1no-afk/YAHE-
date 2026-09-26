enum GroupMessageContentType { text, photo, quickReply, boardInvite }

extension GroupMessageContentTypeX on GroupMessageContentType {
  String get value => switch (this) {
        GroupMessageContentType.text => 'text',
        GroupMessageContentType.photo => 'photo',
        GroupMessageContentType.quickReply => 'quick_reply',
        GroupMessageContentType.boardInvite => 'board_invite',
      };

  static GroupMessageContentType fromString(String v) => switch (v) {
        'photo' => GroupMessageContentType.photo,
        'quick_reply' => GroupMessageContentType.quickReply,
        'board_invite' => GroupMessageContentType.boardInvite,
        _ => GroupMessageContentType.text,
      };
}

class GroupMessageModel {
  final String messageId;
  final String groupId;
  final String senderId;
  final GroupMessageContentType contentType;
  final String? body;
  final String? photoPath;
  final String? relatedPostId;
  final DateTime createdAt;
  final String? senderNickname;
  final String? senderAvatarUrl;
  final DateTime? deletedAt;

  const GroupMessageModel({
    required this.messageId,
    required this.groupId,
    required this.senderId,
    required this.contentType,
    this.body,
    this.photoPath,
    this.relatedPostId,
    required this.createdAt,
    this.senderNickname,
    this.senderAvatarUrl,
    this.deletedAt,
  });

  bool get isDeleted => deletedAt != null;

  factory GroupMessageModel.fromJson(Map<String, dynamic> json) =>
      GroupMessageModel(
        messageId: json['message_id'] as String,
        groupId: json['group_id'] as String,
        senderId: json['sender_id'] as String,
        contentType:
            GroupMessageContentTypeX.fromString(json['content_type'] as String),
        body: json['body'] as String?,
        photoPath: json['photo_path'] as String?,
        relatedPostId: json['related_post_id'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
        deletedAt: json['deleted_at'] != null
            ? DateTime.parse(json['deleted_at'] as String).toLocal()
            : null,
      );

  GroupMessageModel withSender({String? nickname, String? avatarUrl}) =>
      GroupMessageModel(
        messageId: messageId,
        groupId: groupId,
        senderId: senderId,
        contentType: contentType,
        body: body,
        photoPath: photoPath,
        relatedPostId: relatedPostId,
        createdAt: createdAt,
        senderNickname: nickname,
        senderAvatarUrl: avatarUrl,
        deletedAt: deletedAt,
      );
}

/// グループチャット一覧（自分が参加中のグループ）1件分のサマリー。
class GroupChatSummary {
  final String groupId;
  final String groupName;
  final String? groupIconUrl;
  final String? lastMessageBody;
  final DateTime? lastMessageAt;
  final int unreadCount;

  const GroupChatSummary({
    required this.groupId,
    required this.groupName,
    this.groupIconUrl,
    this.lastMessageBody,
    this.lastMessageAt,
    this.unreadCount = 0,
  });
}

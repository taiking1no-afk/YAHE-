enum ChatContentType { text, photo, sns, quickReply, boardInvite }

extension ChatContentTypeX on ChatContentType {
  String get value => switch (this) {
        ChatContentType.text => 'text',
        ChatContentType.photo => 'photo',
        ChatContentType.sns => 'sns',
        ChatContentType.quickReply => 'quick_reply',
        ChatContentType.boardInvite => 'board_invite',
      };

  static ChatContentType fromString(String v) => switch (v) {
        'photo' => ChatContentType.photo,
        'sns' => ChatContentType.sns,
        'quick_reply' => ChatContentType.quickReply,
        'board_invite' => ChatContentType.boardInvite,
        _ => ChatContentType.text,
      };
}

class ChatMessageModel {
  final String messageId;
  final String threadId;
  final String senderId;
  final ChatContentType contentType;
  final String? body;
  final String? photoPath;
  final String? relatedPostId;
  final DateTime createdAt;
  final DateTime? readAt;
  final DateTime? deletedAt;

  const ChatMessageModel({
    required this.messageId,
    required this.threadId,
    required this.senderId,
    required this.contentType,
    this.body,
    this.photoPath,
    this.relatedPostId,
    required this.createdAt,
    this.readAt,
    this.deletedAt,
  });

  bool get isDeleted => deletedAt != null;

  factory ChatMessageModel.fromJson(Map<String, dynamic> json) =>
      ChatMessageModel(
        messageId: json['message_id'] as String,
        threadId: json['thread_id'] as String,
        senderId: json['sender_id'] as String,
        contentType:
            ChatContentTypeX.fromString(json['content_type'] as String),
        body: json['body'] as String?,
        photoPath: json['photo_path'] as String?,
        relatedPostId: json['related_post_id'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
        readAt: json['read_at'] != null
            ? DateTime.parse(json['read_at'] as String).toLocal()
            : null,
        deletedAt: json['deleted_at'] != null
            ? DateTime.parse(json['deleted_at'] as String).toLocal()
            : null,
      );
}

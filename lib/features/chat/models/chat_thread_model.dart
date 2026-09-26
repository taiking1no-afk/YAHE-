class ChatThreadModel {
  final String matchId;
  final String? threadId;
  final String otherUserId;
  final String? otherNickname;
  final String? otherAvatarUrl;
  final String? lastMessagePreview;
  final DateTime? lastMessageAt;
  final int unreadCount;
  final bool isDissolved; // マッチ解消済み（過去のメッセージのみ閲覧可、新規送信不可）

  const ChatThreadModel({
    required this.matchId,
    this.threadId,
    required this.otherUserId,
    this.otherNickname,
    this.otherAvatarUrl,
    this.lastMessagePreview,
    this.lastMessageAt,
    this.unreadCount = 0,
    this.isDissolved = false,
  });
}

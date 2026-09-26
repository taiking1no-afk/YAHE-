enum BoardPostType { touring, event }

extension BoardPostTypeX on BoardPostType {
  String get value => this == BoardPostType.touring ? 'touring' : 'event';
  String get label => this == BoardPostType.touring ? 'ツーリング募集' : 'イベント・オフ会';
  static BoardPostType fromString(String v) =>
      v == 'event' ? BoardPostType.event : BoardPostType.touring;
}

enum BoardPostMode { smallGroup, largeGroup }

extension BoardPostModeX on BoardPostMode {
  String get value =>
      this == BoardPostMode.smallGroup ? 'small_group' : 'large_group';
  String get label => this == BoardPostMode.smallGroup ? '少人数' : '大人数';
  static BoardPostMode? fromString(String? v) => switch (v) {
        'small_group' => BoardPostMode.smallGroup,
        'large_group' => BoardPostMode.largeGroup,
        _ => null,
      };
}

enum BoardVisibility { open, inviteOnly, approval }

extension BoardVisibilityX on BoardVisibility {
  String get value => switch (this) {
        BoardVisibility.open => 'open',
        BoardVisibility.inviteOnly => 'invite_only',
        BoardVisibility.approval => 'approval',
      };
  String get label => switch (this) {
        BoardVisibility.open => '誰でも参加可能',
        BoardVisibility.inviteOnly => '招待制',
        BoardVisibility.approval => '許可制',
      };
  static BoardVisibility fromString(String v) => switch (v) {
        'open' => BoardVisibility.open,
        'invite_only' => BoardVisibility.inviteOnly,
        'approval' => BoardVisibility.approval,
        _ => BoardVisibility.open,
      };
}

class BoardPostModel {
  final String postId;
  final String organizerId;
  final BoardPostType postType;
  final String title;
  final String? detail;
  final BoardPostMode? mode;
  final String? meetingPlaceText;
  final double? meetingLat;
  final double? meetingLng;
  final String? routeDetail;
  final DateTime? scheduledAt;
  final int? capacity;
  final BoardVisibility visibility;
  final DateTime createdAt;
  final int joinedCount;
  final int interestedCount;
  final String? prefecture;
  final bool isInterestedByMe;
  final bool isJoinedByMe;
  final String? imagePath;
  final String? chatGroupId;

  const BoardPostModel({
    required this.postId,
    required this.organizerId,
    required this.postType,
    required this.title,
    this.detail,
    this.mode,
    this.meetingPlaceText,
    this.meetingLat,
    this.meetingLng,
    this.routeDetail,
    this.scheduledAt,
    this.capacity,
    required this.visibility,
    required this.createdAt,
    this.joinedCount = 0,
    this.interestedCount = 0,
    this.prefecture,
    this.isInterestedByMe = false,
    this.isJoinedByMe = false,
    this.imagePath,
    this.chatGroupId,
  });

  bool get isEnded =>
      scheduledAt != null && scheduledAt!.isBefore(DateTime.now());
  bool get isFull => capacity != null && joinedCount >= capacity!;

  // 終了した募集はサーバー側で開催日の1ヶ月後に自動削除される（migration_v1_67）。
  // PostgreSQLの `timestamp + interval '1 month'` は、対象月にその日が
  // 存在しない場合は月末にクランプする（例: 1/31 → 2/28、オーバーフローで
  // 3/3にはならない）。表示用の計算もこれに合わせないと実際の削除日と
  // 表示がずれるため、単純な `DateTime(y, m+1, d)` は使わない。
  DateTime? get autoDeleteAt {
    if (scheduledAt == null) return null;
    final s = scheduledAt!;
    final targetMonthIndex =
        s.month; // 1-12 の m+1 は DateTime(y, m+1, 1) で年跨ぎも自動処理される
    final firstOfNextMonth = DateTime(s.year, targetMonthIndex + 1, 1);
    final firstOfMonthAfterNext = DateTime(s.year, targetMonthIndex + 2, 1);
    final daysInTargetMonth =
        firstOfMonthAfterNext.difference(firstOfNextMonth).inDays;
    final day = s.day > daysInTargetMonth ? daysInTargetMonth : s.day;
    return DateTime(
        firstOfNextMonth.year, firstOfNextMonth.month, day, s.hour, s.minute);
  }

  int? get daysUntilAutoDelete {
    if (!isEnded) return null;
    final d = autoDeleteAt;
    if (d == null) return null;
    return d.difference(DateTime.now()).inDays.clamp(0, 1 << 30);
  }

  factory BoardPostModel.fromJson(Map<String, dynamic> json) => BoardPostModel(
        postId: json['post_id'] as String,
        organizerId: json['organizer_id'] as String,
        postType: BoardPostTypeX.fromString(json['post_type'] as String),
        title: json['title'] as String,
        detail: json['detail'] as String?,
        mode: BoardPostModeX.fromString(json['mode'] as String?),
        meetingPlaceText: json['meeting_place_text'] as String?,
        meetingLat: (json['meeting_lat'] as num?)?.toDouble(),
        meetingLng: (json['meeting_lng'] as num?)?.toDouble(),
        routeDetail: json['route_detail'] as String?,
        scheduledAt: json['scheduled_at'] != null
            ? DateTime.parse(json['scheduled_at'] as String).toLocal()
            : null,
        capacity: json['capacity'] as int?,
        visibility: BoardVisibilityX.fromString(json['visibility'] as String),
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
        prefecture: json['prefecture'] as String?,
        imagePath: json['image_path'] as String?,
        chatGroupId: json['chat_group_id'] as String?,
      );

  BoardPostModel copyWithCounts({
    required int joinedCount,
    required int interestedCount,
    bool? isInterestedByMe,
    bool? isJoinedByMe,
  }) =>
      BoardPostModel(
        postId: postId,
        organizerId: organizerId,
        postType: postType,
        title: title,
        detail: detail,
        mode: mode,
        meetingPlaceText: meetingPlaceText,
        meetingLat: meetingLat,
        meetingLng: meetingLng,
        routeDetail: routeDetail,
        scheduledAt: scheduledAt,
        capacity: capacity,
        visibility: visibility,
        createdAt: createdAt,
        joinedCount: joinedCount,
        interestedCount: interestedCount,
        prefecture: prefecture,
        isInterestedByMe: isInterestedByMe ?? this.isInterestedByMe,
        isJoinedByMe: isJoinedByMe ?? this.isJoinedByMe,
        imagePath: imagePath,
        chatGroupId: chatGroupId,
      );
}

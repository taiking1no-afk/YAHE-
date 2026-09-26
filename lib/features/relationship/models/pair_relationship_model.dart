class PairRelationshipModel {
  final int totalCount;
  final int driveTogetherCount;
  final int eventTogetherCount;
  final int level;

  const PairRelationshipModel({
    required this.totalCount,
    required this.driveTogetherCount,
    required this.eventTogetherCount,
    required this.level,
  });

  factory PairRelationshipModel.fromJson(Map<String, dynamic> json) =>
      PairRelationshipModel(
        totalCount: json['total_count'] as int? ?? 0,
        driveTogetherCount: json['drive_together_count'] as int? ?? 0,
        eventTogetherCount: json['event_together_count'] as int? ?? 0,
        level: json['level'] as int? ?? 1,
      );

  static const empty = PairRelationshipModel(
    totalCount: 0,
    driveTogetherCount: 0,
    eventTogetherCount: 0,
    level: 1,
  );
}

enum PairAlbumMilestoneType { firstEncounter, touringTogether, eventTogether }

extension PairAlbumMilestoneTypeX on PairAlbumMilestoneType {
  static PairAlbumMilestoneType fromString(String v) => switch (v) {
        'touring_together' => PairAlbumMilestoneType.touringTogether,
        'event_together' => PairAlbumMilestoneType.eventTogether,
        _ => PairAlbumMilestoneType.firstEncounter,
      };

  String get label => switch (this) {
        PairAlbumMilestoneType.firstEncounter => '初めてのすれ違い',
        PairAlbumMilestoneType.touringTogether => '一緒にツーリングに参加',
        PairAlbumMilestoneType.eventTogether => '一緒にイベント・オフ会に参加',
      };

  String get emoji => switch (this) {
        PairAlbumMilestoneType.firstEncounter => '⚡',
        PairAlbumMilestoneType.touringTogether => '🚗',
        PairAlbumMilestoneType.eventTogether => '🎉',
      };
}

class PairAlbumEntryModel {
  final String entryId;
  final PairAlbumMilestoneType milestoneType;
  final DateTime occurredAt;

  const PairAlbumEntryModel({
    required this.entryId,
    required this.milestoneType,
    required this.occurredAt,
  });

  factory PairAlbumEntryModel.fromJson(Map<String, dynamic> json) =>
      PairAlbumEntryModel(
        entryId: json['entry_id'] as String,
        milestoneType: PairAlbumMilestoneTypeX.fromString(
            json['milestone_type'] as String),
        occurredAt: DateTime.parse(json['occurred_at'] as String).toLocal(),
      );
}

class GearRInsightsDailyPoint {
  final DateTime date;
  final int profileViews;
  final int linkClicks;
  final int likesReceived;

  const GearRInsightsDailyPoint({
    required this.date,
    required this.profileViews,
    required this.linkClicks,
    required this.likesReceived,
  });

  factory GearRInsightsDailyPoint.fromJson(Map<String, dynamic> json) =>
      GearRInsightsDailyPoint(
        date: DateTime.parse(json['date'] as String),
        profileViews: (json['profile_views'] as num?)?.toInt() ?? 0,
        linkClicks: (json['link_clicks'] as num?)?.toInt() ?? 0,
        likesReceived: (json['likes_received'] as num?)?.toInt() ?? 0,
      );
}

/// 期間内（7/30/90日切り替えの対象）の指標。
class GearRInsightsPeriod {
  final int profileViews;
  final int likesReceived;
  final int likesReceivedEncounter;
  final int likesReceivedNonEncounter;
  final double likesReceivedNonEncounterPct;
  final int likesSent;
  final int matches;
  final int linkClicks;
  final double linkClickPct;

  const GearRInsightsPeriod({
    required this.profileViews,
    required this.likesReceived,
    required this.likesReceivedEncounter,
    required this.likesReceivedNonEncounter,
    required this.likesReceivedNonEncounterPct,
    required this.likesSent,
    required this.matches,
    required this.linkClicks,
    required this.linkClickPct,
  });

  factory GearRInsightsPeriod.fromJson(Map<String, dynamic> json) =>
      GearRInsightsPeriod(
        profileViews: (json['profile_views'] as num?)?.toInt() ?? 0,
        likesReceived: (json['likes_received'] as num?)?.toInt() ?? 0,
        likesReceivedEncounter:
            (json['likes_received_encounter'] as num?)?.toInt() ?? 0,
        likesReceivedNonEncounter:
            (json['likes_received_non_encounter'] as num?)?.toInt() ?? 0,
        likesReceivedNonEncounterPct:
            (json['likes_received_non_encounter_pct'] as num?)?.toDouble() ?? 0,
        likesSent: (json['likes_sent'] as num?)?.toInt() ?? 0,
        matches: (json['matches'] as num?)?.toInt() ?? 0,
        linkClicks: (json['link_clicks'] as num?)?.toInt() ?? 0,
        linkClickPct: (json['link_click_pct'] as num?)?.toDouble() ?? 0,
      );
}

/// 累計（アカウント開設からの合計、期間切り替えの影響を受けない）指標。
/// すれ違いの生ログは24h/有料7dで自動削除されるため、期間別のすれ違い数は
/// 追跡できない。そのため、すれ違い関連の指標はすべてここに累計値として集約する。
class GearRInsightsLifetime {
  final int encounterCount;
  final int likesReceivedEncounter;
  final double encounterToLikeRate;
  final int matchesTotal;
  final int matchesFromEncounter;
  final double matchesFromEncounterPct;
  final int linkClickToMatch;

  const GearRInsightsLifetime({
    required this.encounterCount,
    required this.likesReceivedEncounter,
    required this.encounterToLikeRate,
    required this.matchesTotal,
    required this.matchesFromEncounter,
    required this.matchesFromEncounterPct,
    required this.linkClickToMatch,
  });

  factory GearRInsightsLifetime.fromJson(Map<String, dynamic> json) =>
      GearRInsightsLifetime(
        encounterCount: (json['encounter_count'] as num?)?.toInt() ?? 0,
        likesReceivedEncounter:
            (json['likes_received_encounter'] as num?)?.toInt() ?? 0,
        encounterToLikeRate:
            (json['encounter_to_like_rate'] as num?)?.toDouble() ?? 0,
        matchesTotal: (json['matches_total'] as num?)?.toInt() ?? 0,
        matchesFromEncounter:
            (json['matches_from_encounter'] as num?)?.toInt() ?? 0,
        matchesFromEncounterPct:
            (json['matches_from_encounter_pct'] as num?)?.toDouble() ?? 0,
        linkClickToMatch: (json['link_click_to_match'] as num?)?.toInt() ?? 0,
      );
}

class GearRInsightsPost {
  final String postId;
  final String title;
  final DateTime? scheduledAt;
  final int viewCount;
  final int joinedCount;
  final int interestedCount;
  final int everInterestedCount;
  final int interestedToJoinedCount;
  final double interestedToJoinedPct;
  final int participantInvitedCount;
  final double participantInvitedPct;

  const GearRInsightsPost({
    required this.postId,
    required this.title,
    this.scheduledAt,
    required this.viewCount,
    required this.joinedCount,
    required this.interestedCount,
    required this.everInterestedCount,
    required this.interestedToJoinedCount,
    required this.interestedToJoinedPct,
    required this.participantInvitedCount,
    required this.participantInvitedPct,
  });

  factory GearRInsightsPost.fromJson(Map<String, dynamic> json) =>
      GearRInsightsPost(
        postId: json['post_id'] as String,
        title: json['title'] as String,
        scheduledAt: json['scheduled_at'] != null
            ? DateTime.tryParse(json['scheduled_at'] as String)?.toLocal()
            : null,
        viewCount: (json['view_count'] as num?)?.toInt() ?? 0,
        joinedCount: (json['joined_count'] as num?)?.toInt() ?? 0,
        interestedCount: (json['interested_count'] as num?)?.toInt() ?? 0,
        everInterestedCount:
            (json['ever_interested_count'] as num?)?.toInt() ?? 0,
        interestedToJoinedCount:
            (json['interested_to_joined_count'] as num?)?.toInt() ?? 0,
        interestedToJoinedPct:
            (json['interested_to_joined_pct'] as num?)?.toDouble() ?? 0,
        participantInvitedCount:
            (json['participant_invited_count'] as num?)?.toInt() ?? 0,
        participantInvitedPct:
            (json['participant_invited_pct'] as num?)?.toDouble() ?? 0,
      );
}

/// Gear R限定「インサイトアクティビティ」— 月次バッチではなく、いつでも
/// その場で集計するリアルタイム版のアクセス解析。
class GearRInsights {
  final int periodDays;
  final GearRInsightsPeriod period;
  final GearRInsightsLifetime lifetime;
  final List<GearRInsightsDailyPoint> daily;
  final List<GearRInsightsPost> posts;

  const GearRInsights({
    required this.periodDays,
    required this.period,
    required this.lifetime,
    required this.daily,
    required this.posts,
  });

  factory GearRInsights.fromJson(Map<String, dynamic> json) => GearRInsights(
        periodDays: (json['period_days'] as num?)?.toInt() ?? 30,
        period: GearRInsightsPeriod.fromJson(
            (json['period'] as Map<String, dynamic>?) ?? const {}),
        lifetime: GearRInsightsLifetime.fromJson(
            (json['lifetime'] as Map<String, dynamic>?) ?? const {}),
        daily: ((json['daily'] as List?) ?? [])
            .map((e) =>
                GearRInsightsDailyPoint.fromJson(e as Map<String, dynamic>))
            .toList(),
        posts: ((json['posts'] as List?) ?? [])
            .map((e) => GearRInsightsPost.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class GearRMonthlyReport {
  final String reportId;
  final int reportYear;
  final int reportMonth;
  final int encounters;
  final int profileViews;
  final int likesReceived;
  final int likesSent;
  final int matches;
  final int linkClicks;
  final double? linkTapRate;
  final DateTime generatedAt;
  final DateTime? pushSentAt;

  const GearRMonthlyReport({
    required this.reportId,
    required this.reportYear,
    required this.reportMonth,
    required this.encounters,
    required this.profileViews,
    required this.likesReceived,
    required this.likesSent,
    required this.matches,
    this.linkClicks = 0,
    this.linkTapRate,
    required this.generatedAt,
    this.pushSentAt,
  });

  factory GearRMonthlyReport.fromJson(Map<String, dynamic> json) {
    final summary = json['summary_json'];
    double? tapRate;
    if (summary is Map && summary['link_tap_rate'] != null) {
      tapRate = (summary['link_tap_rate'] as num?)?.toDouble();
    }
    final views = (json['profile_views'] as num?)?.toInt() ?? 0;
    final clicks = (json['link_clicks'] as num?)?.toInt() ??
        (summary is Map ? (summary['link_clicks'] as num?)?.toInt() : null) ??
        0;
    if (tapRate == null && views > 0) {
      tapRate = (clicks / views) * 100;
    }

    return GearRMonthlyReport(
      reportId: json['report_id'] as String,
      reportYear: json['report_year'] as int,
      reportMonth: json['report_month'] as int,
      encounters: (json['encounters'] as num?)?.toInt() ?? 0,
      profileViews: views,
      likesReceived: (json['likes_received'] as num?)?.toInt() ?? 0,
      likesSent: (json['likes_sent'] as num?)?.toInt() ?? 0,
      matches: (json['matches'] as num?)?.toInt() ?? 0,
      linkClicks: clicks,
      linkTapRate: tapRate,
      generatedAt: DateTime.parse(json['generated_at'] as String).toLocal(),
      pushSentAt: json['push_sent_at'] != null
          ? DateTime.tryParse(json['push_sent_at'] as String)?.toLocal()
          : null,
    );
  }

  String get periodLabel => '$reportYear年$reportMonth月';

  String get linkTapRateLabel {
    if (linkTapRate == null) return '—';
    final v = linkTapRate!;
    final s =
        v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '$s%';
  }
}

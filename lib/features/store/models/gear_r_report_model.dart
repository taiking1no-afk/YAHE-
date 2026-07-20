class GearRMonthlyReport {
  final String reportId;
  final int reportYear;
  final int reportMonth;
  final int encounters;
  final int profileViews;
  final int likesReceived;
  final int likesSent;
  final int matches;
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
    required this.generatedAt,
    this.pushSentAt,
  });

  factory GearRMonthlyReport.fromJson(Map<String, dynamic> json) {
    return GearRMonthlyReport(
      reportId: json['report_id'] as String,
      reportYear: json['report_year'] as int,
      reportMonth: json['report_month'] as int,
      encounters: (json['encounters'] as num?)?.toInt() ?? 0,
      profileViews: (json['profile_views'] as num?)?.toInt() ?? 0,
      likesReceived: (json['likes_received'] as num?)?.toInt() ?? 0,
      likesSent: (json['likes_sent'] as num?)?.toInt() ?? 0,
      matches: (json['matches'] as num?)?.toInt() ?? 0,
      generatedAt: DateTime.parse(json['generated_at'] as String).toLocal(),
      pushSentAt: json['push_sent_at'] != null
          ? DateTime.tryParse(json['push_sent_at'] as String)?.toLocal()
          : null,
    );
  }

  String get periodLabel => '$reportYear年$reportMonth月';
}

/// 累計/本日のヤエー（すれ違い）人数
class EncounterStats {
  final int totalPeople;
  final int todayPeople;

  const EncounterStats({
    required this.totalPeople,
    required this.todayPeople,
  });

  static const zero = EncounterStats(totalPeople: 0, todayPeople: 0);

  factory EncounterStats.fromJson(Map<String, dynamic> json) => EncounterStats(
        totalPeople: (json['total_people'] as num?)?.toInt() ?? 0,
        todayPeople: (json['today_people'] as num?)?.toInt() ?? 0,
      );
}

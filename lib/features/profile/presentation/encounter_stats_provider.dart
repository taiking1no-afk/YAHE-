import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/models/encounter_stats.dart';
import '../data/user_repository.dart';

/// 指定ユーザーの累計/本日のヤエー人数（自分・他ユーザーどちらでも利用可）
final encounterStatsProvider =
    FutureProvider.family<EncounterStats, String>((ref, userId) async {
  return UserRepository().fetchEncounterStats(userId);
});

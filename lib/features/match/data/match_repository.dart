import '../../../core/supabase/supabase_config.dart';
import '../models/match_model.dart';
import '../../vehicle/models/vehicle.dart';
import '../../../shared/models/user_model.dart';

class MatchRepository {
  final _client = SupabaseConfig.client;

  Future<List<MatchModel>> fetchMatches(String userId) async {
    final rows = await _client
        .from('matches')
        .select()
        .or('user_a_id.eq.$userId,user_b_id.eq.$userId')
        .order('matched_at', ascending: false);

    // ブロック中の相手はマッチ一覧に出さない（解除すれば再表示される）
    final blockedIds = await _fetchBlockedIds(userId);

    final visibleRows = rows.where((row) {
      final match = MatchModel.fromJson(row);
      final otherUserId = match.userAId == userId ? match.userBId : match.userAId;
      return !blockedIds.contains(otherUserId);
    });

    // 各行の相手情報・SNS・車両の取得を並列化（直列の N+1 だと件数に比例して
    // 遅くなり、マッチ一覧の初期表示が数秒かかっていた）
    final matches = await Future.wait(visibleRows.map((row) async {
      final match = MatchModel.fromJson(row);
      final otherUserId = match.userAId == userId ? match.userBId : match.userAId;

      Map<String, dynamic>? userData;
      List<SnsLink> snsLinks = const [];
      List<Vehicle> vehicles = [];
      try {
        final fetched = await Future.wait([
          // 相手情報を取得（マッチング後に開示）
          _client.from('users').select().eq('user_id', otherUserId).maybeSingle(),
          // SNSリンクは専用テーブルから取得（マッチ済みのみRLSで許可される）
          _client.from('user_sns_links').select('links').eq('user_id', otherUserId).maybeSingle(),
          _client
              .from('vehicles')
              .select()
              .eq('user_id', otherUserId)
              .eq('is_active', true)
              .order('created_at', ascending: true),
        ]);

        userData = fetched[0] as Map<String, dynamic>?;

        final snsRow = fetched[1] as Map<String, dynamic>?;
        snsLinks = (snsRow?['links'] as List<dynamic>? ?? [])
            .map((e) => SnsLink.fromJson(e as Map<String, dynamic>))
            .toList();

        vehicles = (fetched[2] as List)
            .map((v) => Vehicle.fromJson(v as Map<String, dynamic>))
            .toList();
      } catch (_) {}

      return MatchModel(
        matchId: match.matchId,
        userAId: match.userAId,
        userBId: match.userBId,
        matchedAt: match.matchedAt,
        otherUser: userData != null
            ? UserModel.fromJson(userData).copyWith(snsLinks: snsLinks)
            : null,
        otherVehicle: vehicles.firstOrNull,
        otherVehicles: vehicles,
      );
    }));

    // 通報により停止された相手はマッチ一覧に出さない
    return matches.where((m) => !(m.otherUser?.isSuspended ?? false)).toList();
  }

  Future<Set<String>> _fetchBlockedIds(String userId) async {
    try {
      final rows = await _client
          .from('blocks')
          .select('blocker_id, blocked_id')
          .or('blocker_id.eq.$userId,blocked_id.eq.$userId');
      final ids = <String>{};
      for (final r in rows as List) {
        final blocker = r['blocker_id'] as String;
        final blocked = r['blocked_id'] as String;
        ids.add(blocker == userId ? blocked : blocker);
      }
      return ids;
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> deleteMatch(String matchId) async {
    await _client.from('matches').delete().eq('match_id', matchId);
  }
}

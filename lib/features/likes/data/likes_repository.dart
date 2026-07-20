import '../../../core/supabase/supabase_config.dart';
import '../../../shared/models/user_model.dart';
import '../../vehicle/models/vehicle.dart';
import '../models/like_entry.dart';

class LikesRepository {
  final _client = SupabaseConfig.client;

  /// 自分がいいねした相手リスト
  Future<List<LikeEntry>> fetchSentLikes(String userId) async {
    final rows = await _client
        .from('likes')
        .select('like_id, encounter_id, to_user_id, created_at')
        .eq('from_user_id', userId)
        .order('created_at', ascending: false);

    return _buildEntries(rows, userId, isSent: true);
  }

  /// 送信済みのいいねを取り消す（マッチ前のみ想定。matches は別テーブルなので影響しない）
  Future<void> cancelLike(String likeId) async {
    await _client.from('likes').delete().eq('like_id', likeId);
  }

  /// 自分にいいねしてきた相手リスト（まだマッチしていない）
  Future<List<LikeEntry>> fetchReceivedLikes(String userId) async {
    final rows = await _client
        .from('likes')
        .select('like_id, encounter_id, from_user_id, created_at')
        .eq('to_user_id', userId)
        .order('created_at', ascending: false);

    return _buildEntries(rows, userId, isSent: false);
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

  Future<List<LikeEntry>> _buildEntries(
    List<dynamic> rows,
    String myUserId, {
    required bool isSent,
  }) async {
    // ブロック中の相手はリストから除外（解除すれば再表示される）
    final blockedIds = await _fetchBlockedIds(myUserId);
    final visibleRows = rows.where((row) {
      final otherId = isSent
          ? row['to_user_id'] as String
          : row['from_user_id'] as String;
      return !blockedIds.contains(otherId);
    });

    // 各エントリの補助情報取得を並列化（直列の N+1 だと件数に比例して遅くなり、
    // 「いいねした」一覧の反映が数秒かかっていた）。
    final futures = visibleRows.map((row) => _buildEntry(row, myUserId, isSent: isSent));
    final entries = await Future.wait(futures);
    // 通報により停止された相手は一覧から除外
    return entries
        .where((e) => !(e.otherUser?.isSuspended ?? false))
        .toList();
  }

  Future<LikeEntry> _buildEntry(
    dynamic row,
    String myUserId, {
    required bool isSent,
  }) async {
    final otherUserId =
        isSent ? row['to_user_id'] as String : row['from_user_id'] as String;

    final m1 = myUserId.compareTo(otherUserId) < 0 ? myUserId : otherUserId;
    final m2 = myUserId.compareTo(otherUserId) < 0 ? otherUserId : myUserId;

    // 相手のユーザー・車両・マッチ判定・SNSを同時に取得
    // SNS は RLS で開示可能な場合のみ返る（鍵なし相手へいいね済み or マッチ済み）
    final results = await Future.wait([
      _client.from('users').select().eq('user_id', otherUserId).maybeSingle(),
      _client
          .from('vehicles')
          .select()
          .eq('user_id', otherUserId)
          .eq('is_active', true)
          .order('created_at', ascending: true),
      _client
          .from('matches')
          .select('match_id')
          .eq('user_a_id', m1)
          .eq('user_b_id', m2)
          .maybeSingle(),
      _client
          .from('user_sns_links')
          .select('links')
          .eq('user_id', otherUserId)
          .maybeSingle(),
    ]);

    UserModel? otherUser;
    final uData = results[0] as Map<String, dynamic>?;
    if (uData != null) {
      final snsRow = results[3] as Map<String, dynamic>?;
      final snsList = (snsRow?['links'] as List<dynamic>? ?? [])
          .map((e) => SnsLink.fromJson(e as Map<String, dynamic>))
          .toList();
      otherUser = UserModel.fromJson(uData).copyWith(snsLinks: snsList);
    }

    final vehicles = (results[1] as List)
        .map((v) => Vehicle.fromJson(v as Map<String, dynamic>))
        .toList();

    final isMatched = (results[2] as Map<String, dynamic>?) != null;

    return LikeEntry(
      likeId: row['like_id'] as String,
      encounterId: row['encounter_id'] as String,
      otherUserId: otherUserId,
      otherUser: otherUser,
      otherVehicle: vehicles.firstOrNull,
      otherVehicles: vehicles,
      createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
      isMatched: isMatched,
    );
  }
}

import '../../../core/supabase/supabase_config.dart';
import '../../../shared/models/user_model.dart';
import '../../store/data/store_repository.dart';
import '../../vehicle/models/vehicle.dart';
import '../models/like_entry.dart';

class LikesRepository {
  final _client = SupabaseConfig.client;
  final _storeRepo = StoreRepository();

  /// 自分がいいねした相手リスト
  Future<List<LikeEntry>> fetchSentLikes(String userId) async {
    final rows = await _client
        .from('likes')
        .select('like_id, encounter_id, to_user_id, created_at, boost_type')
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
        .select(
            'like_id, encounter_id, from_user_id, created_at, seen_at, boost_type')
        .eq('to_user_id', userId)
        .order('created_at', ascending: false);

    return _buildEntries(rows, userId, isSent: false);
  }

  /// いいね受信ポップアップを表示済みにする（受信者本人のみ）。
  Future<void> markSeen(String likeId) async {
    await _client.rpc('mark_like_seen', params: {'p_like_id': likeId});
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
      final otherId =
          isSent ? row['to_user_id'] as String : row['from_user_id'] as String;
      return !blockedIds.contains(otherId);
    });

    // 各エントリの補助情報取得を並列化（直列の N+1 だと件数に比例して遅くなり、
    // 「いいねした」一覧の反映が数秒かかっていた）。
    final futures =
        visibleRows.map((row) => _buildEntry(row, myUserId, isSent: isSent));
    final entries = await Future.wait(futures);
    // 通報により停止された相手は一覧から除外
    final filtered =
        entries.where((e) => !(e.otherUser?.isSuspended ?? false)).toList();

    // 同一相手への複数 encounter いいねは最新1件にまとめる（別日でも1行で表示）
    final byUser = <String, LikeEntry>{};
    for (final e in filtered) {
      final prev = byUser[e.otherUserId];
      if (prev == null || e.createdAt.isAfter(prev.createdAt)) {
        byUser[e.otherUserId] = e;
      }
    }
    final deduped = byUser.values.toList();

    // 受信いいねは渋！ブーストで上位表示 / 送信は新しい順
    if (!isSent) {
      final ids = deduped.map((e) => e.otherUserId).toList();
      final boosts = await _storeRepo.fetchBoostRanks(ids);
      // このいいね自体に渋！/激渋！が使われている場合（相手を指定したブースト）は、
      // 送信者の一括ブースト（fetchBoostRanks）より優先して上位表示する。
      int score(LikeEntry e) {
        final targeted = switch (e.boostType) {
          'geki_shibu' => 20,
          'shibu' => 10,
          _ => 0,
        };
        return targeted + (boosts[e.otherUserId] ?? 0);
      }

      deduped.sort((a, b) {
        final sa = score(a);
        final sb = score(b);
        if (sa != sb) return sb.compareTo(sa);
        return b.createdAt.compareTo(a.createdAt);
      });
    } else {
      deduped.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return deduped;
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

    // 相手のユーザー・車両・マッチ判定を同時に取得
    // SNSは自動開示しない（チャットで本人が能動的に送る方式に統一）
    final results = await Future.wait([
      _client
          .from('users')
          .select(
              'user_id, auth_id, nickname, area, comment, avatar_url, anonymous_mode, plan, trial_ends_at, gear_plus_trial_used_at, premium_override_plan, premium_override_expires_at, premium_override_source, is_verified, verified_label, is_private, birth_date, terms_agreed_at, is_suspended, passing_target, encounter_test_mode, avatar_focal_x, avatar_focal_y, created_at')
          .eq('user_id', otherUserId)
          .maybeSingle(),
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
    ]);

    UserModel? otherUser;
    final uData = results[0] as Map<String, dynamic>?;
    if (uData != null) {
      otherUser = UserModel.fromJson(uData);
    }

    final vehicles = (results[1] as List)
        .map((v) => Vehicle.fromJson(v as Map<String, dynamic>))
        .toList();

    final isMatched = (results[2] as Map<String, dynamic>?) != null;

    return LikeEntry(
      likeId: row['like_id'] as String,
      encounterId: row['encounter_id'] as String?,
      otherUserId: otherUserId,
      otherUser: otherUser,
      otherVehicle: vehicles.firstOrNull,
      otherVehicles: vehicles,
      createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
      isMatched: isMatched,
      seenAt: row['seen_at'] != null
          ? DateTime.parse(row['seen_at'] as String).toLocal()
          : null,
      boostType: row['boost_type'] as String?,
    );
  }
}

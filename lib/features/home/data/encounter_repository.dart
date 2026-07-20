import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/supabase/supabase_config.dart';
import '../../../core/encounter/encounter_dedupe.dart';
import '../../../shared/models/user_model.dart';
import '../models/encounter.dart';
import '../../vehicle/models/vehicle.dart';

class EncounterRepository {
  final _client = SupabaseConfig.client;

  Future<List<Encounter>> fetchEncounters(String userId) async {
    final now = DateTime.now().toUtc().toIso8601String();

    // encounters + likes を取得（matches は FK がないので別クエリ）
    final rows = await _client
        .from('encounters')
        .select('''
          encounter_id, user_a_id, user_b_id, time, expires_at, occurrence_number,
          likes!left(from_user_id, to_user_id)
        ''')
        .or('user_a_id.eq.$userId,user_b_id.eq.$userId')
        .gt('expires_at', now)
        .order('time', ascending: false);

    // マッチ済みの相手IDセットを先に取得
    final matchRows = await _client
        .from('matches')
        .select('user_a_id, user_b_id')
        .or('user_a_id.eq.$userId,user_b_id.eq.$userId');

    final matchedPartnerIds = <String>{};
    for (final m in matchRows as List) {
      final aId = m['user_a_id'] as String;
      final bId = m['user_b_id'] as String;
      matchedPartnerIds.add(aId == userId ? bId : aId);
    }

    // ブロック中の相手はタイムラインに出さない（双方向）
    final blockedIds = await _fetchBlockedIds(userId);
    final visibleRows = rows.where((row) {
      final userAId = row['user_a_id'] as String;
      final userBId = row['user_b_id'] as String;
      final otherUserId = userAId == userId ? userBId : userAId;
      return !blockedIds.contains(otherUserId);
    });

    // 各行の相手ユーザー・車両情報の取得を並列化（直列の N+1 だと件数に比例して
    // 遅くなり、ホームタイムラインの初期表示が数秒かかっていた）
    final encounters = await Future.wait(visibleRows.map((row) async {
      final encounterId = row['encounter_id'] as String;
      final userAId = row['user_a_id'] as String;
      final userBId = row['user_b_id'] as String;
      final otherUserId = userAId == userId ? userBId : userAId;

      // いいね状態確認
      final likes = row['likes'] as List? ?? [];
      final iLiked = likes.any((l) =>
          l['from_user_id'] == userId && l['to_user_id'] == otherUserId);

      // マッチング状態確認
      final isMatched = matchedPartnerIds.contains(otherUserId);

      // 相手のユーザー情報・全車両を同時に取得
      UserModel? otherUser;
      List<Vehicle> otherVehicles = [];
      try {
        final fetched = await Future.wait([
          _client.from('users').select().eq('user_id', otherUserId).maybeSingle(),
          _client
              .from('vehicles')
              .select()
              .eq('user_id', otherUserId)
              .eq('is_active', true)
              .order('created_at', ascending: true),
        ]);

        final userData = fetched[0] as Map<String, dynamic>?;
        if (userData != null) {
          otherUser = UserModel.fromJson(userData);
        }

        otherVehicles = (fetched[1] as List)
            .map((v) => Vehicle.fromJson(v as Map<String, dynamic>))
            .toList();
      } catch (_) {}

      return Encounter(
        encounterId: encounterId,
        userAId: userAId,
        userBId: userBId,
        time: DateTime.parse(row['time'] as String).toLocal(),
        expiresAt: DateTime.parse(row['expires_at'] as String).toLocal(),
        otherUser: otherUser,
        otherVehicle: otherVehicles.firstOrNull,
        otherVehicles: otherVehicles,
        otherUserId: otherUserId,
        iLiked: iLiked,
        isMatched: isMatched,
        occurrenceNumber: (row['occurrence_number'] as int?) ?? 1,
      );
    }));

    // 通報により停止された相手はタイムラインに出さない
    return encounters.where((e) => !(e.otherUser?.isSuspended ?? false)).toList();
  }

  /// ブロック関係にある相手の user_id 集合（双方向）
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

  // すれ違い登録（サーバー RPC 経由。本人確認・重複防止は DB 側）
  Future<void> registerEncounter({
    required String userAId,
    required String userBId,
    required bool aIsPremium,
    required bool bIsPremium,
  }) async {
    final authUser = _client.auth.currentUser;
    if (authUser == null) return;

    final me = await _client
        .from('users')
        .select('user_id')
        .eq('auth_id', authUser.id)
        .maybeSingle();
    final myUserId = me?['user_id'] as String?;
    if (myUserId == null) return;

    final otherUserId = myUserId == userAId ? userBId : userAId;
    if (otherUserId == myUserId) return;

    await _client.rpc('register_encounter', params: {
      'p_other_user_id': otherUserId,
      'p_test_mode': EncounterTestMode.sendTestModeToServer,
    });
  }

  // 複数人分のすれ違いを1回のRPCでまとめて登録する（集会など同時多発検知時の負荷対策）
  Future<void> registerEncounters({
    required String userAId,
    required List<String> otherUserIds,
    required bool aIsPremium,
  }) async {
    if (otherUserIds.isEmpty) return;
    final authUser = _client.auth.currentUser;
    if (authUser == null) return;

    await _client.rpc('register_encounters_batch', params: {
      'p_other_user_ids': otherUserIds,
      'p_test_mode': EncounterTestMode.sendTestModeToServer,
    });
  }

  // migration_v1_5_debug_user.sql で作成した固定テストパートナーID
  static const _debugPartnerId = '00000000-0000-0000-0000-000000000002';

  /// デバッグ用：テストすれ違いを挿入する
  /// partnerUserId を省略するとビルトインのテストユーザーを使用する
  /// （事前に migration_v1_5_debug_user.sql を Supabase で実行しておくこと）
  Future<void> debugInsertTestEncounters({
    required String myUserId,
    String? partnerUserId,
  }) async {
    final partner = (partnerUserId != null &&
            partnerUserId.isNotEmpty &&
            partnerUserId != myUserId)
        ? partnerUserId
        : _debugPartnerId;

    for (int i = 0; i < 3; i++) {
      await _client.rpc('debug_seed_encounters', params: {
        'p_partner_user_id': partner,
        'p_hours_ago': 2 - i,
      });
    }
  }

  Future<Map<String, dynamic>> sendLike({
    required String fromUserId,
    required String toUserId,
    required String encounterId,
  }) async {
    final result = await _client.rpc('send_like', params: {
      'p_from_user_id': fromUserId,
      'p_to_user_id': toUserId,
      'p_encounter_id': encounterId,
    }) as Map<String, dynamic>;

    if (result['success'] == true) {
      // 相手へのプッシュ通知（失敗してもいいね自体は成立しているので握りつぶす）
      _client.functions.invoke('send-like-notification', body: {
        'to_user_id': toUserId,
        'is_matched': result['is_matched'] == true,
      }).then((_) {}).catchError((_) {});
    }

    return result;
  }
}

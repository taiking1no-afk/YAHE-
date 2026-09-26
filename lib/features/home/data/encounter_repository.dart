import '../../../core/constants/app_constants.dart';
import '../../../core/supabase/supabase_config.dart';
import '../../../core/encounter/encounter_dedupe.dart';
import '../../../shared/models/user_model.dart';
import '../../store/data/store_repository.dart';
import '../models/encounter.dart';
import '../../vehicle/models/vehicle.dart';

class EncounterRepository {
  final _client = SupabaseConfig.client;
  final _storeRepo = StoreRepository();

  /// [viewerIsPremium] が false の場合:
  /// - 時刻から24時間超の履歴を隠す
  /// - 表示期限もすれ違いから24時間に揃える
  /// （DB の expires_at はどちらかが premium なら7日保持のため、無料閲覧者向けにクランプ）
  Future<List<Encounter>> fetchEncounters(
    String userId, {
    bool viewerIsPremium = false,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();

    // encounters・matches・ブロック一覧は互いに依存しないため並列取得する
    // （直列だとラウンドトリップ3回分の遅延がそのまま起動時間に乗っていた）。
    final results = await Future.wait<dynamic>([
      _client
          .from('encounters')
          .select('''
          encounter_id, user_a_id, user_b_id, time, expires_at, occurrence_number,
          likes!left(from_user_id, to_user_id)
        ''')
          .or('user_a_id.eq.$userId,user_b_id.eq.$userId')
          .gt('expires_at', now)
          .order('time', ascending: false),
      _client
          .from('matches')
          .select('user_a_id, user_b_id')
          .or('user_a_id.eq.$userId,user_b_id.eq.$userId'),
      _fetchBlockedIds(userId),
    ]);

    final rows = results[0] as List;
    final matchRows = results[1] as List;
    final blockedIds = results[2] as Set<String>;

    final matchedPartnerIds = <String>{};
    for (final m in matchRows) {
      final aId = m['user_a_id'] as String;
      final bId = m['user_b_id'] as String;
      matchedPartnerIds.add(aId == userId ? bId : aId);
    }

    final freeCutoff =
        DateTime.now().subtract(AppConstants.freeEncounterExpiry);

    final visibleRows = rows.where((row) {
      final userAId = row['user_a_id'] as String;
      final userBId = row['user_b_id'] as String;
      final otherUserId = userAId == userId ? userBId : userAId;
      if (blockedIds.contains(otherUserId)) return false;
      if (!viewerIsPremium) {
        final time = DateTime.parse(row['time'] as String).toLocal();
        if (time.isBefore(freeCutoff)) return false;
      }
      return true;
    });

    // 相手ユーザー・車両情報は行ごとに個別リクエストせず、まとめてIN一括取得する。
    // （すれ違い件数が多い実機では、行ごとの個別リクエストが数十本の並列HTTP
    //   リクエストになり、体感の起動時間の遅さの主因になっていたため）
    final encounterOtherIds = visibleRows
        .map((row) {
          final userAId = row['user_a_id'] as String;
          final userBId = row['user_b_id'] as String;
          return userAId == userId ? userBId : userAId;
        })
        .toSet()
        .toList();

    final usersById = <String, UserModel>{};
    final vehiclesById = <String, List<Vehicle>>{};
    if (encounterOtherIds.isNotEmpty) {
      // SNSは自動開示しない（チャットで本人が能動的に送る方式に統一）
      final fetched = await Future.wait([
        _client
            .from('users')
            .select(
                'user_id, auth_id, nickname, area, comment, avatar_url, anonymous_mode, plan, trial_ends_at, gear_plus_trial_used_at, premium_override_plan, premium_override_expires_at, premium_override_source, is_verified, verified_label, is_private, birth_date, terms_agreed_at, is_suspended, passing_target, encounter_test_mode, avatar_focal_x, avatar_focal_y, created_at')
            .inFilter('user_id', encounterOtherIds),
        _client
            .from('vehicles')
            .select()
            .inFilter('user_id', encounterOtherIds)
            .eq('is_active', true)
            .order('created_at', ascending: true),
      ]);
      for (final u in fetched[0] as List) {
        final model = UserModel.fromJson(u as Map<String, dynamic>);
        usersById[model.userId] = model;
      }
      for (final v in fetched[1] as List) {
        final vehicle = Vehicle.fromJson(v as Map<String, dynamic>);
        vehiclesById.putIfAbsent(vehicle.userId, () => []).add(vehicle);
      }
    }

    final encounters = visibleRows.map((row) {
      final encounterId = row['encounter_id'] as String;
      final userAId = row['user_a_id'] as String;
      final userBId = row['user_b_id'] as String;
      final otherUserId = userAId == userId ? userBId : userAId;

      final likes = row['likes'] as List? ?? [];
      final iLiked = likes.any(
          (l) => l['from_user_id'] == userId && l['to_user_id'] == otherUserId);

      final isMatched = matchedPartnerIds.contains(otherUserId);

      final otherUser = usersById[otherUserId];
      final otherVehicles = vehiclesById[otherUserId] ?? const <Vehicle>[];

      final time = DateTime.parse(row['time'] as String).toLocal();
      final dbExpiresAt = DateTime.parse(row['expires_at'] as String).toLocal();
      // 無料閲覧者の表示期限はすれ違いから24時間（DB は相手が有料だと7日保持のため）
      final expiresAt = viewerIsPremium
          ? dbExpiresAt
          : _earlier(
              dbExpiresAt,
              time.add(AppConstants.freeEncounterExpiry),
            );

      return Encounter(
        encounterId: encounterId,
        userAId: userAId,
        userBId: userBId,
        time: time,
        expiresAt: expiresAt,
        otherUser: otherUser,
        otherVehicle: otherVehicles.firstOrNull,
        otherVehicles: otherVehicles,
        otherUserId: otherUserId,
        iLiked: iLiked,
        isMatched: isMatched,
        occurrenceNumber: (row['occurrence_number'] as int?) ?? 1,
      );
    }).toList();

    final active =
        encounters.where((e) => !(e.otherUser?.isSuspended ?? false)).toList();

    // ニトロ系ブーストでソート（同順位は時刻降順のまま）
    final otherIds =
        active.map((e) => e.otherUserId).whereType<String>().toList();
    final boosts = await _storeRepo.fetchBoostRanks(otherIds);
    active.sort((a, b) {
      final ra = boosts[a.otherUserId] ?? 0;
      final rb = boosts[b.otherUserId] ?? 0;
      if (ra != rb) return rb.compareTo(ra);
      return b.time.compareTo(a.time);
    });

    return active;
  }

  /// 無料プランの1日いいね上限（AppConstants.freeDailyLikeLimit）に対する
  /// 本日の送信済み件数。today_like_counts はJST日次集計のビュー。
  Future<int> fetchTodayLikeCount(String userId) async {
    try {
      final row = await _client
          .from('today_like_counts')
          .select('like_count')
          .eq('from_user_id', userId)
          .maybeSingle();
      return (row?['like_count'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static DateTime _earlier(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

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
  // 戻り値: 実際に新規登録できた相手のuser_id一覧。
  // ブロック済み・愛車未登録（users_can_pass）・重複防止期間内などの理由で
  // 実際には登録されなかった相手は、例外を投げずに単に含まれない。
  // 呼び出し側はこの戻り値だけを見て通知等を送る（例外なし＝成功、
  // ではない点に注意）。
  Future<List<String>> registerEncounters({
    required String userAId,
    required List<String> otherUserIds,
    required bool aIsPremium,
  }) async {
    if (otherUserIds.isEmpty) return const [];
    final authUser = _client.auth.currentUser;
    if (authUser == null) return const [];

    final result = await _client.rpc('register_encounters_batch', params: {
      'p_other_user_ids': otherUserIds,
      'p_test_mode': EncounterTestMode.sendTestModeToServer,
    });
    return (result as List).map((e) => e as String).toList();
  }

  // migration_v1_5_debug_user.sql で作成した固定テストパートナーID
  static const _debugPartnerId = '00000000-0000-0000-0000-000000000002';

  /// デバッグ用：テストすれ違いを挿入する
  ///
  /// v1.28 以降、`debug_seed_encounters` は authenticated から実行不可。
  /// 本番セキュリティのためアプリ長押しでは失敗する（意図どおり）。
  /// 手動シードは `supabase/admin_seed_test_encounters.sql` を SQL Editor で実行する。
  Future<void> debugInsertTestEncounters({
    required String myUserId,
    String? partnerUserId,
  }) async {
    final partner = (partnerUserId != null &&
            partnerUserId.isNotEmpty &&
            partnerUserId != myUserId)
        ? partnerUserId
        : _debugPartnerId;

    try {
      for (int i = 0; i < 3; i++) {
        await _client.rpc('debug_seed_encounters', params: {
          'p_partner_user_id': partner,
          'p_hours_ago': 2 - i,
        });
      }
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('42501') ||
          msg.contains('permission denied') ||
          msg.contains('debug_seed_encounters')) {
        throw Exception(
          'アプリからのテスト挿入は無効です（v1.28）。'
          'Supabase SQL Editor で admin_seed_test_encounters.sql を実行してください。'
          'あなたの user_id: $myUserId',
        );
      }
      rethrow;
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
      _client.functions
          .invoke('send-like-notification', body: {
            'to_user_id': toUserId,
            'is_matched': result['is_matched'] == true,
          })
          .then((_) {})
          .catchError((_) {});
    }

    return result;
  }

  /// グループ・掲示板で出会った（すれ違い実績のない）相手への「いいね」。
  Future<Map<String, dynamic>> sendLikeNoEncounter({
    required String fromUserId,
    required String toUserId,
  }) async {
    final result = await _client.rpc('send_like_no_encounter', params: {
      'p_from_user_id': fromUserId,
      'p_to_user_id': toUserId,
    }) as Map<String, dynamic>;

    if (result['success'] == true) {
      _client.functions
          .invoke('send-like-notification', body: {
            'to_user_id': toUserId,
            'is_matched': result['is_matched'] == true,
          })
          .then((_) {})
          .catchError((_) {});
    }

    return result;
  }
}

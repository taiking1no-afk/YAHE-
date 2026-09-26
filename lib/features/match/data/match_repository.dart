import '../../../core/supabase/supabase_config.dart';
import '../models/match_model.dart';
import '../../vehicle/models/vehicle.dart';
import '../../../shared/models/user_model.dart';
import '../../../shared/utils/network_timeout.dart';

class MatchRepository {
  final _client = SupabaseConfig.client;

  // UserModel.fromJson が参照するカラムのみ（fcm_token 等の非公開/未使用カラムを除外）
  static const _userColumns =
      'user_id, auth_id, nickname, area, comment, avatar_url, anonymous_mode, plan, trial_ends_at, gear_plus_trial_used_at, premium_override_plan, premium_override_expires_at, premium_override_source, is_verified, verified_label, is_private, birth_date, terms_agreed_at, is_suspended, passing_target, encounter_test_mode, avatar_focal_x, avatar_focal_y, created_at';

  Future<List<MatchModel>> fetchMatches(String userId) async {
    final rows = await _client
        .from('matches')
        .select()
        .or('user_a_id.eq.$userId,user_b_id.eq.$userId')
        .filter('dissolved_at', 'is', null)
        .order('matched_at', ascending: false)
        .withNetworkTimeout();

    // ブロック中の相手はマッチ一覧に出さない（解除すれば再表示される）
    final blockedIds = await _fetchBlockedIds(userId);

    final visibleRows = rows.where((row) {
      final match = MatchModel.fromJson(row);
      final otherUserId =
          match.userAId == userId ? match.userBId : match.userAId;
      return !blockedIds.contains(otherUserId);
    });

    // 各行の相手情報・SNS・車両の取得を並列化（直列の N+1 だと件数に比例して
    // 遅くなり、マッチ一覧の初期表示が数秒かかっていた）
    final matches = await Future.wait(visibleRows.map((row) async {
      final match = MatchModel.fromJson(row);
      final otherUserId =
          match.userAId == userId ? match.userBId : match.userAId;

      // SNSリンクは本人が「マッチ相手に表示する」を有効にしている場合のみ
      // user_sns_linksのRLSがこのSELECTを許可する（v1.90）。無効な場合は
      // 単に0件が返るだけで、明示的な分岐は不要。
      Map<String, dynamic>? userData;
      List<Vehicle> vehicles = [];
      List<SnsLink> otherSnsLinks = const [];
      // 通信失敗で相手情報が取れなかった場合と、行自体が本当に存在しない
      // 場合を区別する。前者を"otherUser: null"のまま一覧に混ぜると、
      // 名前・写真が空白の壊れたカードとして表示されてしまうため、
      // 失敗した行は今回の一覧からは除外する（次回再取得時に復活する）。
      var fetchFailed = false;
      try {
        final fetched = await Future.wait([
          // 相手情報を取得（マッチング後に開示）
          _client
              .from('users')
              .select(_userColumns)
              .eq('user_id', otherUserId)
              .maybeSingle(),
          _client
              .from('vehicles')
              .select()
              .eq('user_id', otherUserId)
              .eq('is_active', true)
              .order('created_at', ascending: true),
          _client
              .from('user_sns_links')
              .select('links')
              .eq('user_id', otherUserId)
              .maybeSingle(),
        ]);

        userData = fetched[0] as Map<String, dynamic>?;

        vehicles = (fetched[1] as List)
            .map((v) => Vehicle.fromJson(v as Map<String, dynamic>))
            .toList();

        final snsRow = fetched[2] as Map<String, dynamic>?;
        final snsList = (snsRow?['links'] as List<dynamic>? ?? []);
        otherSnsLinks = snsList
            .map((e) => SnsLink.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        fetchFailed = true;
      }

      if (fetchFailed) return null;

      return match.copyWith(
        otherUser: userData != null
            ? UserModel.fromJson(userData).copyWith(snsLinks: otherSnsLinks)
            : null,
        otherVehicle: vehicles.firstOrNull,
        otherVehicles: vehicles,
      );
    }));

    // 通信失敗で相手情報が取れなかった行(null)と、通報により停止された相手を除外
    return matches
        .whereType<MatchModel>()
        .where((m) => !(m.otherUser?.isSuspended ?? false))
        .toList();
  }

  /// 単一マッチを相手情報・車両付きで取得する（チャット画面からのプロフィール遷移用）。
  Future<MatchModel?> fetchMatch(String matchId, String myUserId) async {
    final row = await _client
        .from('matches')
        .select()
        .eq('match_id', matchId)
        .maybeSingle();
    if (row == null) return null;
    final match = MatchModel.fromJson(row);
    final otherUserId =
        match.userAId == myUserId ? match.userBId : match.userAId;

    Map<String, dynamic>? userData;
    List<Vehicle> vehicles = [];
    List<SnsLink> otherSnsLinks = const [];
    try {
      final fetched = await Future.wait([
        _client
            .from('users')
            .select(_userColumns)
            .eq('user_id', otherUserId)
            .maybeSingle(),
        _client
            .from('vehicles')
            .select()
            .eq('user_id', otherUserId)
            .eq('is_active', true)
            .order('created_at', ascending: true),
        _client
            .from('user_sns_links')
            .select('links')
            .eq('user_id', otherUserId)
            .maybeSingle(),
      ]);
      userData = fetched[0] as Map<String, dynamic>?;
      vehicles = (fetched[1] as List)
          .map((v) => Vehicle.fromJson(v as Map<String, dynamic>))
          .toList();
      final snsRow = fetched[2] as Map<String, dynamic>?;
      final snsList = (snsRow?['links'] as List<dynamic>? ?? []);
      otherSnsLinks = snsList
          .map((e) => SnsLink.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}

    return match.copyWith(
      otherUser: userData != null
          ? UserModel.fromJson(userData).copyWith(snsLinks: otherSnsLinks)
          : null,
      otherVehicle: vehicles.firstOrNull,
      otherVehicles: vehicles,
    );
  }

  /// 相手のuser_idからマッチを特定して相手情報・車両付きで取得する
  /// （YAHE/すれ違い画面から、既にマッチ済みの相手の詳細プロフィールへ遷移する用）。
  Future<MatchModel?> fetchMatchByOtherUserId(
      String myUserId, String otherUserId) async {
    final row = await _client
        .from('matches')
        .select()
        .or(
          'and(user_a_id.eq.$myUserId,user_b_id.eq.$otherUserId),and(user_a_id.eq.$otherUserId,user_b_id.eq.$myUserId)',
        )
        .maybeSingle();
    if (row == null) return null;
    final match = MatchModel.fromJson(row);

    Map<String, dynamic>? userData;
    List<Vehicle> vehicles = [];
    List<SnsLink> otherSnsLinks = const [];
    try {
      final fetched = await Future.wait([
        _client
            .from('users')
            .select(_userColumns)
            .eq('user_id', otherUserId)
            .maybeSingle(),
        _client
            .from('vehicles')
            .select()
            .eq('user_id', otherUserId)
            .eq('is_active', true)
            .order('created_at', ascending: true),
        _client
            .from('user_sns_links')
            .select('links')
            .eq('user_id', otherUserId)
            .maybeSingle(),
      ]);
      userData = fetched[0] as Map<String, dynamic>?;
      vehicles = (fetched[1] as List)
          .map((v) => Vehicle.fromJson(v as Map<String, dynamic>))
          .toList();
      final snsRow = fetched[2] as Map<String, dynamic>?;
      final snsList = (snsRow?['links'] as List<dynamic>? ?? []);
      otherSnsLinks = snsList
          .map((e) => SnsLink.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}

    return match.copyWith(
      otherUser: userData != null
          ? UserModel.fromJson(userData).copyWith(snsLinks: otherSnsLinks)
          : null,
      otherVehicle: vehicles.firstOrNull,
      otherVehicles: vehicles,
    );
  }

  /// マッチのお祝いポップアップを表示済みにする（呼び出し元の側だけ）。
  Future<void> markCelebrated(String matchId) async {
    await _client.rpc('mark_match_celebrated', params: {'p_match_id': matchId});
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

  /// マッチを解除する（ソフトデリート）。チャット履歴は削除されず、
  /// 新規メッセージの送信のみできなくなる。再度相互いいねが成立すれば
  /// 同じ相手と再マッチできる。
  Future<Map<String, dynamic>> dissolveMatch(String matchId) async {
    final result = await _client
        .rpc('dissolve_match', params: {'p_match_id': matchId});
    return Map<String, dynamic>.from(result as Map);
  }
}

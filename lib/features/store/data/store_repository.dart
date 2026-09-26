import 'package:flutter/foundation.dart';
import '../../../core/supabase/supabase_config.dart';
import '../models/gear_r_insights_model.dart';
import '../models/gear_r_report_model.dart';
import '../models/item_model.dart';

class StoreRepository {
  final _client = SupabaseConfig.client;

  Future<List<UserItemState>> fetchMyItems(String userId) async {
    try {
      final rows = await _client
          .from('user_items')
          .select('item_type, quantity, active_until')
          .eq('user_id', userId);
      return rows.map((r) => UserItemState.fromJson(r)).toList();
    } catch (e) {
      debugPrint('[StoreRepo] fetchMyItems: $e');
      return [];
    }
  }

  /// 時限アイテムを1個消費して発動（ニトロ / スーパーニトロ / 24時間ギア＋）
  Future<bool> activateTimedItem(String userId, ItemType type) async {
    try {
      final result = await _client.rpc(
        'activate_timed_item',
        params: {'p_item_type': type.value},
      );
      if (result is Map && result['success'] == true) return true;
      debugPrint('[StoreRepo] activateTimedItem failed: $result');
      return false;
    } catch (e) {
      debugPrint('[StoreRepo] activateTimedItem: $e');
      return false;
    }
  }

  /// 渋！/激渋！ を1個消費してブースト発動
  Future<bool> consumeItem(String userId, ItemType type) async {
    try {
      final result = await _client.rpc(
        'consume_boost_item',
        params: {'p_item_type': type.value},
      );
      if (result is Map && result['success'] == true) return true;
      debugPrint('[StoreRepo] consumeItem failed: $result');
      return false;
    } catch (e) {
      debugPrint('[StoreRepo] consumeItem: $e');
      return false;
    }
  }

  /// 渋！/激渋！を1個消費し、特定の相手へのいいねだけをブースト付きで送る。
  /// 両方所持している場合は激渋！が優先して消費される。
  /// 戻り値: {success, error?, is_matched, match_id?, boost_type}
  Future<Map<String, dynamic>> sendBoostedLike(
    String fromUserId,
    String toUserId,
    String encounterId,
  ) async {
    try {
      final result = await _client.rpc('send_boosted_like', params: {
        'p_from_user_id': fromUserId,
        'p_to_user_id': toUserId,
        'p_encounter_id': encounterId,
      });
      final map = Map<String, dynamic>.from(result as Map);
      if (map['success'] == true) {
        // 相手へのプッシュ通知（失敗してもいいね自体は成立しているので握りつぶす）
        _client.functions
            .invoke('send-like-notification', body: {
              'to_user_id': toUserId,
              'is_matched': map['is_matched'] == true,
            })
            .then((_) {})
            .catchError((_) {});
      }
      return map;
    } catch (e) {
      debugPrint('[StoreRepo] sendBoostedLike: $e');
      return {'success': false, 'error': 'unknown'};
    }
  }

  /// 渋！/激渋！を1個消費し、すれ違い(encounter)を介さない相手（イベント/
  /// グループで出会った未マッチユーザー）へのいいねをブースト付きで送る。
  Future<Map<String, dynamic>> sendBoostedLikeNoEncounter(
    String fromUserId,
    String toUserId,
  ) async {
    try {
      final result =
          await _client.rpc('send_boosted_like_no_encounter', params: {
        'p_from_user_id': fromUserId,
        'p_to_user_id': toUserId,
      });
      final map = Map<String, dynamic>.from(result as Map);
      if (map['success'] == true) {
        _client.functions
            .invoke('send-like-notification', body: {
              'to_user_id': toUserId,
              'is_matched': map['is_matched'] == true,
            })
            .then((_) {})
            .catchError((_) {});
      }
      return map;
    } catch (e) {
      debugPrint('[StoreRepo] sendBoostedLikeNoEncounter: $e');
      return {'success': false, 'error': 'unknown'};
    }
  }

  /// 他ユーザーのアクティブブースト（一覧ソート用）
  Future<Map<String, int>> fetchBoostRanks(List<String> userIds) async {
    if (userIds.isEmpty) return {};
    try {
      final rows = await _client.rpc(
        'get_active_boosts',
        params: {'p_user_ids': userIds},
      );
      final ranks = <String, int>{};
      for (final r in (rows as List)) {
        final uid = r['user_id'] as String;
        final rank = (r['boost_rank'] as num?)?.toInt() ?? 0;
        final prev = ranks[uid] ?? 0;
        if (rank > prev) ranks[uid] = rank;
      }
      return ranks;
    } catch (e) {
      debugPrint('[StoreRepo] fetchBoostRanks: $e');
      return {};
    }
  }

  Future<List<GearRMonthlyReport>> fetchGearRReports(String userId) async {
    try {
      final rows = await _client
          .from('gear_r_monthly_reports')
          .select()
          .eq('user_id', userId)
          .order('report_year', ascending: false)
          .order('report_month', ascending: false)
          .limit(12);
      return (rows as List)
          .map((r) => GearRMonthlyReport.fromJson(r as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[StoreRepo] fetchGearRReports: $e');
      return [];
    }
  }

  /// Gear R限定「インサイトアクティビティ」。月次バッチを待たず、
  /// 指定した直近日数分をその場で集計して返す（随時閲覧可能）。
  Future<GearRInsights> fetchGearRInsights({int days = 30}) async {
    final result =
        await _client.rpc('get_gear_r_insights', params: {'p_days': days});
    return GearRInsights.fromJson(result as Map<String, dynamic>);
  }

  Future<Map<String, int>> fetchMonthlyAnalytics(String userId) async {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);

    int encounterCount = 0;
    int profileViewCount = 0;
    int likesReceived = 0;
    int matches = 0;
    int linkClickCount = 0;

    try {
      final enc = await _client
          .from('encounters')
          .select('encounter_id')
          .or('user_a_id.eq.$userId,user_b_id.eq.$userId')
          .gte('time', monthStart.toIso8601String());
      encounterCount = (enc as List).length;
    } catch (_) {}

    try {
      final views = await _client
          .from('profile_views')
          .select('id')
          .eq('viewed_user_id', userId)
          .gte('viewed_at', monthStart.toIso8601String());
      profileViewCount = (views as List).length;
    } catch (_) {}

    try {
      final likes = await _client
          .from('likes')
          .select('like_id')
          .eq('to_user_id', userId)
          .gte('created_at', monthStart.toIso8601String());
      likesReceived = (likes as List).length;
    } catch (_) {}

    try {
      final m = await _client
          .from('matches')
          .select('match_id')
          .or('user_a_id.eq.$userId,user_b_id.eq.$userId')
          .gte('matched_at', monthStart.toIso8601String());
      matches = (m as List).length;
    } catch (_) {}

    try {
      final clicks = await _client
          .from('sns_link_clicks')
          .select('click_id')
          .eq('owner_user_id', userId)
          .gte('clicked_at', monthStart.toIso8601String());
      linkClickCount = (clicks as List).length;
    } catch (_) {}

    return {
      'encounters': encounterCount,
      'profile_views': profileViewCount,
      'likes_received': likesReceived,
      'matches': matches,
      'link_clicks': linkClickCount,
    };
  }
}

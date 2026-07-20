import 'package:flutter/foundation.dart';
import '../../../core/supabase/supabase_config.dart';
import '../models/gear_r_report_model.dart';
import '../models/item_model.dart';

class StoreRepository {
  final _client = SupabaseConfig.client;

  // ─── アイテム所持状況を取得 ─────────────────────────────
  Future<List<UserItemState>> fetchMyItems(String userId) async {
    try {
      final rows = await _client
          .from('user_items')
          .select()
          .eq('user_id', userId);
      return rows.map((r) => UserItemState.fromJson(r)).toList();
    } catch (e) {
      debugPrint('[StoreRepo] fetchMyItems: $e');
      return [];
    }
  }

  // ─── 時限アイテムを使用（ニトロ1h / スーパーニトロ1h / 24時間ギア＋） ─
  Future<void> activateTimedItem(String userId, ItemType type) async {
    final now = DateTime.now();
    final until = now.add(type.timedDuration);
    await _client.from('user_items').upsert({
      'user_id': userId,
      'item_type': type.value,
      'quantity': 0,
      'active_until': until.toIso8601String(),
      'updated_at': now.toIso8601String(),
    }, onConflict: 'user_id,item_type');
  }

  // ─── 渋！/激渋！ を1個消費 ───────────────────────────────
  Future<bool> consumeItem(String userId, ItemType type) async {
    try {
      final row = await _client
          .from('user_items')
          .select('quantity')
          .eq('user_id', userId)
          .eq('item_type', type.value)
          .maybeSingle();

      final current = (row?['quantity'] as int?) ?? 0;
      if (current <= 0) return false;

      await _client.from('user_items').update({
        'quantity': current - 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('user_id', userId).eq('item_type', type.value);
      return true;
    } catch (e) {
      debugPrint('[StoreRepo] consumeItem: $e');
      return false;
    }
  }

  // ─── アイテムを追加（購入後に呼ぶ） ─────────────────────
  Future<void> addItems(String userId, ItemType type, int count) async {
    final now = DateTime.now();
    final existing = await _client
        .from('user_items')
        .select('quantity')
        .eq('user_id', userId)
        .eq('item_type', type.value)
        .maybeSingle();

    final currentQty = (existing?['quantity'] as int?) ?? 0;
    await _client.from('user_items').upsert({
      'user_id': userId,
      'item_type': type.value,
      'quantity': currentQty + count,
      'updated_at': now.toIso8601String(),
    }, onConflict: 'user_id,item_type');
  }

  // ─── 購入履歴を記録 ──────────────────────────────────────
  Future<void> recordPurchase(String userId, String productId, int amountJpy) async {
    await _client.from('purchase_history').insert({
      'user_id': userId,
      'product_id': productId,
      'amount_jpy': amountJpy,
    });
  }

  // ─── Gear R 月次レポート一覧（DB保存分） ─────────────────
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

  // ─── 当月のリアルタイム集計（レポート未到着時のフォールバック） ─
  Future<Map<String, int>> fetchMonthlyAnalytics(String userId) async {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);

    int encounterCount = 0;
    int profileViewCount = 0;
    int likesReceived = 0;
    int matches = 0;

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

    return {
      'encounters': encounterCount,
      'profile_views': profileViewCount,
      'likes_received': likesReceived,
      'matches': matches,
    };
  }
}

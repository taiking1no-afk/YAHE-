import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;
import '../../../core/supabase/supabase_config.dart';
import '../../../core/supabase/storage_url_helper.dart';
import '../../../core/utils/image_sanitizer.dart';
import '../../../shared/models/user_model.dart';
import '../../../shared/models/encounter_stats.dart';
import '../../home/models/passing_target.dart';

class UserRepository {
  final _client = SupabaseConfig.client;

  Future<UserModel?> fetchUser(String userId) async {
    final data = await _client
        .from('users')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
    if (data == null) return null;
    final snsLinks = await fetchSnsLinks(userId);
    return UserModel.fromJson(data).copyWith(snsLinks: snsLinks);
  }

  /// SNSリンクを専用テーブルから取得（本人 or マッチ済みのみRLSで許可）
  Future<List<SnsLink>> fetchSnsLinks(String userId) async {
    try {
      final row = await _client
          .from('user_sns_links')
          .select('links')
          .eq('user_id', userId)
          .maybeSingle();
      final list = (row?['links'] as List<dynamic>? ?? []);
      return list
          .map((e) => SnsLink.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// SNSリンクを専用テーブルへ保存（本人のみRLSで許可）
  Future<void> saveSnsLinks(String userId, List<SnsLink> links) async {
    await _client.from('user_sns_links').upsert({
      'user_id': userId,
      'links': links.map((e) => e.toJson()).toList(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<String?> uploadAvatar(String userId, File file) async {
    try {
      final fileName =
          'avatar_${userId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final raw = await file.readAsBytes();
      // EXIF(GPS位置情報)を除去してからアップロード
      final bytes = await sanitizeImageBytes(raw);
      await _client.storage.from('profile-photos').uploadBinary(
            fileName,
            bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );
      return StorageUrlHelper.toStoredPath('profile-photos', fileName);
    } catch (e) {
      debugPrint('[UserRepo] アバターアップロード失敗: $e');
      return null;
    }
  }

  Future<UserModel> updateProfile({
    required String userId,
    String? nickname,
    String? area,
    String? comment,
    String? avatarUrl,
    List<SnsLink>? snsLinks,
  }) async {
    // SNSリンクは専用テーブル(user_sns_links)に保存する
    if (snsLinks != null) {
      await saveSnsLinks(userId, snsLinks);
    }

    final updates = <String, dynamic>{};
    if (nickname != null) updates['nickname'] = nickname;
    if (area != null) updates['area'] = area.isEmpty ? null : area;
    if (comment != null) updates['comment'] = comment.isEmpty ? null : comment;
    if (avatarUrl != null) updates['avatar_url'] = avatarUrl;

    // users 側に更新項目がない場合でも、最新のプロフィールを返す
    if (updates.isEmpty) {
      final data = await _client
          .from('users')
          .select()
          .eq('user_id', userId)
          .single();
      final links = await fetchSnsLinks(userId);
      return UserModel.fromJson(data).copyWith(snsLinks: links);
    }

    try {
      final data = await _client
          .from('users')
          .update(updates)
          .eq('user_id', userId)
          .select()
          .single();
      final links = await fetchSnsLinks(userId);
      return UserModel.fromJson(data).copyWith(snsLinks: links);
    } catch (e) {
      // avatar_url カラムが未追加の場合はそれを除いてリトライ
      if (updates.containsKey('avatar_url')) {
        debugPrint('[UserRepo] avatar_url カラム未作成のためスキップしてリトライ: $e');
        updates.remove('avatar_url');
        final data = await _client
            .from('users')
            .update(updates)
            .eq('user_id', userId)
            .select()
            .single();
        final links = await fetchSnsLinks(userId);
        return UserModel.fromJson(data).copyWith(snsLinks: links);
      }
      rethrow;
    }
  }

  Future<void> setPassingTarget(String userId, PassingTarget target) async {
    await _client
        .from('users')
        .update({'passing_target': target.value})
        .eq('user_id', userId);
  }

  Future<void> setAnonymousMode(String userId, bool value) async {
    await _client
        .from('users')
        .update({'anonymous_mode': value})
        .eq('user_id', userId);
  }

  /// Gear R 認証バッジの表示ラベル（空文字で非表示）
  Future<void> updateVerifiedLabel(String userId, String label) async {
    await _client.from('users').update({
      'verified_label': label.isEmpty ? null : label,
    }).eq('user_id', userId);
  }

  /// 鍵アカウント設定（true=鍵あり/相互いいねで開示, false=鍵なし/いいねで即開示）
  Future<void> setPrivate(String userId, bool value) async {
    await _client
        .from('users')
        .update({'is_private': value})
        .eq('user_id', userId);
  }

  Future<void> setQuietHours(String userId, int startHour, int endHour) async {
    await _client.from('users').update({
      'quiet_start': '${startHour.toString().padLeft(2, '0')}:00:00',
      'quiet_end': '${endHour.toString().padLeft(2, '0')}:00:00',
    }).eq('user_id', userId);
  }

  Future<List<Map<String, dynamic>>> fetchBlockList(String userId) async {
    final blocks = await _client
        .from('blocks')
        .select('block_id, blocked_id, created_at')
        .eq('blocker_id', userId)
        .order('created_at', ascending: false);

    // 相手のプロフィール取得を並列化（名前・アイコンを表示するため avatar_url も取得）
    final futures = (blocks as List).map((block) async {
      Map<String, dynamic>? userData;
      try {
        userData = await _client
            .from('users')
            .select('user_id, nickname, avatar_url')
            .eq('user_id', block['blocked_id'])
            .maybeSingle();
      } catch (_) {}
      final nickname = (userData?['nickname'] as String?);
      return <String, dynamic>{
        'block_id': block['block_id'],
        'blocked_id': block['blocked_id'],
        'nickname': (nickname == null || nickname.isEmpty) ? 'ユーザー' : nickname,
        'avatar_url': userData?['avatar_url'] as String?,
        'created_at': block['created_at'],
      };
    });
    return Future.wait(futures);
  }

  Future<void> unblock(String blockId) async {
    await _client.from('blocks').delete().eq('block_id', blockId);
  }

  /// 自分がブロックした／自分をブロックした相手の user_id 集合（双方向）。
  /// タイムライン等から相互に非表示にするために使う。
  Future<Set<String>> fetchBlockedUserIds(String userId) async {
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

  Future<void> saveFcmToken(String userId, String token) async {
    // FCMトークンは専用テーブルに保存（他人から読めないようRLSで保護）
    await _client.from('user_push_tokens').upsert({
      'user_id': userId,
      'fcm_token': token,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> block(String blockerId, String blockedId) async {
    // RPC でブロック登録 + 純粋なすれ違い記録(いいねが無いencounter)の削除を
    // アトミックに実行する。いいね・マッチは残すのでブロック解除で再表示される。
    try {
      await _client.rpc('block_user', params: {'p_blocked_id': blockedId});
    } catch (e) {
      // RPC 未適用環境へのフォールバック（従来通りの登録のみ）
      debugPrint('[UserRepo] block_user RPC 失敗 → fallback: $e');
      await _client.from('blocks').upsert({
        'blocker_id': blockerId,
        'blocked_id': blockedId,
      });
    }
  }

  Future<void> report({
    required String reporterId,
    required String targetId,
    required String category,
    String? detail,
  }) async {
    await _client.from('reports').insert({
      'reporter_id': reporterId,
      'target_id': targetId,
      'category': category,
      if (detail != null && detail.isNotEmpty) 'detail': detail,
    });
  }

  Future<void> grantGearPlus(String userId) async {
    await _client.rpc('grant_gear_plus', params: {'p_user_id': userId});
  }

  /// RevenueCat 同期: プラン・イントロ期間・お試し利用済みフラグを更新
  Future<void> syncSubscriptionPlan({
    required String userId,
    required String plan,
    DateTime? trialEndsAt,
    bool markTrialUsed = false,
  }) async {
    try {
      await _client.rpc('sync_subscription_plan', params: {
        'p_user_id': userId,
        'p_plan': plan,
        'p_trial_ends_at': trialEndsAt?.toUtc().toIso8601String(),
        'p_mark_trial_used': markTrialUsed,
      });
    } catch (e) {
      debugPrint('[UserRepo] syncSubscriptionPlan: $e');
    }
  }

  /// 相手プロフィールの閲覧を記録（Gear R 月次解析用・1日1回/人）
  Future<void> recordProfileView(String viewedUserId) async {
    try {
      await _client.rpc('record_profile_view', params: {'p_viewed_user_id': viewedUserId});
    } catch (e) {
      debugPrint('[UserRepo] recordProfileView: $e');
    }
  }

  /// 累計/本日のヤエー（すれ違い）人数。自分・他ユーザーどちらでも取得可能
  Future<EncounterStats> fetchEncounterStats(String userId) async {
    try {
      final data = await _client
          .rpc('get_encounter_stats', params: {'p_user_id': userId});
      return EncounterStats.fromJson(data as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[UserRepo] fetchEncounterStats: $e');
      return EncounterStats.zero;
    }
  }
}

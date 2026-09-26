import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;
import '../../../core/supabase/supabase_config.dart';
import '../../../core/supabase/storage_url_helper.dart';
import '../../../core/utils/image_sanitizer.dart';
import '../../../shared/models/user_model.dart';
import '../../../shared/models/encounter_stats.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../home/models/passing_target.dart';

/// 自分がブロックした相手のuser_id集合。
/// blocks_own ポリシー（blocker_id=自分の行しか見えない）の制約上、
/// このクエリは元々「自分がブロックした相手」しか返せない
/// （＝コンテンツの非表示フィルタとして使うにはこれで正しい非対称の挙動）。
/// 「ブロック済み」ボタンの再ブロック防止表示にも使う。
final blockedUserIdsProvider = FutureProvider.autoDispose<Set<String>>((ref) {
  final userId = ref.watch(authNotifierProvider).value?.userId;
  if (userId == null) return Future.value(const <String>{});
  return UserRepository().fetchBlockedUserIds(userId);
});

/// 指定した相手が自分をブロックしているかどうか。
/// blocks_own ポリシーの制約でクライアントから直接は分からないため、
/// 専用のSECURITY DEFINER RPC(am_i_blocked_by)を呼ぶ。
/// 「ブロックされています」表示・チャット送信不可の判定に使う。
final blockedByUserProvider =
    FutureProvider.autoDispose.family<bool, String>((ref, otherUserId) {
  return UserRepository().amIBlockedBy(otherUserId);
});

class UserRepository {
  final _client = SupabaseConfig.client;

  // UserModel.fromJson が参照するカラムのみ（fcm_token 等の非公開/未使用カラムを除外）
  static const _userColumns =
      'user_id, auth_id, nickname, area, comment, avatar_url, anonymous_mode, plan, trial_ends_at, gear_plus_trial_used_at, premium_override_plan, premium_override_expires_at, premium_override_source, is_verified, verified_label, is_private, birth_date, terms_agreed_at, is_suspended, passing_target, encounter_test_mode, avatar_focal_x, avatar_focal_y, created_at';

  Future<UserModel?> fetchUser(String userId) async {
    final data = await _client
        .from('users')
        .select(_userColumns)
        .eq('user_id', userId)
        .maybeSingle();
    if (data == null) return null;
    final snsLinks = await fetchSnsLinks(userId);
    final snsVisible = await fetchSnsVisibleToMatches(userId);
    final publicSnsLink = await fetchPublicSnsLink(userId);
    return UserModel.fromJson(data).copyWith(
      snsLinks: snsLinks,
      snsVisibleToMatches: snsVisible,
      publicSnsLink: publicSnsLink,
    );
  }

  /// プロフィールの公開SNSリンクを取得する（マッチ済みの相手にのみ表示）。
  Future<PublicSnsLink?> fetchPublicSnsLink(String userId) async {
    try {
      final row = await _client
          .from('public_sns_links')
          .select('platform, url, label, is_visible')
          .eq('user_id', userId)
          .maybeSingle();
      if (row == null) return null;
      return PublicSnsLink.fromJson(row);
    } catch (_) {
      return null;
    }
  }

  /// プロフィールの公開SNSリンクを保存する。urlを空にすると削除される。
  Future<void> setPublicSnsLink({
    required String platform,
    required String url,
    String? label,
    bool visible = true,
  }) async {
    await _client.rpc('set_public_sns_link', params: {
      'p_platform': platform,
      'p_url': url,
      'p_label': label,
      'p_visible': visible,
    });
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
  Future<void> saveSnsLinks(
    String userId,
    List<SnsLink> links, {
    bool? visibleToMatches,
  }) async {
    final row = <String, dynamic>{
      'user_id': userId,
      'links': links.map((e) => e.toJson()).toList(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (visibleToMatches != null) row['visible_to_matches'] = visibleToMatches;
    await _client.from('user_sns_links').upsert(row);
  }

  /// 「マッチした相手にSNSリンクをプロフィール表示するか」の本人設定を取得
  Future<bool> fetchSnsVisibleToMatches(String userId) async {
    try {
      final row = await _client
          .from('user_sns_links')
          .select('visible_to_matches')
          .eq('user_id', userId)
          .maybeSingle();
      return row?['visible_to_matches'] as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 一覧/サムネイル表示時のアバター焦点（トリミング中心）を更新する。
  Future<void> updateAvatarFocal(String userId, double x, double y) async {
    await _client.from('users').update({
      'avatar_focal_x': x,
      'avatar_focal_y': y,
    }).eq('user_id', userId);
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
    bool? snsVisibleToMatches,
  }) async {
    // SNSリンクは専用テーブル(user_sns_links)に保存する
    if (snsLinks != null) {
      await saveSnsLinks(userId, snsLinks, visibleToMatches: snsVisibleToMatches);
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
          .select(_userColumns)
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
          .select(_userColumns)
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
            .select(_userColumns)
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
        .update({'passing_target': target.value}).eq('user_id', userId);
  }

  Future<void> setAnonymousMode(String userId, bool value) async {
    // RLSでWHERE条件に一致する行が無くても例外にはならず0行更新で
    // 正常終了してしまうため、.select()で実際に更新できた行を確認する。
    // 呼び出し元(設定画面)はこれを見て楽観的更新をロールバックする。
    final updated = await _client
        .from('users')
        .update({'anonymous_mode': value})
        .eq('user_id', userId)
        .select('user_id');
    if (updated.isEmpty) {
      throw Exception('匿名モードの保存に失敗しました（更新対象が見つかりません）');
    }
  }

  /// Gear R 認証バッジの表示ラベル（空文字で非表示）
  Future<void> updateVerifiedLabel(String userId, String label) async {
    await _client.from('users').update({
      'verified_label': label.isEmpty ? null : label,
    }).eq('user_id', userId);
  }

  /// 鍵アカウント設定（true=鍵あり/相互いいねで開示, false=鍵なし/いいねで即開示）
  Future<void> setPrivate(String userId, bool value) async {
    final updated = await _client
        .from('users')
        .update({'is_private': value})
        .eq('user_id', userId)
        .select('user_id');
    if (updated.isEmpty) {
      throw Exception('鍵アカウント設定の保存に失敗しました（更新対象が見つかりません）');
    }
  }

  Future<void> setQuietHours(String userId, int startHour, int endHour) async {
    await _client.from('users').update({
      'quiet_start': '${startHour.toString().padLeft(2, '0')}:00:00',
      'quiet_end': '${endHour.toString().padLeft(2, '0')}:00:00',
    }).eq('user_id', userId);
  }

  Future<List<Map<String, dynamic>>> fetchBlockList(String userId) async {
    // users への直接SELECTは can_view_user() がブロック関係自体を理由に
    // 弾いてしまい、ブロックした本人からも相手の名前が見えなくなる
    // （常に「ユーザー」というプレースホルダー表示になっていた）。
    // 自分が作成した blocks 行の範囲でだけ相手の基本情報を返す専用RPCを使う。
    final rows = await _client.rpc('get_my_blocked_users') as List;
    return rows.map((r) {
      final map = r as Map<String, dynamic>;
      final nickname = map['nickname'] as String?;
      return <String, dynamic>{
        'block_id': map['block_id'],
        'blocked_id': map['blocked_id'],
        'nickname': (nickname == null || nickname.isEmpty) ? 'ユーザー' : nickname,
        'avatar_url': map['avatar_url'] as String?,
        'created_at': map['blocked_at'],
      };
    }).toList();
  }

  Future<void> unblock(String blockId) async {
    await _client.from('blocks').delete().eq('block_id', blockId);
  }

  /// 自分がブロックした相手の user_id 集合。
  /// blocks_own ポリシー（blocker_id=自分の行しか見えない）の制約上、
  /// このクエリは実質「自分がブロックした相手」しか返さない
  /// （非対称のブロック仕様として、これがそのままタイムラインの
  /// 非表示フィルタとして正しい挙動になる）。
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

  /// 保持期間ポリシー「FCMトークンは利用中のみ」に基づき、ログアウト時に削除する。
  Future<void> deleteFcmToken(String userId) async {
    try {
      await _client.from('user_push_tokens').delete().eq('user_id', userId);
    } catch (_) {}
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
    // RPC でブロック登録 + 相手が主催する募集への自分の参加・申請・興味ありを
    // まとめて解除する（すれ違い記録は削除しない＝ブロックされた側は
    // 引き続き閲覧できる。自分側の非表示は各画面のクライアント側フィルタで行う）。
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

  /// 指定したユーザーが自分をブロックしているかどうか。
  Future<bool> amIBlockedBy(String otherUserId) async {
    try {
      return await _client
          .rpc('am_i_blocked_by', params: {'p_user_id': otherUserId}) as bool;
    } catch (_) {
      return false;
    }
  }

  /// 通報を送信する。[targetType] は 'user'/'profile'/'chat_message'/
  /// 'group_message'/'board_post'/'photo'。メッセージ/投稿通報の場合は
  /// 対応する id を渡す（[targetId] はユーザー/プロフィール/写真通報のみ必須）。
  /// reporter は auth.uid() からサーバー側で解決するためなりすまし不可。
  Future<Map<String, dynamic>> report({
    required String targetType,
    required String category,
    String? detail,
    String? targetId,
    String? chatMessageId,
    String? groupMessageId,
    String? boardPostId,
  }) async {
    final result = await _client.rpc('submit_report', params: {
      'p_target_type': targetType,
      'p_category': category,
      if (detail != null && detail.isNotEmpty) 'p_detail': detail,
      if (targetId != null) 'p_target_id': targetId,
      if (chatMessageId != null) 'p_chat_message_id': chatMessageId,
      if (groupMessageId != null) 'p_group_message_id': groupMessageId,
      if (boardPostId != null) 'p_board_post_id': boardPostId,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  /// @deprecated クライアントからの plan 付与は禁止。Webhook / sync-subscription を使う。
  @Deprecated('Use SubscriptionSync / RevenueCat webhook')
  Future<void> grantGearPlus(String userId) async {
    debugPrint('[UserRepo] grantGearPlus is disabled (server-managed)');
  }

  /// @deprecated クライアントからの plan 同期は禁止。SubscriptionSync を使う。
  @Deprecated('Use SubscriptionSync.syncToSupabase')
  Future<void> syncSubscriptionPlan({
    required String userId,
    required String plan,
    DateTime? trialEndsAt,
    bool markTrialUsed = false,
  }) async {
    debugPrint('[UserRepo] syncSubscriptionPlan is disabled (server-managed)');
  }

  /// 相手プロフィールの閲覧を記録（Gear R 月次解析用・1日1回/人）
  Future<void> recordProfileView(String viewedUserId) async {
    try {
      await _client.rpc('record_profile_view',
          params: {'p_viewed_user_id': viewedUserId});
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

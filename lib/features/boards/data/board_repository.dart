import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;
import '../../../core/supabase/storage_url_helper.dart';
import '../../../core/supabase/supabase_config.dart';
import '../../../core/utils/image_sanitizer.dart';
import '../../vehicle/models/vehicle.dart';
import '../models/board_post_model.dart';
import '../models/board_participation_model.dart';
import '../../../shared/utils/network_timeout.dart';

class BoardRepository {
  final _client = SupabaseConfig.client;

  /// Gear Rの「インサイトアクティビティ」用に募集の閲覧数を記録する
  /// （主催者本人の閲覧・同一ユーザーの同日再閲覧はサーバー側で無視される）。
  Future<void> recordPostView(String postId) async {
    try {
      await _client
          .rpc('record_board_post_view', params: {'p_post_id': postId});
    } catch (_) {}
  }

  Future<List<BoardPostModel>> fetchPosts(
      {BoardPostType? postType,
      String? searchQuery,
      String? myUserId,
      int limit = 300}) async {
    try {
      var query = _client.from('board_posts').select();
      if (postType != null) {
        query = query.eq('post_type', postType.value);
      }
      if (searchQuery != null && searchQuery.trim().isNotEmpty) {
        // PostgRESTのor()フィルタ構文で使われる記号(, ) "はor条件の区切りとして
        // 解釈されてしまうため、自由入力の検索語からは除去してから使う。
        final sanitized = searchQuery.trim().replaceAll(RegExp(r'[,()"]'), '');
        if (sanitized.isNotEmpty) {
          query = query.or(
            'title.ilike.%$sanitized%,prefecture.ilike.%$sanitized%,meeting_place_text.ilike.%$sanitized%',
          );
        }
      }
      // board_postsは終了1ヶ月後に自動削除されるcron(migration_v1_67)があり
      // 無制限には増えないが、念のため上限を設けて防御する。
      final rows = await query
          .order('scheduled_at', ascending: true)
          .limit(limit)
          .withNetworkTimeout();
      final posts = (rows as List)
          .map((r) => BoardPostModel.fromJson(r as Map<String, dynamic>))
          .toList();

      Set<String> myInterestedPostIds = {};
      Set<String> myJoinedPostIds = {};
      if (myUserId != null) {
        try {
          final mine = await _client
              .from('board_participations')
              .select('post_id, status')
              .eq('user_id', myUserId)
              .inFilter('status', ['interested', 'joined']);
          for (final r in mine as List) {
            final map = r as Map<String, dynamic>;
            final pid = map['post_id'] as String;
            if (map['status'] == 'interested') {
              myInterestedPostIds.add(pid);
            } else {
              myJoinedPostIds.add(pid);
            }
          }
        } catch (_) {}
      }

      final withCounts = await Future.wait(posts.map((p) async {
        final joined = await _client
            .from('board_participations')
            .select('participation_id')
            .eq('post_id', p.postId)
            .eq('status', 'joined');
        // 「気になる」を押した人の身元はRLSで主催者・本人以外には見えないため、
        // 単純なSELECT件数では非主催者に対して常に0（過少）になってしまう。
        // 集計だけを返すSECURITY DEFINER関数(get_board_interested_count)を使う。
        final interestedCount = await _client.rpc(
          'get_board_interested_count',
          params: {'p_post_id': p.postId},
        ) as int;
        return p.copyWithCounts(
          joinedCount: (joined as List).length,
          interestedCount: interestedCount,
          isInterestedByMe: myInterestedPostIds.contains(p.postId),
          isJoinedByMe: myJoinedPostIds.contains(p.postId),
        );
      }));

      return withCounts;
    } catch (e, st) {
      debugPrint('[BoardRepo] fetchPosts failed: $e\n$st');
      rethrow;
    }
  }

  /// 指定したユーザーが参加予定(joined・開催日が未来)の募集一覧。
  /// マッチ後プロフィールの「参加予定のイベント」表示用。
  /// 招待制(invite_only)は対象外（RLS上も原則見えないが、念のためクライアント側でも除外する）。
  Future<List<BoardPostModel>> fetchUpcomingJoinedPosts(String userId) async {
    final rows = await _client
        .from('board_participations')
        .select('post_id')
        .eq('user_id', userId)
        .eq('status', 'joined');
    final postIds = (rows as List)
        .map((r) => (r as Map<String, dynamic>)['post_id'] as String)
        .toList();
    if (postIds.isEmpty) return [];

    final postRows = await _client
        .from('board_posts')
        .select()
        .inFilter('post_id', postIds)
        .neq('visibility', 'invite_only')
        .gt('scheduled_at', DateTime.now().toUtc().toIso8601String())
        .order('scheduled_at', ascending: true);
    return (postRows as List)
        .map((r) => BoardPostModel.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// 自分が参加(joined)している募集一覧（ツーリング・イベントに誘う機能の候補選び用）。
  Future<List<BoardPostModel>> fetchMyJoinedPosts(String userId) async {
    final rows = await _client
        .from('board_participations')
        .select('post_id')
        .eq('user_id', userId)
        .eq('status', 'joined');
    final postIds = (rows as List)
        .map((r) => (r as Map<String, dynamic>)['post_id'] as String)
        .toList();
    if (postIds.isEmpty) return [];

    final postRows = await _client
        .from('board_posts')
        .select()
        .inFilter('post_id', postIds)
        .order('scheduled_at', ascending: true);
    // 「誘う」シート専用（唯一の呼び出し元）。終了済みの募集はサーバー側の
    // invite_to_board_post自体が拒否するため、一覧の時点で除外しておく
    // （以前は終了済みが先頭付近に混ざり、選ぶと無言で招待が失敗していた）。
    return (postRows as List)
        .map((r) => BoardPostModel.fromJson(r as Map<String, dynamic>))
        .where((p) => !p.isEnded)
        .toList();
  }

  /// 自分が参加(joined)または興味あり(interested)にしている募集一覧（自分のカレンダー用）。
  Future<List<BoardPostModel>> fetchMyParticipatedPosts(String userId) async {
    final rows = await _client
        .from('board_participations')
        .select('post_id')
        .eq('user_id', userId)
        .inFilter('status', ['joined', 'interested']);
    final postIds = (rows as List)
        .map((r) => (r as Map<String, dynamic>)['post_id'] as String)
        .toSet()
        .toList();
    if (postIds.isEmpty) return [];

    final postRows = await _client
        .from('board_posts')
        .select()
        .inFilter('post_id', postIds)
        .order('scheduled_at', ascending: true);
    return (postRows as List)
        .map((r) => BoardPostModel.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// 同じ日（現地時間の暦日）に開催予定の他の募集一覧（重複開催の注意表示用）。
  /// RLSの都合上、visibility='open' もしくは自分が関係する募集のみ対象になる。
  Future<List<BoardPostModel>> fetchPostsOnDate(DateTime localDate,
      {String? excludePostId}) async {
    final start =
        DateTime(localDate.year, localDate.month, localDate.day).toUtc();
    final end = start.add(const Duration(days: 1));
    final rows = await _client
        .from('board_posts')
        .select()
        .gte('scheduled_at', start.toIso8601String())
        .lt('scheduled_at', end.toIso8601String());
    final posts = (rows as List)
        .map((r) => BoardPostModel.fromJson(r as Map<String, dynamic>))
        .toList();
    if (excludePostId != null) {
      posts.removeWhere((p) => p.postId == excludePostId);
    }
    return posts;
  }

  Future<BoardPostModel?> fetchPost(String postId) async {
    final row = await _client
        .from('board_posts')
        .select()
        .eq('post_id', postId)
        .maybeSingle();
    if (row == null) return null;
    final post = BoardPostModel.fromJson(row);

    // fetchPosts() 同様に参加人数を集計する。ここが未集計だと joinedCount が
    // 常に0扱いになり、定員判定（isFull）が機能しなくなる。
    final joined = await _client
        .from('board_participations')
        .select('participation_id')
        .eq('post_id', postId)
        .eq('status', 'joined');
    // 「気になる」の身元はRLSで主催者・本人以外には見えないため、
    // 単純なSELECT件数ではなく集計専用のRPCで人数だけを取得する。
    final interestedCount = await _client.rpc(
      'get_board_interested_count',
      params: {'p_post_id': postId},
    ) as int;
    return post.copyWithCounts(
      joinedCount: (joined as List).length,
      interestedCount: interestedCount,
    );
  }

  Future<List<BoardParticipationModel>> fetchParticipants(String postId) async {
    final rows = await _client
        .from('board_participations')
        .select('*, users:user_id(nickname, avatar_url)')
        .eq('post_id', postId)
        .inFilter('status', ['joined', 'interested']).order('created_at',
            ascending: true);

    final list = rows as List;
    final vehicleIds = list
        .map((r) => (r as Map<String, dynamic>)['vehicle_id'] as String?)
        .whereType<String>()
        .toSet()
        .toList();
    Map<String, Vehicle> vehiclesById = {};
    if (vehicleIds.isNotEmpty) {
      final vehicleRows = await _client
          .from('vehicles')
          .select()
          .inFilter('vehicle_id', vehicleIds);
      vehiclesById = {
        for (final v in vehicleRows as List)
          (v as Map<String, dynamic>)['vehicle_id'] as String:
              Vehicle.fromJson(v),
      };
    }

    return list.map((r) {
      final map = r as Map<String, dynamic>;
      final base = BoardParticipationModel.fromJson(map);
      final userMap = map['users'] as Map<String, dynamic>?;
      return base.withUser(
        nickname: userMap?['nickname'] as String?,
        avatarUrl: userMap?['avatar_url'] as String?,
        vehicle: base.vehicleId != null ? vehiclesById[base.vehicleId] : null,
      );
    }).toList();
  }

  /// 主催者の承認待ち（許可制の参加申請）一覧。主催者本人のみRLSで閲覧可能。
  Future<List<BoardParticipationModel>> fetchPendingRequests(
      String postId) async {
    final rows = await _client
        .from('board_participations')
        .select('*, users:user_id(nickname, avatar_url)')
        .eq('post_id', postId)
        .eq('status', 'pending')
        .order('created_at', ascending: true);

    return (rows as List).map((r) {
      final map = r as Map<String, dynamic>;
      final base = BoardParticipationModel.fromJson(map);
      final userMap = map['users'] as Map<String, dynamic>?;
      return base.withUser(
        nickname: userMap?['nickname'] as String?,
        avatarUrl: userMap?['avatar_url'] as String?,
      );
    }).toList();
  }

  /// 自分が主催する各募集ごとの参加申請(pending)件数。
  /// 一覧画面で「参加希望者がいます」バッジを出すために使う。
  Future<Map<String, int>> fetchMyOrganizedPendingCounts(
      String myUserId) async {
    final myPosts = await _client
        .from('board_posts')
        .select('post_id')
        .eq('organizer_id', myUserId);
    final postIds = (myPosts as List)
        .map((r) => (r as Map<String, dynamic>)['post_id'] as String)
        .toList();
    if (postIds.isEmpty) return {};

    final rows = await _client
        .from('board_participations')
        .select('post_id')
        .eq('status', 'pending')
        .inFilter('post_id', postIds);
    final counts = <String, int>{};
    for (final r in rows as List) {
      final postId = (r as Map<String, dynamic>)['post_id'] as String;
      counts[postId] = (counts[postId] ?? 0) + 1;
    }
    return counts;
  }

  Future<BoardParticipationModel?> fetchMyParticipation(
      String postId, String userId) async {
    final row = await _client
        .from('board_participations')
        .select()
        .eq('post_id', postId)
        .eq('user_id', userId)
        .maybeSingle();
    if (row == null) return null;
    return BoardParticipationModel.fromJson(row);
  }

  /// マッチ済みの相手のうち、この投稿に参加(joined)している人のuser_id一覧
  Future<Set<String>> fetchAttendingMatchUserIds(String postId) async {
    final rows = await _client
        .rpc('get_board_attending_matches', params: {'p_post_id': postId});
    return (rows as List)
        .map((r) => (r as Map<String, dynamic>)['user_id'] as String)
        .toSet();
  }

  Future<String> createPost({
    required BoardPostType postType,
    required String title,
    String? detail,
    BoardPostMode? mode,
    String? meetingPlaceText,
    double? meetingLat,
    double? meetingLng,
    String? routeDetail,
    DateTime? scheduledAt,
    int? capacity,
    required BoardVisibility visibility,
    String? prefecture,
  }) async {
    final id = await _client.rpc('create_board_post', params: {
      'p_post_type': postType.value,
      'p_title': title,
      'p_detail': detail,
      'p_mode': mode?.value,
      'p_meeting_place_text': meetingPlaceText,
      'p_meeting_lat': meetingLat,
      'p_meeting_lng': meetingLng,
      'p_route_detail': routeDetail,
      'p_scheduled_at': scheduledAt?.toUtc().toIso8601String(),
      'p_capacity': capacity,
      'p_visibility': visibility.value,
      'p_prefecture': prefecture,
    });
    return id as String;
  }

  /// 主催者本人のみRLSで更新可能（board_posts_update_own）。
  Future<void> updatePost({
    required String postId,
    required BoardPostType postType,
    required String title,
    String? detail,
    BoardPostMode? mode,
    String? meetingPlaceText,
    double? meetingLat,
    double? meetingLng,
    String? routeDetail,
    DateTime? scheduledAt,
    int? capacity,
    required BoardVisibility visibility,
    String? prefecture,
    String? imagePath,
  }) async {
    await _client.from('board_posts').update({
      'post_type': postType.value,
      'title': title,
      'detail': detail,
      'mode': postType == BoardPostType.touring ? mode?.value : null,
      'meeting_place_text': meetingPlaceText,
      'meeting_lat': meetingLat,
      'meeting_lng': meetingLng,
      'route_detail': routeDetail,
      'scheduled_at': scheduledAt?.toUtc().toIso8601String(),
      'capacity': capacity,
      'prefecture': prefecture,
      'visibility': visibility.value,
      'image_path': imagePath,
    }).eq('post_id', postId);
  }

  /// 主催者本人のみRLSで更新可能（board_posts_update_own）。
  Future<void> updatePostImage(String postId, String? imagePath) async {
    await _client
        .from('board_posts')
        .update({'image_path': imagePath}).eq('post_id', postId);
  }

  /// 主催者のみアップロード可能（board_photos_insert_organizer）。post作成後に呼ぶこと。
  Future<String?> uploadPostImage(String postId, File file) async {
    try {
      final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
      final objectPath = '$postId/$fileName';
      final raw = await file.readAsBytes();
      final bytes = await sanitizeImageBytes(raw);
      await _client.storage.from('board-photos').uploadBinary(
            objectPath,
            bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );
      return StorageUrlHelper.toStoredPath('board-photos', objectPath);
    } catch (e) {
      debugPrint('[BoardRepo] uploadPostImage failed: $e');
      return null;
    }
  }

  /// 主催者本人のみRLSで削除可能（board_posts_delete_own）。
  Future<void> deletePost(String postId) async {
    await _client.from('board_posts').delete().eq('post_id', postId);
  }

  Future<Map<String, dynamic>> join(String postId, {String? vehicleId}) async {
    final result = await _client.rpc('join_board_post', params: {
      'p_post_id': postId,
      'p_vehicle_id': vehicleId,
    });
    return result as Map<String, dynamic>;
  }

  Future<void> expressInterest(String postId) async {
    await _client
        .rpc('express_interest_board_post', params: {'p_post_id': postId});
  }

  Future<void> cancelInterest(String postId) async {
    await _client.rpc('cancel_board_interest', params: {'p_post_id': postId});
  }

  Future<void> leave(String postId) async {
    await _client.rpc('leave_board_post', params: {'p_post_id': postId});
  }

  Future<Map<String, dynamic>> respondToInvite(
      String participationId, bool accept) async {
    final result = await _client.rpc('respond_to_board_invite', params: {
      'p_participation_id': participationId,
      'p_accept': accept,
    });
    return result as Map<String, dynamic>;
  }

  Future<void> invite(String postId, String userId) async {
    await _client.rpc('invite_to_board_post', params: {
      'p_post_id': postId,
      'p_user_id': userId,
    });
  }

  Future<void> approveJoinRequest(String participationId, bool approve) async {
    await _client.rpc('approve_board_join_request', params: {
      'p_participation_id': participationId,
      'p_approve': approve,
    });
  }

  /// 参加者限定の期間限定チャットを作成する（主催者のみ）。既にあれば既存のgroup_idを返す。
  Future<String> createPostChat(String postId) async {
    final id = await _client
        .rpc('create_board_post_chat', params: {'p_post_id': postId});
    return id as String;
  }
}

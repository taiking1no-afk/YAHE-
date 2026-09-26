import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show
        RealtimeChannel,
        PostgresChangeEvent,
        PostgresChangeFilter,
        PostgresChangeFilterType,
        FileOptions;
import '../../../core/supabase/storage_url_helper.dart';
import '../../../core/supabase/supabase_config.dart';
import '../../../core/utils/image_sanitizer.dart';
import '../models/group_model.dart';
import '../models/group_membership_model.dart';
import '../models/group_message_model.dart';

class GroupRepository {
  final _client = SupabaseConfig.client;

  /// 一覧・検索（誰でも閲覧可能）。
  /// 募集(イベント/ツーリング)から自動作成される期間限定の参加者チャット
  /// (expires_atが設定されている)は、ここには出さずマイグループチャット
  /// にのみ表示する（expires_atの有無が唯一の判別手段。migration_v1_65/v1_70参照）。
  Future<List<GroupModel>> fetchGroups({String? searchQuery}) async {
    try {
      var query = _client
          .from('groups')
          .select('*, owner:owner_id(area)')
          .filter('expires_at', 'is', null);
      if (searchQuery != null && searchQuery.trim().isNotEmpty) {
        query = query.ilike('name', '%${searchQuery.trim()}%');
      }
      final rows = await query.order('created_at', ascending: false);

      final groups = (rows as List)
          .map((r) => GroupModel.fromJson(r as Map<String, dynamic>))
          .toList();

      // メンバー数を並列取得（件数が多い場合の直列N+1を避ける）
      final counts = await Future.wait(groups.map((g) async {
        final memberRows = await _client
            .from('group_memberships')
            .select('membership_id')
            .eq('group_id', g.groupId)
            .eq('status', 'member');
        return (memberRows as List).length;
      }));

      return [
        for (var i = 0; i < groups.length; i++)
          GroupModel(
            groupId: groups[i].groupId,
            ownerId: groups[i].ownerId,
            name: groups[i].name,
            description: groups[i].description,
            joinMode: groups[i].joinMode,
            iconUrl: groups[i].iconUrl,
            createdAt: groups[i].createdAt,
            memberCount: counts[i],
            ownerArea: groups[i].ownerArea,
          ),
      ];
    } catch (e, st) {
      debugPrint('[GroupRepo] fetchGroups failed: $e\n$st');
      rethrow;
    }
  }

  /// マッチ済みの相手が所属(member)しているグループのID一覧（おすすめ並べ替え用）。
  Future<Set<String>> fetchMatchedUserGroupIds(String myUserId) async {
    try {
      final matchRows = await _client
          .from('matches')
          .select('user_a_id, user_b_id')
          .or('user_a_id.eq.$myUserId,user_b_id.eq.$myUserId');
      final matchedUserIds = <String>{};
      for (final r in matchRows as List) {
        final m = r as Map<String, dynamic>;
        final a = m['user_a_id'] as String;
        final b = m['user_b_id'] as String;
        matchedUserIds.add(a == myUserId ? b : a);
      }
      if (matchedUserIds.isEmpty) return {};

      final rows = await _client
          .from('group_memberships')
          .select('group_id')
          .inFilter('user_id', matchedUserIds.toList())
          .eq('status', 'member');
      return (rows as List)
          .map((r) => (r as Map<String, dynamic>)['group_id'] as String)
          .toSet();
    } catch (_) {
      return {};
    }
  }

  Future<GroupModel?> fetchGroup(String groupId) async {
    final row = await _client
        .from('groups')
        .select()
        .eq('group_id', groupId)
        .maybeSingle();
    if (row == null) return null;
    final group = GroupModel.fromJson(row);

    // fetchGroups()と違いここではメンバー数を集計していなかったため、
    // グループ詳細画面が常に「0人」表示になり、SNS共有画像にも
    // 「👥 0人が参加中」とそのまま焼き込まれてしまっていた。
    final memberRows = await _client
        .from('group_memberships')
        .select('membership_id')
        .eq('group_id', groupId)
        .eq('status', 'member');
    final memberCount = (memberRows as List).length;

    return GroupModel(
      groupId: group.groupId,
      ownerId: group.ownerId,
      name: group.name,
      description: group.description,
      joinMode: group.joinMode,
      iconUrl: group.iconUrl,
      createdAt: group.createdAt,
      memberCount: memberCount,
      ownerArea: group.ownerArea,
      expiresAt: group.expiresAt,
    );
  }

  /// 自分が所属（member）しているグループ一覧（プロフィールの「所属グループ」表示用）。
  /// 募集(イベント/ツーリング)から自動作成された期間限定の参加者チャット
  /// (expires_atが設定されている)は、通常のグループ一覧同様ここにも出さない。
  Future<List<GroupModel>> fetchMyGroups(String userId) async {
    final memberships = await _client
        .from('group_memberships')
        .select('group_id')
        .eq('user_id', userId)
        .eq('status', 'member');
    final groupIds =
        (memberships as List).map((m) => m['group_id'] as String).toList();
    if (groupIds.isEmpty) return [];

    final rows = await _client
        .from('groups')
        .select()
        .inFilter('group_id', groupIds)
        .filter('expires_at', 'is', null);
    return (rows as List)
        .map((r) => GroupModel.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// 自分が招待されて未応答（invited）のグループ一覧（一覧の最上部表示用）。
  Future<List<InvitedGroupEntry>> fetchMyInvitedGroups(String userId) async {
    final memberships = await _client
        .from('group_memberships')
        .select('membership_id, group_id')
        .eq('user_id', userId)
        .eq('status', 'invited');
    final rows = memberships as List;
    if (rows.isEmpty) return [];

    final groupIds = rows
        .map((m) => (m as Map<String, dynamic>)['group_id'] as String)
        .toList();
    final groupRows =
        await _client.from('groups').select().inFilter('group_id', groupIds);
    final rawGroups = (groupRows as List)
        .map((g) => GroupModel.fromJson(g as Map<String, dynamic>))
        .toList();

    // fetchGroup同様、ここでもメンバー数を集計していなかったため招待
    // セクションが常に「0人」表示になっていた。
    final counts = await Future.wait(rawGroups.map((g) async {
      final memberRows = await _client
          .from('group_memberships')
          .select('membership_id')
          .eq('group_id', g.groupId)
          .eq('status', 'member');
      return (memberRows as List).length;
    }));

    final groupsById = {
      for (var i = 0; i < rawGroups.length; i++)
        rawGroups[i].groupId: GroupModel(
          groupId: rawGroups[i].groupId,
          ownerId: rawGroups[i].ownerId,
          name: rawGroups[i].name,
          description: rawGroups[i].description,
          joinMode: rawGroups[i].joinMode,
          iconUrl: rawGroups[i].iconUrl,
          createdAt: rawGroups[i].createdAt,
          memberCount: counts[i],
          ownerArea: rawGroups[i].ownerArea,
          expiresAt: rawGroups[i].expiresAt,
        ),
    };

    return rows
        .map((m) {
          final map = m as Map<String, dynamic>;
          final group = groupsById[map['group_id'] as String];
          if (group == null) return null;
          return InvitedGroupEntry(
              membershipId: map['membership_id'] as String, group: group);
        })
        .whereType<InvitedGroupEntry>()
        .toList();
  }

  Future<List<GroupMembershipModel>> fetchMembers(String groupId) async {
    final rows = await _client
        .from('group_memberships')
        .select()
        .eq('group_id', groupId)
        .eq('status', 'member')
        .order('created_at', ascending: true);
    return _hydrateUsers((rows as List)
        .map((r) => GroupMembershipModel.fromJson(r as Map<String, dynamic>))
        .toList());
  }

  Future<List<GroupMembershipModel>> _hydrateUsers(
      List<GroupMembershipModel> memberships) async {
    if (memberships.isEmpty) return memberships;
    final userIds = memberships.map((m) => m.userId).toSet().toList();
    final userRows = await _client
        .from('users')
        .select('user_id, nickname, avatar_url')
        .inFilter('user_id', userIds);
    final usersById = {
      for (final u in userRows as List)
        (u as Map<String, dynamic>)['user_id'] as String: u
    };
    return memberships.map((m) {
      final u = usersById[m.userId];
      return m.withUser(
          nickname: u?['nickname'] as String?,
          avatarUrl: u?['avatar_url'] as String?);
    }).toList();
  }

  /// 呼び出し元本人の、このグループでの参加状態（未参加ならnull）
  Future<GroupMembershipModel?> fetchMyMembership(
      String groupId, String userId) async {
    final row = await _client
        .from('group_memberships')
        .select()
        .eq('group_id', groupId)
        .eq('user_id', userId)
        .maybeSingle();
    if (row == null) return null;
    return GroupMembershipModel.fromJson(row);
  }

  /// 自分宛の招待・自グループへの参加申請一覧（承認待ちUI用）
  Future<List<GroupMembershipModel>> fetchPendingRequests(
      String groupId) async {
    final rows = await _client
        .from('group_memberships')
        .select()
        .eq('group_id', groupId)
        .eq('status', 'pending')
        .order('created_at', ascending: true);
    return _hydrateUsers((rows as List)
        .map((r) => GroupMembershipModel.fromJson(r as Map<String, dynamic>))
        .toList());
  }

  /// 自分がオーナーの各グループごとの参加申請(pending)件数。
  /// 一覧画面で「参加希望者がいます」バッジを出すために使う。
  Future<Map<String, int>> fetchMyOwnedPendingCounts(String myUserId) async {
    final myGroups = await _client
        .from('groups')
        .select('group_id')
        .eq('owner_id', myUserId);
    final groupIds = (myGroups as List)
        .map((r) => (r as Map<String, dynamic>)['group_id'] as String)
        .toList();
    if (groupIds.isEmpty) return {};

    final rows = await _client
        .from('group_memberships')
        .select('group_id')
        .eq('status', 'pending')
        .inFilter('group_id', groupIds);
    final counts = <String, int>{};
    for (final r in rows as List) {
      final groupId = (r as Map<String, dynamic>)['group_id'] as String;
      counts[groupId] = (counts[groupId] ?? 0) + 1;
    }
    return counts;
  }

  Future<String> createGroup({
    required String name,
    String? description,
    required GroupJoinMode joinMode,
    bool inviteRestrictedToLeader = false,
  }) async {
    final id = await _client.rpc('create_group', params: {
      'p_name': name,
      'p_description': description,
      'p_join_mode': joinMode.value,
      'p_invite_restricted_to_leader': inviteRestrictedToLeader,
    });
    return id as String;
  }

  /// リーダーの昇格/降格（オーナーのみ実行可能）。
  Future<void> promoteMember(String groupId, String userId, {required bool toLeader}) async {
    await _client.rpc('promote_group_member', params: {
      'p_group_id': groupId,
      'p_user_id': userId,
      'p_role': toLeader ? 'leader' : 'member',
    });
  }

  /// メンバーの除名。open: メンバー全員可 / invite_only（リーダー制）・approval: オーナー/リーダーのみ。
  Future<void> kickMember(String groupId, String userId) async {
    await _client.rpc('kick_group_member', params: {
      'p_group_id': groupId,
      'p_target_user_id': userId,
    });
  }

  Future<Map<String, dynamic>> requestJoin(String groupId) async {
    final result = await _client
        .rpc('request_join_group', params: {'p_group_id': groupId});
    return result as Map<String, dynamic>;
  }

  Future<void> inviteUser(String groupId, String userId) async {
    await _client.rpc('invite_to_group', params: {
      'p_group_id': groupId,
      'p_user_id': userId,
    });
  }

  Future<void> respondToInvite(String membershipId, bool accept) async {
    await _client.rpc('respond_to_group_invite', params: {
      'p_membership_id': membershipId,
      'p_accept': accept,
    });
  }

  Future<void> approveJoinRequest(String membershipId, bool approve) async {
    await _client.rpc('approve_group_join_request', params: {
      'p_membership_id': membershipId,
      'p_approve': approve,
    });
  }

  Future<void> leaveGroup(String groupId) async {
    await _client.rpc('leave_group', params: {'p_group_id': groupId});
  }

  /// オーナー本人のみRLSで削除可能（groups_delete_own）。メンバー・チャットも連動して削除される。
  Future<void> deleteGroup(String groupId) async {
    await _client.from('groups').delete().eq('group_id', groupId);
  }

  /// オーナー本人のみRLSで更新可能（groups_update_own）。
  Future<void> updateGroup({
    required String groupId,
    required String name,
    String? description,
    required GroupJoinMode joinMode,
    String? iconUrl,
    bool inviteRestrictedToLeader = false,
  }) async {
    await _client.from('groups').update({
      'name': name,
      'description': description,
      'join_mode': joinMode.value,
      'icon_url': iconUrl,
      'invite_restricted_to_leader': inviteRestrictedToLeader,
    }).eq('group_id', groupId);
  }

  /// オーナー本人のみRLSで更新可能（groups_update_own）。
  Future<void> updateGroupIcon(String groupId, String? iconUrl) async {
    await _client
        .from('groups')
        .update({'icon_url': iconUrl}).eq('group_id', groupId);
  }

  /// オーナーのみアップロード可能（group_photos_insert_owner）。グループ作成後に呼ぶこと。
  Future<String?> uploadGroupIcon(String groupId, File file) async {
    try {
      final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
      final objectPath = '$groupId/$fileName';
      final raw = await file.readAsBytes();
      final bytes = await sanitizeImageBytes(raw);
      await _client.storage.from('group-photos').uploadBinary(
            objectPath,
            bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );
      return StorageUrlHelper.toStoredPath('group-photos', objectPath);
    } catch (e) {
      debugPrint('[GroupRepo] uploadGroupIcon failed: $e');
      return null;
    }
  }

  Future<void> transferOwnership(String groupId, String newOwnerUserId) async {
    await _client.rpc('transfer_group_ownership', params: {
      'p_group_id': groupId,
      'p_new_owner_id': newOwnerUserId,
    });
  }

  // ─── グループチャット ─────────────────────────────────

  /// 自分が参加中の各グループの未読件数・最終メッセージをまとめて取得する。
  Future<List<GroupChatSummary>> fetchMyGroupChatSummaries() async {
    final rows = await _client.rpc('get_my_group_chat_summaries');
    final list = rows as List;
    if (list.isEmpty) return [];

    final groupIds = list
        .map((r) => (r as Map<String, dynamic>)['group_id'] as String)
        .toList();
    final groupRows = await _client
        .from('groups')
        .select('group_id, name, icon_url')
        .inFilter('group_id', groupIds);
    final groupsById = {
      for (final g in groupRows as List)
        (g as Map<String, dynamic>)['group_id'] as String: g
    };

    return list.map((r) {
      final map = r as Map<String, dynamic>;
      final groupId = map['group_id'] as String;
      final g = groupsById[groupId];
      return GroupChatSummary(
        groupId: groupId,
        groupName: g?['name'] as String? ?? '（不明なグループ）',
        groupIconUrl: g?['icon_url'] as String?,
        lastMessageBody: map['last_message_body'] as String?,
        lastMessageAt: map['last_message_at'] != null
            ? DateTime.parse(map['last_message_at'] as String).toLocal()
            : null,
        unreadCount: (map['unread_count'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  Future<List<GroupMessageModel>> fetchGroupMessages(String groupId) async {
    final rows = await _client
        .from('group_messages')
        .select()
        .eq('group_id', groupId)
        .order('created_at', ascending: true);
    final messages = (rows as List)
        .map((r) => GroupMessageModel.fromJson(r as Map<String, dynamic>))
        .toList();
    if (messages.isEmpty) return messages;

    final senderIds = messages.map((m) => m.senderId).toSet().toList();
    final userRows = await _client
        .from('users')
        .select('user_id, nickname, avatar_url')
        .inFilter('user_id', senderIds);
    final usersById = {
      for (final u in userRows as List)
        (u as Map<String, dynamic>)['user_id'] as String: u
    };

    return messages.map((m) {
      final u = usersById[m.senderId];
      return m.withSender(
          nickname: u?['nickname'] as String?,
          avatarUrl: u?['avatar_url'] as String?);
    }).toList();
  }

  Future<void> sendGroupMessage(String groupId, String body,
      {bool isQuickReply = false}) async {
    try {
      await _client.rpc('send_group_message', params: {
        'p_group_id': groupId,
        'p_content_type': isQuickReply ? 'quick_reply' : 'text',
        'p_body': body,
      });
    } catch (e, st) {
      debugPrint('[GroupRepo] sendGroupMessage failed: $e\n$st');
      rethrow;
    }
  }

  Future<void> sendGroupPhoto(
      String groupId, String myUserId, File file) async {
    try {
      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}_${file.path.hashCode.abs()}.jpg';
      final objectPath = '$groupId/$fileName';
      final raw = await file.readAsBytes();
      final bytes = await sanitizeImageBytes(raw);
      await _client.storage.from('group-chat-photos').uploadBinary(
            objectPath,
            bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );
      final stored =
          StorageUrlHelper.toStoredPath('group-chat-photos', objectPath);
      await _client.rpc('send_group_message', params: {
        'p_group_id': groupId,
        'p_content_type': 'photo',
        'p_photo_path': stored,
      });
    } catch (e, st) {
      debugPrint('[GroupRepo] sendGroupPhoto failed: $e\n$st');
      rethrow;
    }
  }

  Future<void> sendGroupBoardInvite(
      String groupId, String postId, String postTitle) async {
    try {
      await _client.rpc('send_group_message', params: {
        'p_group_id': groupId,
        'p_content_type': 'board_invite',
        'p_body': postTitle,
        'p_related_post_id': postId,
      });
    } catch (e, st) {
      debugPrint('[GroupRepo] sendGroupBoardInvite failed: $e\n$st');
      rethrow;
    }
  }

  Future<void> markGroupRead(String groupId) async {
    await _client.rpc('mark_group_read', params: {'p_group_id': groupId});
  }

  /// 送信取り消し（本人のメッセージのみ）。RPC成功後、写真ならStorage実体も
  /// ベストエフォートで削除する（失敗しても取り消し自体は成功扱い）。
  Future<void> unsendGroupMessage(String messageId, {String? photoPath}) async {
    final result = await _client
        .rpc('unsend_group_message', params: {'p_message_id': messageId});
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      throw Exception(map['error'] ?? 'unsend_failed');
    }
    if (photoPath != null) {
      final ref = StorageUrlHelper.parseStored(photoPath);
      if (ref != null) {
        try {
          await _client.storage.from(ref.bucket).remove([ref.path]);
        } catch (e) {
          debugPrint('[GroupRepo] unsendGroupMessage storage cleanup failed: $e');
        }
      }
    }
  }

  RealtimeChannel subscribeToGroupMessages(
      String groupId, void Function() onChange) {
    return _client
        .channel('group_messages_$groupId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'group_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'group_id',
            value: groupId,
          ),
          callback: (_) => onChange(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'group_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'group_id',
            value: groupId,
          ),
          callback: (_) => onChange(),
        )
        .subscribe();
  }
}

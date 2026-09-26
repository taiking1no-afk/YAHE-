import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show
        FileOptions,
        RealtimeChannel,
        PostgresChangeEvent,
        PostgresChangeFilter,
        PostgresChangeFilterType;
import '../../../core/supabase/supabase_config.dart';
import '../../../core/supabase/storage_url_helper.dart';
import '../../../core/utils/image_sanitizer.dart';
import '../models/chat_message_model.dart';
import '../models/chat_thread_model.dart';
import '../../../shared/utils/network_timeout.dart';

class ChatRepository {
  final _client = SupabaseConfig.client;

  /// マッチ一覧をベースに、各マッチのチャットスレッド状況を合成する。
  /// （chat_threadsは初回送信まで存在しないため、matches起点で組み立てる）
  Future<List<ChatThreadModel>> fetchThreadList(String myUserId) async {
    try {
      final matches = await _client
          .from('matches')
          .select('match_id, user_a_id, user_b_id, dissolved_at')
          .or('user_a_id.eq.$myUserId,user_b_id.eq.$myUserId')
          .withNetworkTimeout();

      // マッチは非対称ブロックでも解除されず継続する仕様のため、encounters/
      // likes/matches一覧と同様にここでも「自分がブロックした相手」を除外
      // する（以前は除外が無く、ブロック後もチャット一覧に相手が残り続け、
      // 再入室できてしまっていた）。
      final blockedIds = await _fetchBlockedIds(myUserId);
      final visibleMatches = (matches as List).where((m) {
        final otherUserId = m['user_a_id'] == myUserId
            ? m['user_b_id'] as String
            : m['user_a_id'] as String;
        return !blockedIds.contains(otherUserId);
      });

      // スレッドごとの4クエリが直列だと、マッチ数が多い端末ほど
      // fetchThreadList全体のテール遅延が線形に伸びていた（chunkごとの
      // レイテンシは並列でも、各chunk内は直列4本のため短縮されない）。
      // 依存関係の無いクエリ同士を2段階で並列化する。
      final results = await Future.wait(visibleMatches.map((m) async {
        final matchId = m['match_id'] as String;
        final otherUserId = m['user_a_id'] == myUserId
            ? m['user_b_id'] as String
            : m['user_a_id'] as String;
        final isDissolved = m['dissolved_at'] != null;

        final stage1 = await Future.wait<dynamic>([
          _client
              .from('users')
              .select('nickname, avatar_url')
              .eq('user_id', otherUserId)
              .maybeSingle(),
          _client
              .from('chat_threads')
              .select('thread_id')
              .eq('match_id', matchId)
              .maybeSingle(),
        ]);
        final userRow = stage1[0] as Map<String, dynamic>?;
        final threadRow = stage1[1] as Map<String, dynamic>?;

        if (threadRow == null) {
          return ChatThreadModel(
            matchId: matchId,
            otherUserId: otherUserId,
            otherNickname: userRow?['nickname'] as String?,
            otherAvatarUrl: userRow?['avatar_url'] as String?,
            isDissolved: isDissolved,
          );
        }

        final threadId = threadRow['thread_id'] as String;
        final stage2 = await Future.wait<dynamic>([
          _client
              .from('chat_messages')
              .select()
              .eq('thread_id', threadId)
              .order('created_at', ascending: false)
              .limit(1)
              .maybeSingle(),
          _client
              .from('chat_messages')
              .select('message_id')
              .eq('thread_id', threadId)
              .neq('sender_id', myUserId)
              .filter('read_at', 'is', null),
        ]);
        final lastMsg = stage2[0] as Map<String, dynamic>?;
        final unread = stage2[1] as List;

        return ChatThreadModel(
          matchId: matchId,
          threadId: threadId,
          otherUserId: otherUserId,
          otherNickname: userRow?['nickname'] as String?,
          otherAvatarUrl: userRow?['avatar_url'] as String?,
          lastMessagePreview: lastMsg != null
              ? _previewOf(ChatMessageModel.fromJson(lastMsg))
              : null,
          lastMessageAt: lastMsg != null
              ? DateTime.parse(lastMsg['created_at'] as String).toLocal()
              : null,
          unreadCount: unread.length,
          isDissolved: isDissolved,
        );
      }));

      results.sort((a, b) {
        if (a.lastMessageAt == null && b.lastMessageAt == null) return 0;
        if (a.lastMessageAt == null) return 1;
        if (b.lastMessageAt == null) return -1;
        return b.lastMessageAt!.compareTo(a.lastMessageAt!);
      });
      return results;
    } catch (e, st) {
      debugPrint('[ChatRepo] fetchThreadList failed: $e\n$st');
      rethrow;
    }
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
      return {};
    }
  }

  String _previewOf(ChatMessageModel m) => switch (m.contentType) {
        ChatContentType.photo => '📷 写真',
        ChatContentType.sns => '🔗 SNSアカウント',
        ChatContentType.boardInvite => '🚗 ${m.body ?? 'ツーリング・イベント'}に誘いました',
        ChatContentType.quickReply => m.body ?? '',
        ChatContentType.text => m.body ?? '',
      };

  Future<String?> getThreadId(String matchId) async {
    final row = await _client
        .rpc('get_chat_thread_id', params: {'p_match_id': matchId});
    return row as String?;
  }

  /// チャット履歴の取得（ページング対応）。
  /// - 指定なし: 直近[limit]件を返す（初期表示用。履歴が数千件あっても
  ///   全件取得しないようにする）。
  /// - [before]: そのタイムスタンプより前のメッセージを直近から[limit]件
  ///   （「さらに読み込む」で過去へ遡る用）。
  /// - [after]: そのタイムスタンプより後のメッセージを古い順に全件
  ///   （Realtime受信時等、既に読み込み済みの続きだけを取得する用）。
  /// いずれも戻り値は常に古い→新しい順。
  Future<List<ChatMessageModel>> fetchMessages(
    String threadId, {
    int limit = 200,
    DateTime? before,
    DateTime? after,
  }) async {
    var query = _client.from('chat_messages').select().eq('thread_id', threadId);
    if (before != null) {
      query = query.lt('created_at', before.toUtc().toIso8601String());
    }
    if (after != null) {
      query = query.gt('created_at', after.toUtc().toIso8601String());
    }

    if (after != null) {
      // 追いかけ取得は取りこぼし厳禁のため件数上限を付けない
      final rows = await query
          .order('created_at', ascending: true)
          .withNetworkTimeout();
      return (rows as List)
          .map((r) => ChatMessageModel.fromJson(r as Map<String, dynamic>))
          .toList();
    }

    // 直近[limit]件を新しい順で取ってから、表示用に古い順へ並び替える
    final rows = await query
        .order('created_at', ascending: false)
        .limit(limit)
        .withNetworkTimeout();
    return (rows as List)
        .map((r) => ChatMessageModel.fromJson(r as Map<String, dynamic>))
        .toList()
        .reversed
        .toList();
  }

  Future<void> markRead(String threadId, String myUserId) async {
    await _client
        .from('chat_messages')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('thread_id', threadId)
        .neq('sender_id', myUserId)
        .filter('read_at', 'is', null);
  }

  Future<void> sendText(String matchId, String text) async {
    try {
      await _client.rpc('send_chat_message', params: {
        'p_match_id': matchId,
        'p_content_type': 'text',
        'p_body': text,
        'p_client_message_id': const Uuid().v4(),
      });
    } catch (e, st) {
      debugPrint('[ChatRepo] sendText failed: $e\n$st');
      rethrow;
    }
  }

  Future<void> sendBoardInvite(
      String matchId, String postId, String postTitle) async {
    try {
      await _client.rpc('send_chat_message', params: {
        'p_match_id': matchId,
        'p_content_type': 'board_invite',
        'p_body': postTitle,
        'p_related_post_id': postId,
        'p_client_message_id': const Uuid().v4(),
      });
    } catch (e, st) {
      debugPrint('[ChatRepo] sendBoardInvite failed: $e\n$st');
      rethrow;
    }
  }

  Future<void> sendQuickReply(String matchId, String text) async {
    try {
      await _client.rpc('send_chat_message', params: {
        'p_match_id': matchId,
        'p_content_type': 'quick_reply',
        'p_body': text,
        'p_client_message_id': const Uuid().v4(),
      });
    } catch (e, st) {
      debugPrint('[ChatRepo] sendQuickReply failed: $e\n$st');
      rethrow;
    }
  }

  Future<void> sendSns(String matchId, String snsText) async {
    try {
      await _client.rpc('send_chat_message', params: {
        'p_match_id': matchId,
        'p_content_type': 'sns',
        'p_body': snsText,
        'p_client_message_id': const Uuid().v4(),
      });
    } catch (e, st) {
      debugPrint('[ChatRepo] sendSns failed: $e\n$st');
      rethrow;
    }
  }

  Future<void> sendPhoto(String matchId, String myUserId, File file) async {
    try {
      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}_${file.path.hashCode.abs()}.jpg';
      final objectPath = '$myUserId/$fileName';
      final raw = await file.readAsBytes();
      final bytes = await sanitizeImageBytes(raw);
      await _client.storage.from('chat-photos').uploadBinary(
            objectPath,
            bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );
      final stored = StorageUrlHelper.toStoredPath('chat-photos', objectPath);
      await _client.rpc('send_chat_message', params: {
        'p_match_id': matchId,
        'p_content_type': 'photo',
        'p_photo_path': stored,
        'p_client_message_id': const Uuid().v4(),
      });
    } catch (e, st) {
      debugPrint('[ChatRepo] sendPhoto failed: $e\n$st');
      rethrow;
    }
  }

  /// 送信取り消し（本人のメッセージのみ）。RPC成功後、写真ならStorage実体も
  /// ベストエフォートで削除する（失敗しても取り消し自体は成功扱い）。
  Future<void> unsendMessage(String messageId, {String? photoPath}) async {
    final result = await _client
        .rpc('unsend_chat_message', params: {'p_message_id': messageId});
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
          debugPrint('[ChatRepo] unsendMessage storage cleanup failed: $e');
        }
      }
    }
  }

  /// チャットルーム画面専用のRealtime購読。画面のinitState/disposeスコープで
  /// 生成・破棄すること。未読バッジ用の共通購読(inbox_provider)とは別チャンネル。
  RealtimeChannel subscribeToThread(String threadId, void Function() onChange) {
    return _client
        .channel('chat_messages_$threadId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'thread_id',
            value: threadId,
          ),
          callback: (_) => onChange(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'chat_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'thread_id',
            value: threadId,
          ),
          callback: (_) => onChange(),
        )
        .subscribe();
  }
}

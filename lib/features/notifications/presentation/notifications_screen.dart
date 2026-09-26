import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/supabase/supabase_config.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../boards/presentation/board_detail_screen.dart';
import '../../chat/presentation/chat_room_screen.dart';
import '../../groups/presentation/group_chat_screen.dart';
import '../../groups/presentation/group_detail_screen.dart';
import '../../inbox/presentation/inbox_provider.dart';
import '../../inbox/models/app_notification_model.dart';
import '../../match/data/match_repository.dart';

// ─── モデル ──────────────────────────────────────────────────
enum NotifType {
  encounter,
  match,
  announcement,
  likeReceived,
  customInterest,
  chatMessage,
  groupInvite,
  groupJoinRequest,
  groupInviteDeclined,
  boardInvite,
  boardJoinRequest,
  boardInviteDeclined,
  levelUp,
  groupOwnershipTransferred,
  groupMessage,
}

NotifType _notifTypeFromInbox(AppNotificationType type) => switch (type) {
      AppNotificationType.match => NotifType.match,
      AppNotificationType.likeReceived => NotifType.likeReceived,
      AppNotificationType.customInterest => NotifType.customInterest,
      AppNotificationType.chatMessage => NotifType.chatMessage,
      AppNotificationType.groupInvite => NotifType.groupInvite,
      AppNotificationType.groupJoinRequest => NotifType.groupJoinRequest,
      AppNotificationType.groupInviteDeclined => NotifType.groupInviteDeclined,
      AppNotificationType.boardInvite => NotifType.boardInvite,
      AppNotificationType.boardJoinRequest => NotifType.boardJoinRequest,
      AppNotificationType.boardInviteDeclined => NotifType.boardInviteDeclined,
      AppNotificationType.levelUp => NotifType.levelUp,
      AppNotificationType.groupOwnershipTransferred =>
        NotifType.groupOwnershipTransferred,
      AppNotificationType.groupMessage => NotifType.groupMessage,
      AppNotificationType.unknown => NotifType.announcement,
    };

(String, String) _inboxTitleBody(AppNotificationModel n) => switch (n.type) {
      AppNotificationType.likeReceived => switch (n.payload['boost_type']) {
          'geki_shibu' => ('🌟 激渋！が届きました', '特別ないいねです。あなたの車に興味を持った人がいます'),
          'shibu' => ('🔥 渋！が届きました', '特別ないいねです。あなたの車に興味を持った人がいます'),
          _ => ('❤️ いいねが届きました', 'あなたの車に興味を持った人がいます'),
        },
      AppNotificationType.customInterest => (
          '🔧 気になるカスタムがあります',
          'あなたのカスタムに興味を持った人がいます'
        ),
      AppNotificationType.chatMessage => ('💬 新着メッセージ', 'チャットを確認しましょう'),
      AppNotificationType.groupInvite => ('👥 グループに招待されました', 'グループの詳細を確認しましょう'),
      AppNotificationType.groupJoinRequest => (
          '👥 参加申請が届きました',
          'グループの参加申請を確認しましょう'
        ),
      AppNotificationType.groupInviteDeclined => (
          '👥 招待が辞退されました',
          'グループへの招待が辞退されました'
        ),
      AppNotificationType.boardInvite => ('📋 掲示板に招待されました', '募集の詳細を確認しましょう'),
      AppNotificationType.boardJoinRequest => (
          '📋 参加申請が届きました',
          '募集の参加申請を確認しましょう'
        ),
      AppNotificationType.boardInviteDeclined => (
          '📋 招待が辞退されました',
          '募集への招待が辞退されました'
        ),
      AppNotificationType.levelUp => ('⬆️ レベルアップ！', '相手との関係レベルが上がりました'),
      AppNotificationType.groupOwnershipTransferred => (
          '👑 オーナー権限を受け取りました',
          '${n.payload['group_name'] as String? ?? 'グループ'}のオーナーになりました'
        ),
      AppNotificationType.groupMessage => (
          '👥 ${n.payload['group_name'] as String? ?? 'グループ'}に新着メッセージ',
          'グループチャットを確認しましょう'
        ),
      AppNotificationType.match => ('🎉 マッチしました！', 'マッチタブから詳細を見てみましょう'),
      AppNotificationType.unknown => ('お知らせ', ''),
    };

class NotifItem {
  final NotifType type;
  final String title;
  final String body;
  final DateTime time;
  final String? subLabel; // イベント種別など
  final String? notificationId; // app_notifications 由来の場合のみ
  final Map<String, dynamic> payload;
  final String? relatedUserId;

  const NotifItem({
    required this.type,
    required this.title,
    required this.body,
    required this.time,
    this.subLabel,
    this.notificationId,
    this.payload = const {},
    this.relatedUserId,
  });
}

// ─── プロバイダー ─────────────────────────────────────────────
final notificationsProvider =
    FutureProvider.autoDispose<List<NotifItem>>((ref) async {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return [];

  final client = SupabaseConfig.client;
  final items = <NotifItem>[];

  // ① すれ違い（encounters）
  try {
    final encounters = await client
        .from('encounters')
        .select('encounter_id, time')
        .or('user_a_id.eq.${user.userId},user_b_id.eq.${user.userId}')
        .order('time', ascending: false)
        .limit(20);

    for (final e in encounters) {
      final t = DateTime.parse(e['time'] as String).toLocal();
      items.add(NotifItem(
        type: NotifType.encounter,
        title: '⚡ YAHEしたよ！',
        body: 'どんな人か確認してみよう',
        time: t,
      ));
    }
  } catch (_) {}

  // ② マッチ（matches）
  try {
    final matches = await client
        .from('matches')
        .select('match_id, matched_at')
        .or('user_a_id.eq.${user.userId},user_b_id.eq.${user.userId}')
        .order('matched_at', ascending: false)
        .limit(20);

    for (final m in matches) {
      final t = DateTime.parse(m['matched_at'] as String).toLocal();
      items.add(NotifItem(
        type: NotifType.match,
        title: '🎉 マッチしました！',
        body: 'マッチタブからSNSで繋がりましょう',
        time: t,
      ));
    }
  } catch (_) {}

  // ③ 運営お知らせ（announcements）
  try {
    final announcements = await client
        .from('announcements')
        .select('title, body, type, published_at, created_at')
        .eq('is_published', true)
        .order('published_at', ascending: false)
        .limit(10);

    for (final a in announcements) {
      final t = a['published_at'] != null
          ? DateTime.parse(a['published_at'] as String).toLocal()
          : DateTime.parse(a['created_at'] as String).toLocal();
      items.add(NotifItem(
        type: NotifType.announcement,
        title: a['title'] as String,
        body: a['body'] as String,
        time: t,
        subLabel: _announcementLabel(a['type'] as String? ?? 'info'),
      ));
    }
  } catch (_) {}

  // ④ インボックス（いいね受信・気になるカスタム・チャット・グループ/掲示板招待等）
  //   'match' は上の②で既に表示しているため、二重表示を避けるため除外する。
  try {
    final inboxItems =
        await ref.watch(inboxRepositoryProvider).fetchNotifications();
    for (final n in inboxItems) {
      if (n.type == AppNotificationType.match) continue;
      final (title, body) = _inboxTitleBody(n);
      items.add(NotifItem(
        type: _notifTypeFromInbox(n.type),
        title: title,
        body: body,
        time: n.createdAt,
        notificationId: n.notificationId,
        payload: n.payload,
        relatedUserId: n.relatedUserId,
      ));
    }
  } catch (_) {}

  // 時系列（新しい順）で並べ替え
  items.sort((a, b) => b.time.compareTo(a.time));
  return items;
});

String _announcementLabel(String type) => switch (type) {
      'event' => 'イベント',
      'maintenance' => 'メンテナンス',
      _ => 'お知らせ',
    };

// 未読カウント用プロバイダー
final unreadNotifCountProvider = FutureProvider<int>((ref) async {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return 0;

  final prefs = await SharedPreferences.getInstance();
  final lastReadStr = prefs.getString('notif_last_read_${user.userId}');
  // 未設定時（再インストール直後など）に固定の過去日時(2020年)へフォールバック
  // すると、それまでの全期間のすれ違い・マッチが「未読」扱いになり、
  // バッジに数百件と出てしまっていた。未設定時は「今」を起点にし、
  // 過去の履歴を遡って未読扱いにしない。
  final lastRead = lastReadStr != null
      ? DateTime.tryParse(lastReadStr) ?? DateTime.now()
      : DateTime.now();

  int count = 0;
  final client = SupabaseConfig.client;

  try {
    final encounters = await client
        .from('encounters')
        .select('encounter_id')
        .or('user_a_id.eq.${user.userId},user_b_id.eq.${user.userId}')
        .gt('time', lastRead.toIso8601String());
    count += (encounters as List).length;
  } catch (_) {}

  try {
    final matches = await client
        .from('matches')
        .select('match_id')
        .or('user_a_id.eq.${user.userId},user_b_id.eq.${user.userId}')
        .gt('matched_at', lastRead.toIso8601String());
    count += (matches as List).length;
  } catch (_) {}

  try {
    final announcements = await client
        .from('announcements')
        .select('id')
        .eq('is_published', true)
        .gt('published_at', lastRead.toIso8601String());
    count += (announcements as List).length;
  } catch (_) {}

  try {
    // inboxRepositoryProvider.fetchUnreadCount() を直接呼ぶのではなく
    // unreadInboxCountProvider を watch することで、inboxRealtimeProvider が
    // 新着通知を検知して unreadInboxCountProvider を invalidate するたび、
    // このベルバッジ用カウントも連動して再計算されるようにする
    // （以前はRealtime更新が一切この値に届かず、お知らせ画面を開くまで
    // バッジが更新されなかった）。
    count += await ref.watch(unreadInboxCountProvider.future);
  } catch (_) {}

  return count;
});

// ─── 画面 ─────────────────────────────────────────────────────
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    // 画面を開いたら既読にする
    _markAsRead();
  }

  Future<void> _markAsRead() async {
    final user = ref.read(authNotifierProvider).value;
    if (user == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('notif_last_read_${user.userId}',
        DateTime.now().toUtc().toIso8601String());

    // インボックス由来の通知も既読にする
    try {
      final repo = ref.read(inboxRepositoryProvider);
      final items = await repo.fetchNotifications();
      for (final n in items.where((n) => !n.isRead)) {
        await repo.markAsRead(n.notificationId);
      }
    } catch (_) {}

    // 未読が多いとここまでのawaitが長引く。その間に画面を閉じられていると
    // dispose済みのrefを使うことになりStateErrorになるため、破棄後は何もしない。
    if (!mounted) return;
    ref.invalidate(unreadNotifCountProvider);
    ref.invalidate(unreadInboxCountProvider);
    ref.invalidate(appNotificationsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final notifsAsync = ref.watch(notificationsProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('お知らせ'),
        actions: [
          TextButton(
            onPressed: () {
              ref.invalidate(notificationsProvider);
            },
            child: const Text('更新', style: TextStyle(color: AppColors.primary)),
          ),
        ],
      ),
      body: notifsAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: AppColors.primary)),
        error: (e, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.notifications_none,
                  size: 56, color: AppColors.textMuted),
              const SizedBox(height: 12),
              const Text('読み込みに失敗しました',
                  style: TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 12),
              TextButton(
                  onPressed: () => ref.invalidate(notificationsProvider),
                  child: const Text('再試行')),
            ],
          ),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.notifications_none,
                      size: 64, color: AppColors.textMuted),
                  SizedBox(height: 16),
                  Text('お知らせはありません',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 15)),
                  SizedBox(height: 8),
                  Text('ドライブしてYAHEしよう！',
                      style:
                          TextStyle(color: AppColors.textMuted, fontSize: 13)),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: items.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: AppColors.border, indent: 72),
            itemBuilder: (context, i) => _NotifTile(item: items[i]),
          );
        },
      ),
    );
  }
}

class _NotifTile extends ConsumerWidget {
  final NotifItem item;
  const _NotifTile({required this.item});

  bool get _isTappable => switch (item.type) {
        NotifType.groupInvite ||
        NotifType.groupJoinRequest ||
        NotifType.groupInviteDeclined =>
          true,
        NotifType.groupOwnershipTransferred => true,
        NotifType.boardInvite ||
        NotifType.boardJoinRequest ||
        NotifType.boardInviteDeclined =>
          true,
        NotifType.chatMessage => true,
        NotifType.groupMessage => true,
        _ => false,
      };

  Future<void> _handleTap(BuildContext context, WidgetRef ref) async {
    switch (item.type) {
      case NotifType.groupInvite:
      case NotifType.groupJoinRequest:
      case NotifType.groupInviteDeclined:
      case NotifType.groupOwnershipTransferred:
        final groupId = item.payload['group_id'] as String?;
        if (groupId == null) return;
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => GroupDetailScreen(groupId: groupId)));
        return;
      case NotifType.groupMessage:
        final groupId = item.payload['group_id'] as String?;
        final groupName = item.payload['group_name'] as String? ?? 'グループ';
        if (groupId == null) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                GroupChatScreen(groupId: groupId, groupName: groupName),
          ),
        );
        return;
      case NotifType.boardInvite:
      case NotifType.boardJoinRequest:
      case NotifType.boardInviteDeclined:
        final postId = item.payload['post_id'] as String?;
        if (postId == null) return;
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => BoardDetailScreen(postId: postId)));
        return;
      case NotifType.chatMessage:
        final matchId = item.payload['match_id'] as String?;
        final myId = ref.read(authNotifierProvider).value?.userId;
        if (matchId == null || myId == null) return;
        final match = await MatchRepository().fetchMatch(matchId, myId);
        if (match?.otherUser == null || !context.mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatRoomScreen(
              matchId: matchId,
              otherUserId: match!.otherUser!.userId,
              otherNickname: match.otherUser!.nickname,
            ),
          ),
        );
        return;
      default:
        return;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timeStr = _formatTime(item.time);

    return ListTile(
      onTap: _isTappable ? () => _handleTap(context, ref) : null,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: _Icon(type: item.type),
      title: Row(
        children: [
          Expanded(
            child: Text(
              item.title,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (item.subLabel != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _labelColor(item.type).withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
                border:
                    Border.all(color: _labelColor(item.type).withOpacity(0.4)),
              ),
              child: Text(
                item.subLabel!,
                style: TextStyle(
                  color: _labelColor(item.type),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 3),
          Text(item.body,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13)),
          const SizedBox(height: 4),
          Text(timeStr,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
        ],
      ),
    );
  }

  Color _labelColor(NotifType type) => switch (type) {
        NotifType.encounter => AppColors.primary,
        NotifType.match => Colors.pink,
        NotifType.announcement => Colors.blue,
        NotifType.likeReceived => Colors.pink,
        NotifType.customInterest => AppColors.tagWheel,
        NotifType.chatMessage => AppColors.primary,
        NotifType.groupInvite => const Color(0xFF6C63FF),
        NotifType.groupJoinRequest => const Color(0xFF6C63FF),
        NotifType.groupInviteDeclined => AppColors.textMuted,
        NotifType.boardInvite => AppColors.tagEngine,
        NotifType.boardJoinRequest => AppColors.tagEngine,
        NotifType.boardInviteDeclined => AppColors.textMuted,
        NotifType.levelUp => AppColors.success,
        NotifType.groupOwnershipTransferred => const Color(0xFF6C63FF),
        NotifType.groupMessage => const Color(0xFF6C63FF),
      };

  String _formatTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'たった今';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours}時間前';
    if (diff.inDays < 7) return '${diff.inDays}日前';
    return DateFormat('M月d日').format(t);
  }
}

class _Icon extends StatelessWidget {
  final NotifType type;
  const _Icon({required this.type});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (type) {
      NotifType.encounter => (Icons.swap_horiz, AppColors.primary),
      NotifType.match => (Icons.favorite, Colors.pink),
      NotifType.announcement => (Icons.campaign_outlined, Colors.blue),
      NotifType.likeReceived => (Icons.favorite_border, Colors.pink),
      NotifType.customInterest => (Icons.build_outlined, AppColors.tagWheel),
      NotifType.chatMessage => (Icons.chat_bubble_outline, AppColors.primary),
      NotifType.groupInvite => (
          Icons.group_add_outlined,
          const Color(0xFF6C63FF)
        ),
      NotifType.groupJoinRequest => (
          Icons.group_outlined,
          const Color(0xFF6C63FF)
        ),
      NotifType.groupInviteDeclined => (
          Icons.person_remove_outlined,
          AppColors.textMuted
        ),
      NotifType.boardInvite => (Icons.event_note_outlined, AppColors.tagEngine),
      NotifType.boardJoinRequest => (
          Icons.event_available_outlined,
          AppColors.tagEngine
        ),
      NotifType.boardInviteDeclined => (
          Icons.event_busy_outlined,
          AppColors.textMuted
        ),
      NotifType.levelUp => (Icons.trending_up, AppColors.success),
      NotifType.groupOwnershipTransferred => (
          Icons.stars_outlined,
          const Color(0xFF6C63FF)
        ),
      NotifType.groupMessage => (
          Icons.forum_outlined,
          const Color(0xFF6C63FF)
        ),
    };
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: color, size: 22),
    );
  }
}

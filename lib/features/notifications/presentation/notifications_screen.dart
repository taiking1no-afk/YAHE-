import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/supabase/supabase_config.dart';
import '../../auth/presentation/auth_provider.dart';

// ─── モデル ──────────────────────────────────────────────────
enum NotifType { encounter, match, announcement }

class NotifItem {
  final NotifType type;
  final String title;
  final String body;
  final DateTime time;
  final String? subLabel; // イベント種別など

  const NotifItem({
    required this.type,
    required this.title,
    required this.body,
    required this.time,
    this.subLabel,
  });
}

// ─── プロバイダー ─────────────────────────────────────────────
final notificationsProvider = FutureProvider.autoDispose<List<NotifItem>>((ref) async {
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
        .select()
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
  final lastRead = lastReadStr != null
      ? DateTime.tryParse(lastReadStr) ?? DateTime(2020)
      : DateTime(2020);

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

  return count;
});

// ─── 画面 ─────────────────────────────────────────────────────
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
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
    await prefs.setString(
        'notif_last_read_${user.userId}', DateTime.now().toUtc().toIso8601String());
    ref.invalidate(unreadNotifCountProvider);
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
        loading: () => const Center(child: CircularProgressIndicator(color: AppColors.primary)),
        error: (e, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.notifications_none, size: 56, color: AppColors.textMuted),
              const SizedBox(height: 12),
              const Text('読み込みに失敗しました', style: TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 12),
              TextButton(onPressed: () => ref.invalidate(notificationsProvider), child: const Text('再試行')),
            ],
          ),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.notifications_none, size: 64, color: AppColors.textMuted),
                  SizedBox(height: 16),
                  Text('お知らせはありません', style: TextStyle(color: AppColors.textSecondary, fontSize: 15)),
                  SizedBox(height: 8),
                  Text('ドライブしてYAHEしよう！', style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.border, indent: 72),
            itemBuilder: (context, i) => _NotifTile(item: items[i]),
          );
        },
      ),
    );
  }
}

class _NotifTile extends StatelessWidget {
  final NotifItem item;
  const _NotifTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final timeStr = _formatTime(item.time);

    return ListTile(
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
                border: Border.all(color: _labelColor(item.type).withOpacity(0.4)),
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
          Text(item.body, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          const SizedBox(height: 4),
          Text(timeStr, style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
        ],
      ),
    );
  }

  Color _labelColor(NotifType type) => switch (type) {
        NotifType.encounter => AppColors.primary,
        NotifType.match => Colors.pink,
        NotifType.announcement => Colors.blue,
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/constants/app_colors.dart';
import '../../features/boards/data/board_repository.dart';
import '../../features/boards/models/board_post_model.dart';
import '../../features/boards/presentation/board_detail_screen.dart';

final userUpcomingEventsProvider = FutureProvider.autoDispose
    .family<List<BoardPostModel>, String>((ref, userId) {
  return BoardRepository().fetchUpcomingJoinedPosts(userId);
});

/// 指定ユーザーが参加予定の募集（招待制は除く）。マッチ後プロフィールで使う。
class UserUpcomingEventsSection extends ConsumerWidget {
  final String userId;
  const UserUpcomingEventsSection({super.key, required this.userId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eventsAsync = ref.watch(userUpcomingEventsProvider(userId));

    // `.value` だけを見ていると、ローディング中(null)とエラー時(値が
    // 無いまま確定)を区別できず、取得失敗時に進捗バーが表示され続けていた。
    if (eventsAsync.hasError) return const SizedBox.shrink();
    final events = eventsAsync.value;
    if (events != null && events.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '参加予定のイベント',
            style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          if (events == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(color: AppColors.primary),
            )
          else
            ...events.map((p) => _EventTile(post: p)),
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  final BoardPostModel post;
  const _EventTile({required this.post});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => BoardDetailScreen(postId: post.postId)),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surfaceCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Icon(
                post.postType.value == 'touring'
                    ? Icons.two_wheeler
                    : Icons.event_available_outlined,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      post.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                    if (post.scheduledAt != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        DateFormat('M月d日 HH:mm').format(post.scheduledAt!),
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right,
                  size: 18, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

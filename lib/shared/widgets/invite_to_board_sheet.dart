import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/constants/app_colors.dart';
import '../../features/auth/presentation/auth_provider.dart';
import '../../features/boards/data/board_repository.dart';
import '../../features/boards/models/board_post_model.dart';
import '../../features/chat/data/chat_repository.dart';
import '../../features/groups/data/group_repository.dart';

/// 自分が参加中のツーリング・イベント募集から1件選んで、指定した相手（複数可）を誘う。
/// マッチ画面・チャット画面・プロフィール・グループチャットの「誘う」ボタンから共通利用する。
///
/// [chatMatchId] / [chatGroupId] を指定すると、誘いに成功した際にそのチャット
/// スレッド／グループチャットにも「誘いました」メッセージを残す
/// （チャット画面・グループチャット画面からの呼び出し時のみ指定する）。
Future<void> showInviteToBoardSheet(
  BuildContext context,
  WidgetRef ref, {
  required List<String> targetUserIds,
  String? chatMatchId,
  String? chatGroupId,
}) async {
  final myId = ref.read(authNotifierProvider).value?.userId;
  if (myId == null || targetUserIds.isEmpty) return;

  final posts = await BoardRepository().fetchMyJoinedPosts(myId);
  if (!context.mounted) return;

  if (posts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('先に掲示板でツーリング・イベントに参加してから誘えます')),
    );
    return;
  }

  final picked = await showModalBottomSheet<BoardPostModel>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (ctx, scrollController) => Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('誘う募集を選ぶ',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: ListView.separated(
              controller: scrollController,
              itemCount: posts.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, color: AppColors.border),
              itemBuilder: (context, i) {
                final p = posts[i];
                return ListTile(
                  leading: Icon(
                    p.postType == BoardPostType.touring
                        ? Icons.directions_car_outlined
                        : Icons.event_outlined,
                    color: AppColors.primary,
                  ),
                  title: Text(p.title,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: p.scheduledAt != null
                      ? Text(DateFormat('M月d日 HH:mm').format(p.scheduledAt!),
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textMuted))
                      : null,
                  onTap: () => Navigator.pop(ctx, p),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );

  if (picked == null || !context.mounted) return;

  var successCount = 0;
  for (final userId in targetUserIds) {
    try {
      await BoardRepository().invite(picked.postId, userId);
      successCount++;
    } catch (_) {}
  }

  if (successCount > 0) {
    try {
      if (chatMatchId != null) {
        await ChatRepository()
            .sendBoardInvite(chatMatchId, picked.postId, picked.title);
      } else if (chatGroupId != null) {
        await GroupRepository()
            .sendGroupBoardInvite(chatGroupId, picked.postId, picked.title);
      }
    } catch (_) {}
  }

  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
        content: Text(
            successCount > 0 ? '「${picked.title}」に誘いました' : '誘いの送信に失敗しました')),
  );
}

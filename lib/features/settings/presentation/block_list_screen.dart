import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/constants/app_colors.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../../shared/providers/global_realtime_providers.dart';
import '../../profile/data/user_repository.dart';

final _blockListProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return [];
  final repo = UserRepository();
  return repo.fetchBlockList(user.userId);
});

class BlockListScreen extends ConsumerWidget {
  const BlockListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocksAsync = ref.watch(_blockListProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('ブロックリスト')),
      body: blocksAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: AppColors.primary)),
        error: (e, _) => const Center(child: Text('読み込みに失敗しました')),
        data: (blocks) {
          if (blocks.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.block, size: 56, color: AppColors.textMuted),
                  SizedBox(height: 12),
                  Text('ブロックしているユーザーはいません',
                      style: TextStyle(color: AppColors.textSecondary)),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: blocks.length,
            itemBuilder: (context, i) {
              final block = blocks[i];
              final date = DateFormat('yyyy/MM/dd')
                  .format(DateTime.parse(block['created_at']).toLocal());
              final nickname = block['nickname'] as String;
              final avatarUrl = block['avatar_url'] as String?;
              final letter = CircleAvatar(
                backgroundColor: AppColors.border,
                child: Text(
                  nickname.isNotEmpty
                      ? nickname.substring(0, 1).toUpperCase()
                      : '?',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              );
              return ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                leading: (avatarUrl != null && avatarUrl.isNotEmpty)
                    ? ClipOval(
                        child: SignedStorageImage(
                          storedReference: avatarUrl,
                          defaultBucket: 'profile-photos',
                          width: 40,
                          height: 40,
                          placeholder: letter,
                        ),
                      )
                    : letter,
                title: Text(block['nickname'] as String,
                    style: const TextStyle(color: AppColors.textPrimary)),
                subtitle: Text('$date にブロック',
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12)),
                trailing: OutlinedButton(
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        backgroundColor: AppColors.surface,
                        title: const Text('ブロック解除'),
                        content: Text('${block['nickname']} のブロックを解除しますか？'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('キャンセル')),
                          ElevatedButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('解除')),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      try {
                        await UserRepository()
                            .unblock(block['block_id'] as String);
                        ref.invalidate(_blockListProvider);
                        // 解除でいいね・マッチ・募集は再表示される（すれ違いは要再遭遇）
                        invalidateAfterBlockChange(ref);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('解除に失敗しました: $e')),
                          );
                        }
                      }
                    }
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: const BorderSide(color: AppColors.error),
                    minimumSize: const Size(72, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: const Text('解除', style: TextStyle(fontSize: 13)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../features/match/presentation/match_screen.dart';
import 'signed_storage_image.dart';

/// マッチ済みユーザーから1人選ぶボトムシート。
/// グループ招待・ツーリング/イベント誘いなど、マッチ相手を対象にする導線で共通利用する。
Future<String?> showMatchedUserPicker(
  BuildContext context,
  WidgetRef ref, {
  String title = 'マッチ済みの相手から選ぶ',
  Set<String> excludeUserIds = const {},
}) async {
  final matches = await ref.read(matchesProvider.future);
  final candidates = matches
      .where((m) =>
          m.otherUser != null && !excludeUserIds.contains(m.otherUser!.userId))
      .toList();

  if (!context.mounted) return null;

  if (candidates.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('誘えるマッチ相手がいません')),
    );
    return null;
  }

  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (ctx, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: ListView.separated(
              controller: scrollController,
              itemCount: candidates.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, color: AppColors.border),
              itemBuilder: (context, i) {
                final u = candidates[i].otherUser!;
                return ListTile(
                  leading: (u.avatarUrl != null && u.avatarUrl!.isNotEmpty)
                      ? ClipOval(
                          child: SignedStorageImage(
                            storedReference: u.avatarUrl!,
                            defaultBucket: 'profile-photos',
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                          ),
                        )
                      : CircleAvatar(
                          backgroundColor: AppColors.primary.withOpacity(0.15),
                          child: Text(u.nickname.isNotEmpty
                              ? u.nickname.substring(0, 1).toUpperCase()
                              : 'U'),
                        ),
                  title: Text(u.nickname),
                  onTap: () => Navigator.pop(ctx, u.userId),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

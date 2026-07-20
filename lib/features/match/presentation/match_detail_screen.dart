import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/external_link.dart';
import '../../../features/auth/presentation/auth_provider.dart';
import '../../../features/profile/data/user_repository.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/vehicle_detail_card.dart';
import '../../home/presentation/home_provider.dart';
import '../../likes/presentation/likes_screen.dart';
import '../models/match_model.dart';
import 'match_screen.dart';

class MatchDetailScreen extends ConsumerWidget {
  final MatchModel match;
  const MatchDetailScreen({super.key, required this.match});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = match.otherUser;
    final vehicles = match.otherVehicles;
    final currentUser = ref.watch(authNotifierProvider).value;
    final otherUserId = match.otherUser?.userId ?? match.userBId;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(user?.nickname ?? 'マッチ詳細'),
        actions: [
          if (currentUser != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              color: AppColors.surface,
              onSelected: (value) async {
                if (value == 'block') {
                  await _showBlockDialog(context, ref, currentUser.userId, otherUserId);
                } else if (value == 'report') {
                  await _showReportDialog(context, currentUser.userId, otherUserId);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'block',
                  child: Row(
                    children: [
                      Icon(Icons.block, color: AppColors.error, size: 18),
                      SizedBox(width: 10),
                      Text('ブロック', style: TextStyle(color: AppColors.error)),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'report',
                  child: Row(
                    children: [
                      Icon(Icons.flag_outlined, color: AppColors.textSecondary, size: 18),
                      SizedBox(width: 10),
                      Text('通報', style: TextStyle(color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ─── プロフィールヘッダー
            Container(
              color: AppColors.surface,
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  // アバター
                  _Avatar(avatarUrl: user?.avatarUrl, nickname: user?.nickname ?? 'U'),
                  const SizedBox(height: 14),
                  Text(
                    user?.nickname ?? '名無し',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (user?.area != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.location_on_outlined, size: 14, color: AppColors.textMuted),
                        const SizedBox(width: 3),
                        Text(user!.area!, style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
                      ],
                    ),
                  ],
                  const SizedBox(height: 6),
                  // マッチ日時バッジ
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.primary.withOpacity(0.3)),
                    ),
                    child: Text(
                      'マッチ日: ${DateFormat('yyyy年M月d日').format(match.matchedAt)}',
                      style: const TextStyle(color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (user?.comment != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '"${user!.comment!}"',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                          height: 1.6,
                          fontStyle: FontStyle.italic,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // ─── SNSリンク
            if (user != null && user.snsLinks.isNotEmpty) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('SNS', style: TextStyle(color: AppColors.textMuted, fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    ...user.snsLinks.map((link) {
                      final platformLabel = AppConstants.snsPlatforms
                          .firstWhere((p) => p['key'] == link.platform, orElse: () => {'label': 'SNS'})['label']!;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: GestureDetector(
                          onTap: () => openExternalLink(context, link.url),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(platformLabel,
                                      style: const TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.w600)),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    link.label.isNotEmpty ? link.label : link.url,
                                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const Icon(Icons.open_in_new, size: 14, color: AppColors.textMuted),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],

            // ─── 相手の愛車（全台）
            if (vehicles.isNotEmpty) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '愛車${vehicles.length > 1 ? ' (${vehicles.length}台)' : ''}',
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    ...vehicles.map((v) => VehicleDetailCard(vehicle: v)),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Future<void> _showBlockDialog(BuildContext context, WidgetRef ref, String currentUserId, String otherUserId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('ブロックしますか？'),
        content: const Text('このユーザーのすれ違い・マッチが表示されなくなります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('ブロック'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      try {
        await UserRepository().block(currentUserId, otherUserId);
        // タイムライン各所から即時に消すため再取得を促す
        ref.invalidate(matchesProvider);
        ref.invalidate(encountersProvider);
        ref.invalidate(sentLikesProvider);
        ref.invalidate(receivedLikesProvider);
        if (!context.mounted) return;
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ブロックしました')),
        );
      } catch (_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('エラーが発生しました')),
        );
      }
    }
  }

  Future<void> _showReportDialog(BuildContext context, String currentUserId, String otherUserId) async {
    String? selectedCategory;
    final detailController = TextEditingController();

    final submitted = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('通報'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('理由を選んでください', style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
              const SizedBox(height: 12),
              ...{
                'inappropriate_photo': '不適切な写真',
                'impersonation': 'なりすまし',
                'spam': 'スパム',
                'other': 'その他',
              }.entries.map((e) => RadioListTile<String>(
                    value: e.key,
                    groupValue: selectedCategory,
                    title: Text(e.value, style: const TextStyle(fontSize: 14)),
                    activeColor: AppColors.primary,
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) => setState(() => selectedCategory = v),
                  )),
              const SizedBox(height: 8),
              TextField(
                controller: detailController,
                decoration: const InputDecoration(
                  hintText: '詳細（任意）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                maxLines: 2,
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              onPressed: selectedCategory == null ? null : () => Navigator.pop(ctx, true),
              child: const Text('送信'),
            ),
          ],
        ),
      ),
    );

    if (submitted == true && selectedCategory != null && context.mounted) {
      try {
        await UserRepository().report(
          reporterId: currentUserId,
          targetId: otherUserId,
          category: selectedCategory!,
          detail: detailController.text,
        );
        if (!context.mounted) return;
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('通報を送信しました。ありがとうございます。')),
        );
      } catch (_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('エラーが発生しました')),
        );
      }
    }
    detailController.dispose();
  }
}

class _Avatar extends StatelessWidget {
  final String? avatarUrl;
  final String nickname;
  const _Avatar({this.avatarUrl, required this.nickname});

  @override
  Widget build(BuildContext context) {
    if (avatarUrl != null && avatarUrl!.isNotEmpty) {
      return ClipOval(
        child: SignedStorageImage(
          storedReference: avatarUrl!,
          defaultBucket: 'profile-photos',
          width: 80,
          height: 80,
          fit: BoxFit.cover,
          placeholder: _initials(),
        ),
      );
    }
    return _initials();
  }

  Widget _initials() => CircleAvatar(
        radius: 40,
        backgroundColor: AppColors.primary.withOpacity(0.15),
        child: Text(
          nickname.isNotEmpty ? nickname.substring(0, 1).toUpperCase() : 'U',
          style: const TextStyle(color: AppColors.primary, fontSize: 30, fontWeight: FontWeight.w900),
        ),
      );
}

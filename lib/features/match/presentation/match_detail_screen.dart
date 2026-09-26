import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/external_link.dart';
import '../../../features/auth/presentation/auth_provider.dart';
import '../../../features/profile/data/user_repository.dart';
import '../../../shared/models/encounter_stats.dart';
import '../../../shared/providers/global_realtime_providers.dart';
import '../../chat/presentation/chat_room_screen.dart';
import '../data/match_repository.dart';
import '../../relationship/presentation/pair_level_badge.dart';
import '../../../shared/widgets/invite_to_board_sheet.dart';
import '../../../shared/widgets/public_badge.dart';
import '../../../shared/widgets/report_dialog.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/user_groups_section.dart';
import '../../../shared/widgets/user_upcoming_events_section.dart';
import '../../../shared/widgets/vehicle_detail_card.dart';
import '../models/match_model.dart';

class MatchDetailScreen extends ConsumerWidget {
  final MatchModel match;
  const MatchDetailScreen({super.key, required this.match});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = match.otherUser;
    final vehicles = match.otherVehicles;
    final currentUser = ref.watch(authNotifierProvider).value;
    final otherUserId = match.otherUser?.userId ?? match.userBId;
    // Gear Rの「インサイトアクティビティ」用に閲覧数を記録する（サーバー側で1日1回に重複排除）
    UserRepository().recordProfileView(otherUserId);
    final isBlocked =
        (ref.watch(blockedUserIdsProvider).value ?? const <String>{})
            .contains(otherUserId);
    final isBlockedByOther =
        ref.watch(blockedByUserProvider(otherUserId)).value ?? false;
    final contactBlocked = isBlocked || isBlockedByOther;
    final isDissolved = match.isDissolved;

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
                  await _showBlockDialog(
                      context, ref, currentUser.userId, otherUserId);
                } else if (value == 'report') {
                  await showReportDialog(context,
                      targetType: 'user', targetId: otherUserId);
                } else if (value == 'dissolve') {
                  await _showDissolveDialog(context, ref);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: isBlocked ? null : 'block',
                  enabled: !isBlocked,
                  child: Row(
                    children: [
                      Icon(Icons.block,
                          color:
                              isBlocked ? AppColors.textMuted : AppColors.error,
                          size: 18),
                      const SizedBox(width: 10),
                      Text(
                        isBlocked ? 'ブロック済み' : 'ブロック',
                        style: TextStyle(
                            color: isBlocked
                                ? AppColors.textMuted
                                : AppColors.error),
                      ),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'report',
                  child: Row(
                    children: [
                      Icon(Icons.flag_outlined,
                          color: AppColors.textSecondary, size: 18),
                      SizedBox(width: 10),
                      Text('通報',
                          style: TextStyle(color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                if (!isDissolved)
                  const PopupMenuItem(
                    value: 'dissolve',
                    child: Row(
                      children: [
                        Icon(Icons.heart_broken_outlined,
                            color: AppColors.error, size: 18),
                        SizedBox(width: 10),
                        Text('マッチを解除',
                            style: TextStyle(color: AppColors.error)),
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
                  _Avatar(
                      avatarUrl: user?.avatarUrl,
                      nickname: user?.nickname ?? 'U'),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          user?.nickname ?? '名無し',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (user?.isPrivate == false) ...[
                        const SizedBox(width: 6),
                        const PublicBadge(),
                      ],
                    ],
                  ),
                  if (user?.area != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.location_on_outlined,
                            size: 14, color: AppColors.textMuted),
                        const SizedBox(width: 3),
                        Text(user!.area!,
                            style: const TextStyle(
                                color: AppColors.textMuted, fontSize: 13)),
                      ],
                    ),
                  ],
                  const SizedBox(height: 6),
                  // マッチ日時バッジ
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: AppColors.primary.withOpacity(0.3)),
                    ),
                    child: Text(
                      'マッチ日: ${DateFormat('yyyy年M月d日').format(match.matchedAt)}',
                      style: const TextStyle(
                          color: AppColors.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
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

            // ─── ヤエー人数（累計・本日）
            if (user != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _EncounterStatsSection(userId: user.userId),
              ),
              const SizedBox(height: 16),
            ],

            // ─── マッチ解消状態の表示
            if (isDissolved)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.textMuted.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.heart_broken_outlined,
                          color: AppColors.textMuted, size: 18),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'マッチは解消されています。過去のメッセージのみ閲覧できます',
                          style: TextStyle(
                              color: AppColors.textMuted,
                              fontWeight: FontWeight.w700,
                              fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // ─── ブロック状態の表示
            if (contactBlocked)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.textMuted.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.block,
                          color: AppColors.textMuted, size: 18),
                      const SizedBox(width: 10),
                      Text(
                        isBlockedByOther ? 'ブロックされています' : 'ブロック中',
                        style: const TextStyle(
                            color: AppColors.textMuted,
                            fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),

            // ─── チャット
            if (user != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatRoomScreen(
                          matchId: match.matchId,
                          otherUserId: user.userId,
                          otherNickname: user.nickname,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.chat_bubble_outline, size: 18),
                    label: const Text('チャットを始める'),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: (contactBlocked || isDissolved)
                        ? null
                        : () => showInviteToBoardSheet(context, ref,
                            targetUserIds: [user.userId],
                            chatMatchId: match.matchId),
                    icon: const Icon(Icons.event_available_outlined, size: 18),
                    label: const Text('ツーリング・イベントに誘う'),
                  ),
                ),
              ),
              if (currentUser != null) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: PairLevelBadge(
                    myUserId: currentUser.userId,
                    otherUserId: user.userId,
                    otherNickname: user.nickname,
                  ),
                ),
              ],
              UserGroupsSection(userId: user.userId, showSearchLink: false),
              UserUpcomingEventsSection(userId: user.userId),
              const SizedBox(height: 12),
            ],

            // ─── 公開SNSリンク（Gear R限定・マッチ後は常に相手に公開される）
            if (user?.publicSnsLink != null) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.public, size: 13, color: Color(0xFF6C63FF)),
                        SizedBox(width: 4),
                        Text('公開SNS',
                            style: TextStyle(
                                color: Color(0xFF6C63FF),
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: () => openExternalLink(
                        context,
                        user.publicSnsLink!.url,
                        ownerUserId: otherUserId,
                        platform: user.publicSnsLink!.platform,
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                user!.publicSnsLink!.label?.isNotEmpty == true
                                    ? user.publicSnsLink!.label!
                                    : user.publicSnsLink!.url,
                                style: const TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(Icons.open_in_new,
                                size: 14, color: AppColors.textMuted),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // ─── SNSリンク
            if (user != null && user.snsLinks.isNotEmpty) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('SNS',
                        style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    ...user.snsLinks.map((link) {
                      final platformLabel = AppConstants.snsPlatforms
                          .firstWhere((p) => p['key'] == link.platform,
                              orElse: () => {'label': 'SNS'})['label']!;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: GestureDetector(
                          onTap: () => openExternalLink(
                            context,
                            link.url,
                            ownerUserId: otherUserId,
                            platform: link.platform,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(platformLabel,
                                      style: const TextStyle(
                                          color: AppColors.primary,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600)),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    link.label.isNotEmpty
                                        ? link.label
                                        : link.url,
                                    style: const TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 13),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const Icon(Icons.open_in_new,
                                    size: 14, color: AppColors.textMuted),
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
                      style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    ...vehicles.map((v) => VehicleDetailCard(
                          vehicle: v,
                          customInterestOwnerUserId: user?.userId,
                        )),
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

  Future<void> _showDissolveDialog(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('マッチを解除しますか？'),
        content: const Text(
          '解除すると新しいメッセージは送れなくなりますが、これまでのチャット履歴は残ります。'
          '再び相互にいいねすると、同じ相手と再マッチできます。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('解除する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await MatchRepository().dissolveMatch(match.matchId);
      if (!context.mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('マッチを解除しました')),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('エラーが発生しました')),
      );
    }
  }

  Future<void> _showBlockDialog(BuildContext context, WidgetRef ref,
      String currentUserId, String otherUserId) async {
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
        invalidateAfterBlockChange(ref);
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
          style: const TextStyle(
              color: AppColors.primary,
              fontSize: 30,
              fontWeight: FontWeight.w900),
        ),
      );
}

// ─── ヤエー人数（累計・本日）
class _EncounterStatsSection extends StatelessWidget {
  final String userId;
  const _EncounterStatsSection({required this.userId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EncounterStats>(
      future: UserRepository().fetchEncounterStats(userId),
      builder: (context, snapshot) {
        final stats = snapshot.data;
        if (stats == null) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Expanded(
                  child: _StatItem(label: '累計ヤエー', value: stats.totalPeople)),
              Container(width: 1, height: 28, color: AppColors.border),
              Expanded(
                  child: _StatItem(label: '今日のヤエー', value: stats.todayPeople)),
            ],
          ),
        );
      },
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final int value;
  const _StatItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          '$value人',
          style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
      ],
    );
  }
}

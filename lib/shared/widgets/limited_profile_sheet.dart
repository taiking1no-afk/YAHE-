import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../core/utils/external_link.dart';
import '../../features/profile/data/user_repository.dart';
import '../../features/vehicle/models/vehicle.dart';
import '../../shared/models/user_model.dart';
import '../../shared/models/encounter_stats.dart';
import 'signed_storage_image.dart';
import 'vehicle_detail_card.dart';
import 'vehicle_photo_viewer.dart';

/// YAHEタブ・いいねタブのタップ時に表示する限定プロフィール
/// 表示内容：アイコン（車両写真）・名前（車種名）・愛車情報のみ
/// ニックネーム・SNS・コメントは非表示（マッチ後のみ開示）
class LimitedProfileSheet extends StatelessWidget {
  final Vehicle? vehicle;
  final List<Vehicle> otherVehicles;
  final UserModel? otherUser;
  final bool iLiked;
  final bool isMatched;
  final VoidCallback? onLike;
  final String? otherUserId;
  final String? currentUserId;
  final VoidCallback? onBlocked;

  const LimitedProfileSheet({
    super.key,
    this.vehicle,
    this.otherVehicles = const [],
    this.otherUser,
    required this.iLiked,
    required this.isMatched,
    this.onLike,
    this.otherUserId,
    this.currentUserId,
    this.onBlocked,
  });

  static Future<void> show(
    BuildContext context, {
    Vehicle? vehicle,
    List<Vehicle> otherVehicles = const [],
    UserModel? otherUser,
    required bool iLiked,
    required bool isMatched,
    VoidCallback? onLike,
    String? otherUserId,
    String? currentUserId,
    VoidCallback? onBlocked,
  }) {
    return Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => LimitedProfileSheet(
          vehicle: vehicle,
          otherVehicles: otherVehicles,
          otherUser: otherUser,
          iLiked: iLiked,
          isMatched: isMatched,
          onLike: onLike,
          otherUserId: otherUserId,
          currentUserId: currentUserId,
          onBlocked: onBlocked,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canReport = otherUserId != null && currentUserId != null;
    final title = otherUser?.nickname ?? (vehicle?.displayName ?? 'プロフィール');

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        actions: [
          if (canReport)
            _ReportMenu(
              otherUserId: otherUserId!,
              currentUserId: currentUserId!,
              onBlocked: onBlocked,
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // メイン写真（大きく）
            _VehiclePhoto(vehicle: vehicle),

            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ニックネーム + 認証バッジ
                  if (otherUser != null) ...[
                    Text(
                      otherUser!.nickname,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (otherUser!.isVerified && otherUser!.verifiedLabel != null && otherUser!.verifiedLabel!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF6C63FF).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.35)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.verified, color: Color(0xFF6C63FF), size: 16),
                            const SizedBox(width: 5),
                            Text(
                              otherUser!.verifiedLabel!,
                              style: const TextStyle(
                                color: Color(0xFF6C63FF),
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                  ],

                  // ヤエー人数（累計・本日）
                  if (otherUserId != null) ...[
                    _EncounterStatsSection(userId: otherUserId!),
                    const SizedBox(height: 16),
                  ],

                  // 一言コメント
                  if (otherUser?.comment != null && otherUser!.comment!.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Text(
                        '"${otherUser!.comment!}"',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 15,
                          fontStyle: FontStyle.italic,
                          height: 1.6,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // 愛車セクション
                  if (otherVehicles.isNotEmpty) ...[
                    const Text(
                      '愛車',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    ...otherVehicles.map((v) => VehicleDetailCard(vehicle: v)),
                  ] else if (vehicle != null) ...[
                    const Text(
                      '愛車',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    VehicleDetailCard(vehicle: vehicle!),
                  ],

                  const SizedBox(height: 24),

                  // SNS（開示が許可されている場合のみ snsLinks が入る）
                  if (otherUser != null && otherUser!.snsLinks.isNotEmpty) ...[
                    const Text(
                      'SNS',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    ...otherUser!.snsLinks.map((link) => _SnsLinkRow(link: link)),
                    const SizedBox(height: 16),
                  ]
                  // プライバシー案内（SNS未開示かつ未マッチのときのみ）
                  else if (!isMatched)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.lock_outline, size: 16, color: AppColors.textMuted),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'SNSリンクはマッチング後に開示されます',
                              style: TextStyle(color: AppColors.textMuted, fontSize: 13, height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ),

                  const SizedBox(height: 32),
                ],
              ),
            ),
          ],
        ),
      ),
      // いいね/マッチボタンを画面下部に固定
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: isMatched
              ? Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.primary.withOpacity(0.3)),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.favorite, color: AppColors.primary, size: 20),
                      SizedBox(width: 8),
                      Text('マッチ済み', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700, fontSize: 16)),
                    ],
                  ),
                )
              : iLiked
                  ? OutlinedButton.icon(
                      onPressed: null,
                      icon: const Icon(Icons.favorite, size: 20),
                      label: const Text('いいね済み', style: TextStyle(fontSize: 16)),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 52),
                      ),
                    )
                  : ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        onLike?.call();
                      },
                      icon: const Icon(Icons.favorite_border, size: 20),
                      label: const Text('いいねする', style: TextStyle(fontSize: 16)),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 52),
                      ),
                    ),
        ),
      ),
    );
  }
}

// ヤエー人数（累計・本日）表示
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
              Expanded(child: _StatItem(label: '累計ヤエー', value: stats.totalPeople)),
              Container(width: 1, height: 28, color: AppColors.border),
              Expanded(child: _StatItem(label: '今日のヤエー', value: stats.todayPeople)),
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
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

// ブロック/通報メニュー
class _ReportMenu extends StatelessWidget {
  final String otherUserId;
  final String currentUserId;
  final VoidCallback? onBlocked;

  const _ReportMenu({
    required this.otherUserId,
    required this.currentUserId,
    this.onBlocked,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, color: AppColors.textMuted),
      color: AppColors.surface,
      onSelected: (value) async {
        if (value == 'block') {
          await _showBlockDialog(context);
        } else if (value == 'report') {
          await _showReportDialog(context);
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
    );
  }

  Future<void> _showBlockDialog(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('ブロックしますか？'),
        content: const Text('このユーザーのすれ違いが表示されなくなります。'),
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
        onBlocked?.call();
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

  Future<void> _showReportDialog(BuildContext context) async {
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

// SNSリンク行（開示許可時のみ表示）
class _SnsLinkRow extends StatelessWidget {
  final SnsLink link;
  const _SnsLinkRow({required this.link});

  @override
  Widget build(BuildContext context) {
    final platformLabel = AppConstants.snsPlatforms
        .firstWhere((p) => p['key'] == link.platform,
            orElse: () => {'label': 'SNS'})['label']!;
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
                    style: const TextStyle(
                        color: AppColors.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  link.label.isNotEmpty ? '$platformLabel：${link.label}' : link.url,
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
  }
}

// シート内の車両行
class _SheetVehicleRow extends StatelessWidget {
  final Vehicle vehicle;
  const _SheetVehicleRow({required this.vehicle});

  @override
  Widget build(BuildContext context) {
    final typeLabel = vehicle.vehicleType == VehicleType.bike ? '🏍' : '🚗';
    final tags = vehicle.tags.take(3).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: vehicle.photos.isNotEmpty
                ? SignedStorageImage(
                    storedReference: vehicle.photos.first,
                    width: 60,
                    height: 44,
                    fit: BoxFit.cover,
                    placeholder: _placeholder(),
                  )
                : _placeholder(),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(typeLabel, style: const TextStyle(fontSize: 13)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        vehicle.displayName,
                        style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(spacing: 4, runSpacing: 4, children: tags.map((t) => _SheetTag(t)).toList()),
                ],
                if (vehicle.customContent != null && vehicle.customContent!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(vehicle.customContent!, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder() => Container(width: 60, height: 44, color: AppColors.surface,
      child: const Icon(Icons.directions_car, color: AppColors.textMuted, size: 22));
}

class _SheetTag extends StatelessWidget {
  final String label;
  const _SheetTag(this.label);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.primary.withOpacity(0.25)),
        ),
        child: Text(label, style: const TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.w600)),
      );
}

class _VehiclePhoto extends StatelessWidget {
  final Vehicle? vehicle;
  const _VehiclePhoto({this.vehicle});

  @override
  Widget build(BuildContext context) {
    final photos = vehicle?.photos ?? const [];
    final photo = photos.firstOrNull;
    if (photo != null) {
      return GestureDetector(
        onTap: () => VehiclePhotoViewer.show(context, photos: photos),
        child: SignedStorageImage(
          storedReference: photo,
          width: double.infinity,
          height: 240,
          fit: BoxFit.cover,
          placeholder: _placeholder(),
        ),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() => Container(
        height: 180,
        color: AppColors.border,
        child: const Center(
          child: Icon(Icons.directions_car_outlined, color: AppColors.textMuted, size: 56),
        ),
      );
}

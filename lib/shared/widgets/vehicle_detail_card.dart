import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../features/vehicle/models/vehicle.dart';
import 'signed_storage_image.dart';
import 'vehicle_photo_viewer.dart';

/// 愛車1台分の詳細カード（写真ギャラリー + 全情報）
/// プロフィール（自分・相手）・マッチ詳細で共通利用する
class VehicleDetailCard extends StatefulWidget {
  final Vehicle vehicle;
  const VehicleDetailCard({super.key, required this.vehicle});

  @override
  State<VehicleDetailCard> createState() => _VehicleDetailCardState();
}

class _VehicleDetailCardState extends State<VehicleDetailCard> {
  int _currentPhoto = 0;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vehicle;
    final typeLabel = v.vehicleType == VehicleType.bike ? '🏍 バイク' : '🚗 車';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 写真ギャラリー（タップで全画面ズーム表示）
          if (v.photos.isNotEmpty)
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
              child: Stack(
                children: [
                  SizedBox(
                    height: 220,
                    child: PageView.builder(
                      controller: _pageController,
                      itemCount: v.photos.length,
                      onPageChanged: (i) { if (mounted) setState(() => _currentPhoto = i); },
                      itemBuilder: (_, i) => GestureDetector(
                        onTap: () => VehiclePhotoViewer.show(
                          context,
                          photos: v.photos,
                          initialIndex: i,
                        ),
                        child: SignedStorageImage(
                          storedReference: v.photos[i],
                          width: double.infinity,
                          height: 220,
                          fit: BoxFit.cover,
                          placeholder: Container(height: 220, color: AppColors.shimmerBase),
                        ),
                      ),
                    ),
                  ),
                  // ページドット
                  if (v.photos.length > 1)
                    Positioned(
                      bottom: 10,
                      left: 0,
                      right: 0,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(v.photos.length, (i) => Container(
                          width: i == _currentPhoto ? 16 : 6,
                          height: 6,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: i == _currentPhoto
                                ? AppColors.primary
                                : Colors.white.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        )),
                      ),
                    ),
                  // 枚数バッジ
                  if (v.photos.length > 1)
                    Positioned(
                      top: 10,
                      right: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${_currentPhoto + 1} / ${v.photos.length}',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                ],
              ),
            )
          else
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
              child: Container(
                height: 120,
                color: AppColors.surface,
                child: const Center(child: Icon(Icons.directions_car, color: AppColors.textMuted, size: 48)),
              ),
            ),

          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 車種名
                Text(
                  v.displayName,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                // タイプ + 年式
                Row(
                  children: [
                    Text(typeLabel, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                    if (v.year != null) ...[
                      const SizedBox(width: 10),
                      const Icon(Icons.calendar_today_outlined, size: 12, color: AppColors.textMuted),
                      const SizedBox(width: 3),
                      Text('${v.year}年式', style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                    ],
                  ],
                ),
                // タグ
                if (v.tags.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: v.tags.map((t) => _DetailTag(t)).toList(),
                  ),
                ],
                // カスタム説明（全文）
                if (v.customContent != null && v.customContent!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: AppColors.border),
                  const SizedBox(height: 12),
                  Text(
                    v.customContent!,
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.6),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailTag extends StatelessWidget {
  final String label;
  const _DetailTag(this.label);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.primary.withOpacity(0.3)),
        ),
        child: Text(label, style: const TextStyle(color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

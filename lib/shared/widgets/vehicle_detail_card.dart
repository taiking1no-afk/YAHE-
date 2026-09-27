import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../core/constants/app_colors.dart';
import '../../core/utils/focal_point.dart';
import '../../features/vehicle/data/vehicle_repository.dart';
import '../../features/vehicle/models/vehicle.dart';
import '../../features/vehicle/models/vehicle_customization_part.dart';
import 'signed_storage_image.dart';
import 'vehicle_photo_viewer.dart';

/// 愛車1台分の詳細カード（写真ギャラリー + 全情報）
/// プロフィール（自分・相手）・マッチ詳細で共通利用する
class VehicleDetailCard extends StatefulWidget {
  final Vehicle vehicle;

  /// マッチ済みの相手の車を表示している場合のみ渡す。渡すと「気になるカスタム」
  /// の選択UIが表示され、送信先はここで指定したオーナーIDになる。
  final String? customInterestOwnerUserId;
  const VehicleDetailCard(
      {super.key, required this.vehicle, this.customInterestOwnerUserId});

  @override
  State<VehicleDetailCard> createState() => _VehicleDetailCardState();
}

class _VehicleDetailCardState extends State<VehicleDetailCard> {
  int _currentPhoto = 0;
  late final PageController _pageController;
  List<VehicleCustomizationPart> _parts = [];
  final Set<CustomizationCategory> _selectedInterest = {};
  bool _sendingInterest = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _loadParts();
  }

  Future<void> _loadParts() async {
    try {
      final parts = await VehicleRepository()
          .fetchCustomizationParts(widget.vehicle.vehicleId);
      final visible = parts.where((p) => !p.isEmpty).toList()
        // display_orderがすべて0のため、カテゴリの表示順（enum宣言順、その他は最後）で並べ替える
        ..sort((a, b) =>
            CustomizationCategory.values.indexOf(a.category).compareTo(
                  CustomizationCategory.values.indexOf(b.category),
                ));
      if (mounted) setState(() => _parts = visible);
    } catch (_) {}
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vehicle;
    final typeIcon =
        v.vehicleType == VehicleType.bike ? LucideIcons.bike : LucideIcons.car;
    final typeLabel = v.vehicleType == VehicleType.bike ? 'バイク' : '車';

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
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(14)),
              child: Stack(
                children: [
                  SizedBox(
                    height: 220,
                    child: PageView.builder(
                      controller: _pageController,
                      itemCount: v.photos.length,
                      onPageChanged: (i) {
                        if (mounted) setState(() => _currentPhoto = i);
                      },
                      itemBuilder: (_, i) => GestureDetector(
                        onTap: () => VehiclePhotoViewer.show(
                          context,
                          photos: v.photos,
                          initialIndex: i,
                          ownerUserId: v.userId,
                        ),
                        child: SignedStorageImage(
                          storedReference: v.photos[i],
                          width: double.infinity,
                          height: 220,
                          fit: BoxFit.cover,
                          alignment: focalAlignment(v.photoFocalX, v.photoFocalY),
                          placeholder: Container(
                              height: 220, color: AppColors.shimmerBase),
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
                        children: List.generate(
                            v.photos.length,
                            (i) => Container(
                                  width: i == _currentPhoto ? 16 : 6,
                                  height: 6,
                                  margin:
                                      const EdgeInsets.symmetric(horizontal: 2),
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${_currentPhoto + 1} / ${v.photos.length}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                ],
              ),
            )
          else
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(14)),
              child: Container(
                height: 120,
                color: AppColors.surface,
                child: const Center(
                    child: Icon(Icons.directions_car,
                        color: AppColors.textMuted, size: 48)),
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
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                // タイプ + 年式
                Row(
                  children: [
                    Icon(typeIcon, size: 12, color: AppColors.textMuted),
                    const SizedBox(width: 3),
                    Text(typeLabel,
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 12)),
                    if (v.year != null) ...[
                      const SizedBox(width: 10),
                      const Icon(Icons.calendar_today_outlined,
                          size: 12, color: AppColors.textMuted),
                      const SizedBox(width: 3),
                      Text('${v.year}年式',
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 12)),
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
                // オーナーのこだわり（車1台につき1つ）
                if (v.ownerPassionComment != null &&
                    v.ownerPassionComment!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: AppColors.border),
                  const SizedBox(height: 12),
                  const Text(
                    'オーナーのこだわり',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '"${v.ownerPassionComment!}"',
                    style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                        height: 1.6,
                        fontStyle: FontStyle.italic),
                  ),
                ],
                // カスタム詳細（構造化パーツ：車高調・ホイール・マフラー・エアロ・ECU・タイヤ）
                if (_parts.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: AppColors.border),
                  const SizedBox(height: 12),
                  const Text(
                    'カスタム詳細',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  ..._parts.map((p) => _CustomizationPartTile(part: p)),
                ],
                // カスタム説明（その他・自由記述）
                if (v.customContent != null && v.customContent!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: AppColors.border),
                  const SizedBox(height: 12),
                  if (_parts.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 6),
                      child: Text(
                        'その他のカスタム',
                        style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  Text(
                    v.customContent!,
                    style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                        height: 1.6),
                  ),
                ],
                // 気になるカスタム（マッチ済みの相手の車のときだけ表示）
                if (widget.customInterestOwnerUserId != null &&
                    _parts.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: AppColors.border),
                  const SizedBox(height: 12),
                  const Text(
                    '気になるカスタムはありますか？',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _parts.map((p) {
                      final selected = _selectedInterest.contains(p.category);
                      return FilterChip(
                        label: Text(p.category.label,
                            style: const TextStyle(fontSize: 12)),
                        selected: selected,
                        onSelected: (v) => setState(() {
                          if (v) {
                            _selectedInterest.add(p.category);
                          } else {
                            _selectedInterest.remove(p.category);
                          }
                        }),
                        selectedColor: AppColors.primary.withOpacity(0.15),
                        checkmarkColor: AppColors.primary,
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _selectedInterest.isEmpty || _sendingInterest
                          ? null
                          : _sendInterest,
                      child: _sendingInterest
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('気になるを送る'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sendInterest() async {
    final ownerId = widget.customInterestOwnerUserId;
    if (ownerId == null || _selectedInterest.isEmpty) return;
    setState(() => _sendingInterest = true);
    try {
      await VehicleRepository().sendCustomInterest(
        vehicleId: widget.vehicle.vehicleId,
        ownerUserId: ownerId,
        categories: _selectedInterest.toList(),
      );
      if (mounted) {
        setState(() => _selectedInterest.clear());
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('気になるを送りました！')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('送信に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingInterest = false);
    }
  }
}

class _CustomizationPartTile extends StatelessWidget {
  final VehicleCustomizationPart part;
  const _CustomizationPartTile({required this.part});

  Color get _color => switch (part.category) {
        CustomizationCategory.suspension => AppColors.tagSuspension,
        CustomizationCategory.wheel => AppColors.tagWheel,
        CustomizationCategory.exhaust => AppColors.tagSound,
        CustomizationCategory.aero => AppColors.tagAero,
        CustomizationCategory.other => AppColors.tagEngine,
        CustomizationCategory.tire => AppColors.tagTire,
      };

  @override
  Widget build(BuildContext context) {
    final specLine = [
      if (part.brand != null && part.brand!.isNotEmpty) part.brand,
      if (part.specDetail != null && part.specDetail!.isNotEmpty)
        part.specDetail,
    ].join(' / ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 5, right: 8),
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: _color, shape: BoxShape.circle),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  part.category.label,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700),
                ),
                if (specLine.isNotEmpty)
                  Text(specLine,
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
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
        child: Text(label,
            style: const TextStyle(
                color: AppColors.primary,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
      );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../vehicle/models/vehicle.dart';
import '../../vehicle/presentation/vehicle_register_provider.dart';
export '../../vehicle/models/vehicle.dart' show VehicleType;
import '../../vehicle/presentation/vehicle_register_step1.dart';
import '../../vehicle/presentation/vehicle_register_step2.dart';
import '../../vehicle/presentation/vehicle_register_step3.dart';
import '../../vehicle/data/vehicle_repository.dart';

class MyCarScreen extends ConsumerWidget {
  const MyCarScreen({super.key});

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, String vehicleId, String userId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('愛車を削除'),
        content: const Text('この愛車を削除しますか？\n（マッチ履歴は保持されます）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除', style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final repo = ref.read(vehicleRepositoryProvider);
    await repo.deleteVehicle(vehicleId);
    ref.invalidate(allVehiclesProvider(userId));
  }

  void _openRegisterFlow(BuildContext context, WidgetRef ref, String userId, {Vehicle? editVehicle}) {
    final notifier = ref.read(vehicleRegisterProvider.notifier);
    if (editVehicle != null) {
      notifier.loadForEdit(editVehicle);
    } else {
      notifier.reset();
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _VehicleRegisterFlow(
          userId: userId,
          onComplete: () {
            // 登録完了後は必ず再取得して画面に反映
            ref.invalidate(allVehiclesProvider(userId));
          },
        ),
      ),
    ).then((_) {
      // ポップ後にも再取得（invalidate が間に合わない場合のフォールバック）
      ref.invalidate(allVehiclesProvider(userId));
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(authNotifierProvider);
    final user = userAsync.value;

    if (user == null) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(child: CircularProgressIndicator(color: AppColors.primary)),
      );
    }

    final vehiclesAsync = ref.watch(allVehiclesProvider(user.userId));
    final isPremium = user.isPremium;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const YaheAppBar(title: 'マイカー', showBack: false),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 愛車セクション（プロフィール・統計は除外）
            vehiclesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator(color: AppColors.primary)),
              error: (e, _) => const Text('車両情報の読み込みに失敗しました'),
              data: (vehicles) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '登録済みの愛車',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${vehicles.length} / ${isPremium ? "∞" : AppConstants.freeVehicleLimit}',
                          style: const TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ...vehicles.map((v) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: GestureDetector(
                      onTap: () => _openRegisterFlow(context, ref, user.userId, editVehicle: v),
                      onLongPress: () => _confirmDelete(context, ref, v.vehicleId, user.userId),
                      child: _VehicleCard(vehicle: v),
                    ),
                  )),
                  _AddVehicleButton(
                    canAdd: isPremium || vehicles.length < AppConstants.freeVehicleLimit,
                    isPremium: isPremium,
                    currentCount: vehicles.length,
                    onTap: () => _openRegisterFlow(context, ref, user.userId),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  final dynamic user;
  const _ProfileCard({required this.user});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: AppColors.primary.withOpacity(0.15),
            child: Text(
              (user.nickname as String? ?? 'U').substring(0, 1).toUpperCase(),
              style: const TextStyle(color: AppColors.primary, fontSize: 22, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.nickname as String? ?? '名無し',
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w700),
                ),
                if (user.area != null)
                  Text(user.area as String,
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
                if (user.comment != null)
                  Text('"${user.comment}"',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (user.isPremium == true)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFFFFD700), Color(0xFFFFA500)]),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('Gear+', style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w800)),
                ),
              const SizedBox(height: 4),
              const Text('編集', style: TextStyle(color: AppColors.primary, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

class _VehicleCard extends StatelessWidget {
  final Vehicle vehicle;
  const _VehicleCard({required this.vehicle});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 写真
          if (vehicle.photos.isNotEmpty)
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              child: SignedStorageImage(
                storedReference: vehicle.photos.first,
                height: 180,
                width: double.infinity,
                fit: BoxFit.cover,
                placeholder: Container(
                  height: 180,
                  color: AppColors.background,
                  child: const Center(child: Icon(Icons.broken_image, color: AppColors.textMuted)),
                ),
              ),
            )
          else
            Container(
              height: 100,
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: const Center(
                child: Icon(Icons.directions_car_outlined, color: AppColors.textMuted, size: 40),
              ),
            ),

          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 車/バイクバッジ
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        vehicle.vehicleType == VehicleType.bike ? '🏍 バイク' : '🚗 車',
                        style: const TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        vehicle.displayName,
                        style: const TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.primary.withOpacity(0.3)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.edit_outlined, size: 12, color: AppColors.primary),
                          SizedBox(width: 4),
                          Text('編集', style: TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ],
                ),
                if (vehicle.deliveryDate != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.calendar_today_outlined, size: 13, color: AppColors.textMuted),
                      const SizedBox(width: 4),
                      Text(
                        '納車日：${DateFormat('yyyy年M月d日').format(vehicle.deliveryDate!)}',
                        style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ],
                if (vehicle.customContent != null && vehicle.customContent!.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Divider(height: 1, color: AppColors.border),
                  const SizedBox(height: 10),
                  Text(
                    vehicle.customContent!,
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.6),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
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

class _AddVehicleButton extends StatelessWidget {
  final bool canAdd;
  final bool isPremium;
  final int currentCount;
  final VoidCallback onTap;

  const _AddVehicleButton({
    required this.canAdd,
    required this.isPremium,
    required this.currentCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (!canAdd) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            const Icon(Icons.lock_outline, color: AppColors.textMuted, size: 24),
            const SizedBox(height: 6),
            Text(
              '無料プランは${AppConstants.freeVehicleLimit}台まで',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () {},
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.primary),
                minimumSize: const Size(double.infinity, 40),
              ),
              child: const Text('Gear+ で無制限に'),
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withOpacity(0.4), width: 1.5),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, color: AppColors.primary, size: 20),
            SizedBox(width: 8),
            Text('愛車を追加登録', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

class _StatsSection extends ConsumerWidget {
  final String userId;
  const _StatsSection({required this.userId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('統計', style: TextStyle(color: AppColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          const Row(
            children: [
              _StatItem(label: 'すれ違い', value: '-', icon: Icons.swap_horiz),
              _StatItem(label: 'いいね', value: '-', icon: Icons.favorite_border),
              _StatItem(label: 'マッチ', value: '-', icon: Icons.people_outline),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _StatItem({required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: AppColors.primary, size: 24),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w800)),
          Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
        ],
      ),
    );
  }
}

// 登録・編集フロー
class _VehicleRegisterFlow extends ConsumerStatefulWidget {
  final String userId;
  final VoidCallback onComplete;
  const _VehicleRegisterFlow({required this.userId, required this.onComplete});

  @override
  ConsumerState<_VehicleRegisterFlow> createState() => _VehicleRegisterFlowState();
}

class _VehicleRegisterFlowState extends ConsumerState<_VehicleRegisterFlow> {
  int _step = 1;

  @override
  Widget build(BuildContext context) {
    return switch (_step) {
      1 => VehicleRegisterStep1(onNext: () => setState(() => _step = 2)),
      2 => VehicleRegisterStep2(
          onNext: () => setState(() => _step = 3),
          onBack: () => setState(() => _step = 1),
        ),
      3 => VehicleRegisterStep3(
          onBack: () => setState(() => _step = 2),
          onComplete: () {
            widget.onComplete();
            Navigator.pop(context);
          },
        ),
      _ => const SizedBox.shrink(),
    };
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../vehicle/models/vehicle.dart';
import '../../vehicle/presentation/vehicle_register_provider.dart';
import '../models/passing_target.dart';
import 'home_provider.dart';
import 'passing_target_provider.dart';

/// ホーム画面上部：すれ違い対象の表示＋タップで変更
class PassingTargetHeader extends ConsumerWidget {
  const PassingTargetHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authNotifierProvider).value;
    if (user == null) return const SizedBox.shrink();

    final target = ref.watch(passingTargetProvider);
    final vehiclesAsync = ref.watch(allVehiclesProvider(user.userId));

    return vehiclesAsync.when(
      loading: () => const SizedBox(
        height: 52,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
          ),
        ),
      ),
      error: (_, __) => const SizedBox.shrink(),
      data: (vehicles) {
        final identity = identityTypesFromVehicles(vehicles);
        return Material(
          color: AppColors.surface,
          child: InkWell(
            onTap: identity.isEmpty
                ? () => _showNoVehicleDialog(context)
                : () => _showSelector(context, ref, target),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AppColors.border),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'すれ違い対象',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          identity.isEmpty
                              ? '愛車を登録してください'
                              : target.shortLabel,
                          style: TextStyle(
                            color: identity.isEmpty
                                ? AppColors.textMuted
                                : AppColors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (identity.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Text(
                        identityLabel(identity),
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Icon(
                    identity.isEmpty ? Icons.info_outline : Icons.expand_more,
                    color: AppColors.textMuted,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showNoVehicleDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceCard,
        title: const Text('愛車の登録が必要です'),
        content: const Text(
          'すれ違い検知を開始するには、マイカータブから\n車またはバイクを登録してください。\n\n登録した愛車の種別が、あなたのすれ違い種別になります。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showSelector(BuildContext context, WidgetRef ref, PassingTarget current) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final user = ref.read(authNotifierProvider).value;
        final vehicles = user == null
            ? <Vehicle>[]
            : ref.read(allVehiclesProvider(user.userId)).value ?? [];
        final identity = identityTypesFromVehicles(vehicles);

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'すれ違い対象を選択',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'あなたは「${identityLabel(identity)}」として検知されます',
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  identityDetail(identity),
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 11, height: 1.5),
                ),
                const SizedBox(height: 16),
                ...PassingTarget.values.map(
                  (t) => _TargetOption(
                    target: t,
                    isSelected: t == current,
                    onTap: () async {
                      Navigator.pop(ctx);
                      await ref.read(passingTargetProvider.notifier).setTarget(t);
                      ref.invalidate(encountersProvider);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TargetOption extends StatelessWidget {
  final PassingTarget target;
  final bool isSelected;
  final VoidCallback onTap;

  const _TargetOption({
    required this.target,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isSelected ? AppColors.primary.withOpacity(0.08) : AppColors.background,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? AppColors.primary : AppColors.border,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        target.label,
                        style: TextStyle(
                          color: isSelected ? AppColors.primary : AppColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        target.description,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  const Icon(Icons.check_circle, color: AppColors.primary, size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';

// ステップインジケーター（車両登録フロー用）
class StepHeader extends StatelessWidget {
  final int currentStep;
  final int totalSteps;
  final String label;

  const StepHeader({
    super.key,
    required this.currentStep,
    required this.totalSteps,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: List.generate(totalSteps, (i) {
              final isActive = i < currentStep;
              final isCurrent = i == currentStep - 1;
              return Expanded(
                child: Container(
                  margin: EdgeInsets.only(right: i < totalSteps - 1 ? 4 : 0),
                  height: 3,
                  decoration: BoxDecoration(
                    color: isActive
                        ? AppColors.primary
                        : isCurrent
                            ? AppColors.primary.withOpacity(0.5)
                            : AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          Text(
            'Step $currentStep / $totalSteps  ·  $label',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

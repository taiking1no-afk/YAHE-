import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../shared/widgets/step_header.dart';
import 'vehicle_customization_edit_screen.dart';
import 'vehicle_register_provider.dart';

class VehicleRegisterStep2 extends ConsumerWidget {
  final VoidCallback onNext;
  final VoidCallback onBack;
  const VehicleRegisterStep2(
      {super.key, required this.onNext, required this.onBack});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reg = ref.watch(vehicleRegisterProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('愛車登録'),
        leading:
            IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack),
      ),
      body: Column(
        children: [
          StepHeader(currentStep: 2, totalSteps: 3, label: 'カスタム詳細'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (reg.editingVehicleId != null)
                    VehicleCustomizationEditor(
                      vehicleId: reg.editingVehicleId!,
                      initialOwnerPassionComment: reg.ownerPassionComment,
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: const Text(
                        '保存すると、続けてカスタム詳細（車高調・ホイール・マフラー・エアロ・タイヤ・その他）とオーナーのこだわりを登録できるようになります。',
                        style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            height: 1.6),
                      ),
                    ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            color: AppColors.background,
            child: ElevatedButton(
              onPressed: onNext,
              child: const Text('次へ'),
            ),
          ),
        ],
      ),
    );
  }
}

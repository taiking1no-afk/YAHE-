import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../shared/widgets/step_header.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import 'vehicle_register_provider.dart';

class VehicleRegisterStep2 extends ConsumerStatefulWidget {
  final VoidCallback onNext;
  final VoidCallback onBack;
  const VehicleRegisterStep2({super.key, required this.onNext, required this.onBack});

  @override
  ConsumerState<VehicleRegisterStep2> createState() => _VehicleRegisterStep2State();
}

class _VehicleRegisterStep2State extends ConsumerState<VehicleRegisterStep2> {
  final _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ctrl.text = ref.read(vehicleRegisterProvider).customContent;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reg = ref.watch(vehicleRegisterProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('愛車登録'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
      ),
      body: Column(
        children: [
          StepHeader(currentStep: 2, totalSteps: 3, label: 'カスタム内容'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'カスタム内容・こだわりポイント',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'エアロ・足回り・エンジンなど自由に記載してください',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _ctrl,
                    maxLines: 8,
                    maxLength: 500,
                    onChanged: ref.read(vehicleRegisterProvider.notifier).setCustomContent,
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, height: 1.6),
                    decoration: const InputDecoration(
                      hintText: '例：\n・車高調：TEIN FLEX Z\n・マフラー：HKS ハイパワースペックL\n・ホイール：Rays TE37 18インチ\n・エアロ：エムズスピード フルエアロ',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // 入力ヒント
                  _HintChips(
                    hints: const ['エアロ', '車高調', 'マフラー', 'ホイール', 'エンジン', '全塗装', 'ラッピング', 'ターボ'],
                    onTap: (hint) {
                      final current = _ctrl.text;
                      final newText = current.isEmpty ? hint : '$current\n・$hint：';
                      _ctrl.text = newText;
                      _ctrl.selection = TextSelection.fromPosition(
                        TextPosition(offset: _ctrl.text.length),
                      );
                      ref.read(vehicleRegisterProvider.notifier).setCustomContent(newText);
                    },
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
              onPressed: widget.onNext,
              child: const Text('次へ'),
            ),
          ),
        ],
      ),
    );
  }
}

class _HintChips extends StatelessWidget {
  final List<String> hints;
  final ValueChanged<String> onTap;
  const _HintChips({required this.hints, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('タップして追記', style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: hints.map((h) => GestureDetector(
            onTap: () => onTap(h),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                '+ $h',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ),
          )).toList(),
        ),
      ],
    );
  }
}

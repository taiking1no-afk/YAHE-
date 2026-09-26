import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../../shared/widgets/step_header.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import 'vehicle_register_provider.dart';

class VehicleRegisterStep1 extends ConsumerStatefulWidget {
  final VoidCallback onNext;
  const VehicleRegisterStep1({super.key, required this.onNext});

  @override
  ConsumerState<VehicleRegisterStep1> createState() =>
      _VehicleRegisterStep1State();
}

class _VehicleRegisterStep1State extends ConsumerState<VehicleRegisterStep1> {
  final _modelCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final reg = ref.read(vehicleRegisterProvider);
    _modelCtrl.text = reg.model ?? '';
  }

  @override
  void dispose() {
    _modelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reg = ref.watch(vehicleRegisterProvider);
    final notifier = ref.read(vehicleRegisterProvider.notifier);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('愛車登録')),
      body: Column(
        children: [
          StepHeader(currentStep: 1, totalSteps: 3, label: 'メーカー・車種'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 車 / バイク 選択
                  _Label('種別'),
                  const SizedBox(height: 8),
                  _VehicleTypeSelector(
                    selected: reg.vehicleType,
                    onSelect: notifier.setVehicleType,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '登録した種別が、あなたのすれ違い種別になります（車のみ→車のり、バイクのみ→バイカー、両方→どちらも）',
                    style: TextStyle(
                      color: AppColors.textMuted.withOpacity(0.9),
                      fontSize: 11,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 20),
                  _Label('メーカー'),
                  const SizedBox(height: 8),
                  _MakerGrid(
                    vehicleType: reg.vehicleType,
                    selected: reg.maker,
                    onSelect: notifier.setMaker,
                  ),
                  const SizedBox(height: 20),
                  _Label(
                      reg.vehicleType == VehicleType.bike ? '車種名（型式）' : '車種名'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _modelCtrl,
                    onChanged: notifier.setModel,
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: reg.vehicleType == VehicleType.bike
                          ? '例：CB400SF、Ninja 400、MT-07'
                          : '例：GR86、シルビア S15',
                    ),
                  ),
                  const SizedBox(height: 20),
                  _Label('年式（任意）'),
                  const SizedBox(height: 8),
                  _YearPicker(
                    selected: reg.year,
                    onSelect: notifier.setYear,
                  ),
                  const SizedBox(height: 20),
                  _Label('納車日（任意）'),
                  const SizedBox(height: 8),
                  _DeliveryDatePicker(
                    selected: reg.deliveryDate,
                    onSelect: notifier.setDeliveryDate,
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
          _BottomButton(
            enabled: reg.maker != null && (reg.model?.isNotEmpty ?? false),
            onTap: widget.onNext,
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600),
      );
}

class _VehicleTypeSelector extends StatelessWidget {
  final VehicleType selected;
  final ValueChanged<VehicleType> onSelect;
  const _VehicleTypeSelector({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _TypeButton(
          label: '🚗  車',
          isSelected: selected == VehicleType.car,
          onTap: () => onSelect(VehicleType.car),
        ),
        const SizedBox(width: 10),
        _TypeButton(
          label: '🏍  バイク',
          isSelected: selected == VehicleType.bike,
          onTap: () => onSelect(VehicleType.bike),
        ),
      ],
    );
  }
}

class _TypeButton extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  const _TypeButton(
      {required this.label, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withOpacity(0.1)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.border,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? AppColors.primary : AppColors.textSecondary,
            fontSize: 15,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _MakerGrid extends StatelessWidget {
  final VehicleType vehicleType;
  final String? selected;
  final ValueChanged<String> onSelect;
  const _MakerGrid({
    required this.vehicleType,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final makers = vehicleType == VehicleType.bike
        ? AppConstants.bikeMakers
        : AppConstants.carMakers;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: makers.map((maker) {
        final isSelected = selected == maker;
        return GestureDetector(
          onTap: () => onSelect(maker),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppColors.primary.withOpacity(0.1)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isSelected ? AppColors.primary : AppColors.border,
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Text(
              maker,
              style: TextStyle(
                color: isSelected ? AppColors.primary : AppColors.textSecondary,
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.normal,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _YearPicker extends StatelessWidget {
  final int? selected;
  final ValueChanged<int?> onSelect;
  const _YearPicker({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final currentYear = DateTime.now().year;
    final years = List.generate(40, (i) => currentYear - i);

    return DropdownButtonFormField<int>(
      value: selected,
      decoration: const InputDecoration(hintText: '年式を選択'),
      dropdownColor: AppColors.surface,
      style: const TextStyle(color: AppColors.textPrimary),
      items: [
        const DropdownMenuItem<int>(
            value: null,
            child: Text('選択しない', style: TextStyle(color: AppColors.textMuted))),
        ...years.map(
            (y) => DropdownMenuItem<int>(value: y, child: Text(y.toString()))),
      ],
      onChanged: onSelect,
    );
  }
}

class _DeliveryDatePicker extends StatelessWidget {
  final DateTime? selected;
  final ValueChanged<DateTime?> onSelect;
  const _DeliveryDatePicker({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final date = await showDatePicker(
          context: context,
          initialDate: selected ?? DateTime.now(),
          firstDate: DateTime(1980),
          lastDate: DateTime.now().add(const Duration(days: 365)),
          locale: const Locale('ja'),
          builder: (context, child) => Theme(
            data: Theme.of(context).copyWith(
              colorScheme: Theme.of(context).colorScheme.copyWith(
                    primary: AppColors.primary,
                  ),
            ),
            child: child!,
          ),
        );
        onSelect(date);
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            const Icon(Icons.calendar_today_outlined,
                size: 18, color: AppColors.textMuted),
            const SizedBox(width: 10),
            Text(
              selected != null
                  ? DateFormat('yyyy年M月d日').format(selected!)
                  : '納車日を選択',
              style: TextStyle(
                color: selected != null
                    ? AppColors.textPrimary
                    : AppColors.textMuted,
                fontSize: 15,
              ),
            ),
            const Spacer(),
            if (selected != null)
              GestureDetector(
                onTap: () => onSelect(null),
                child: const Icon(Icons.close,
                    size: 16, color: AppColors.textMuted),
              ),
          ],
        ),
      ),
    );
  }
}

class _BottomButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  const _BottomButton({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      color: AppColors.background,
      child: ElevatedButton(
        onPressed: enabled ? onTap : null,
        child: const Text('次へ'),
      ),
    );
  }
}

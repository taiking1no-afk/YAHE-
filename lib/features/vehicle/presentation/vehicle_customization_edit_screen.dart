import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../data/vehicle_repository.dart';
import '../models/vehicle_customization_part.dart';

/// マイカーの「オーナーのこだわり」（車1台につき1つ）と、
/// カスタム詳細（車高調・ホイール・マフラー・エアロ・ECU・タイヤ）を
/// カテゴリごとに編集するウィジェット。愛車登録・編集フローの2枚目（カスタム内容）
/// に埋め込んで使う（自前のScaffold/AppBarは持たない）。
/// 車両が未確定（新規登録の途中でvehicleIdがまだない）場合は使えない。
class VehicleCustomizationEditor extends StatefulWidget {
  final String vehicleId;
  final String? initialOwnerPassionComment;
  const VehicleCustomizationEditor({
    super.key,
    required this.vehicleId,
    this.initialOwnerPassionComment,
  });

  @override
  State<VehicleCustomizationEditor> createState() =>
      _VehicleCustomizationEditorState();
}

class _VehicleCustomizationEditorState
    extends State<VehicleCustomizationEditor> {
  final _repo = VehicleRepository();
  bool _loading = true;
  late final _passionCtrl =
      TextEditingController(text: widget.initialOwnerPassionComment);
  bool _savingPassion = false;
  final _brandCtrls = <CustomizationCategory, TextEditingController>{};
  final _specCtrls = <CustomizationCategory, TextEditingController>{};
  final _savingCategories = <CustomizationCategory>{};

  @override
  void initState() {
    super.initState();
    for (final c in CustomizationCategory.values) {
      _brandCtrls[c] = TextEditingController();
      _specCtrls[c] = TextEditingController();
    }
    _load();
  }

  Future<void> _load() async {
    try {
      final parts = await _repo.fetchCustomizationParts(widget.vehicleId);
      for (final p in parts) {
        _brandCtrls[p.category]!.text = p.brand ?? '';
        _specCtrls[p.category]!.text = p.specDetail ?? '';
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _passionCtrl.dispose();
    for (final c in _brandCtrls.values) {
      c.dispose();
    }
    for (final c in _specCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _savePassion() async {
    setState(() => _savingPassion = true);
    try {
      await _repo.updateOwnerPassionComment(
        widget.vehicleId,
        _passionCtrl.text.trim().isEmpty ? null : _passionCtrl.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('保存しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存に失敗しました: $e')));
      }
    } finally {
      if (mounted) setState(() => _savingPassion = false);
    }
  }

  Future<void> _save(CustomizationCategory category) async {
    setState(() => _savingCategories.add(category));
    try {
      await _repo.upsertCustomizationPart(VehicleCustomizationPart(
        vehicleId: widget.vehicleId,
        category: category,
        brand: _brandCtrls[category]!.text.trim().isEmpty
            ? null
            : _brandCtrls[category]!.text.trim(),
        specDetail: _specCtrls[category]!.text.trim().isEmpty
            ? null
            : _specCtrls[category]!.text.trim(),
      ));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${category.label}を保存しました')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingCategories.remove(category));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child:
            Center(child: CircularProgressIndicator(color: AppColors.primary)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'オーナーのこだわり',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                'この車のここが好き、という一言を1つだけ登録できます（パーツごとではなく車全体について）。',
                style: TextStyle(
                    color: AppColors.textMuted, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _passionCtrl,
                maxLines: 3,
                maxLength: 200,
                decoration:
                    const InputDecoration(hintText: '例：低音の効いた排気音が気に入っています'),
                style: const TextStyle(fontSize: 14),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _savingPassion ? null : _savePassion,
                  child: _savingPassion
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('保存'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'パーツごとにブランド・こだわりを登録できます。',
          style: TextStyle(
              color: AppColors.textSecondary, fontSize: 13, height: 1.6),
        ),
        const SizedBox(height: 16),
        for (final category in CustomizationCategory.values) ...[
          _CategoryCard(
            category: category,
            brandCtrl: _brandCtrls[category]!,
            specCtrl: _specCtrls[category]!,
            saving: _savingCategories.contains(category),
            onSave: () => _save(category),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _CategoryCard extends StatelessWidget {
  final CustomizationCategory category;
  final TextEditingController brandCtrl;
  final TextEditingController specCtrl;
  final bool saving;
  final VoidCallback onSave;

  const _CategoryCard({
    required this.category,
    required this.brandCtrl,
    required this.specCtrl,
    required this.saving,
    required this.onSave,
  });

  Color get _color => switch (category) {
        CustomizationCategory.suspension => AppColors.tagSuspension,
        CustomizationCategory.wheel => AppColors.tagWheel,
        CustomizationCategory.exhaust => AppColors.tagSound,
        CustomizationCategory.aero => AppColors.tagAero,
        CustomizationCategory.other => AppColors.tagEngine,
        CustomizationCategory.tire => AppColors.tagTire,
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: _color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                category.label,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: brandCtrl,
            decoration: const InputDecoration(labelText: 'ブランド'),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: specCtrl,
            decoration: const InputDecoration(labelText: 'こだわり'),
            style: const TextStyle(fontSize: 14),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: saving ? null : onSave,
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }
}

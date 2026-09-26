import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/supabase/supabase_config.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../../auth/presentation/auth_provider.dart';

const Map<String, String> _requestTypeLabels = {
  'disclosure': '保有個人データの開示請求',
  'correction': '内容の訂正・追加・削除請求',
  'restriction': '利用停止・消去請求',
  'deletion': 'アカウントデータの削除請求',
};

/// 個人情報保護法上の開示・訂正・利用停止・削除請求の受付フォーム。
/// 請求内容はdata_subject_requestsに記録され、運営が手動で対応する
/// （アカウント全体の即時削除は設定画面の「アカウント削除」を案内）。
class DataSubjectRequestScreen extends ConsumerStatefulWidget {
  const DataSubjectRequestScreen({super.key});

  @override
  ConsumerState<DataSubjectRequestScreen> createState() =>
      _DataSubjectRequestScreenState();
}

class _DataSubjectRequestScreenState
    extends ConsumerState<DataSubjectRequestScreen> {
  String? _selectedType;
  final _detailCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _detailCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final userId = ref.read(authNotifierProvider).value?.userId;
    if (userId == null || _selectedType == null) return;
    setState(() => _submitting = true);
    try {
      await SupabaseConfig.client.from('data_subject_requests').insert({
        'user_id': userId,
        'request_type': _selectedType,
        if (_detailCtrl.text.trim().isNotEmpty) 'detail': _detailCtrl.text.trim(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('請求を受け付けました。内容を確認のうえ対応いたします。')),
        );
        setState(() {
          _selectedType = null;
          _detailCtrl.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('送信に失敗しました。時間をおいて再度お試しください。')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const YaheAppBar(title: '個人情報に関する請求'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'ご自身の個人情報について、開示・訂正・利用停止・削除等の請求ができます。'
            '内容を確認のうえ、対応いたします。',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.6),
          ),
          const SizedBox(height: 20),
          const Text('請求の種類',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          ..._requestTypeLabels.entries.map((e) => RadioListTile<String>(
                value: e.key,
                // ignore: deprecated_member_use
                groupValue: _selectedType,
                // ignore: deprecated_member_use
                onChanged: (v) => setState(() => _selectedType = v),
                title: Text(e.value, style: const TextStyle(fontSize: 14)),
                activeColor: AppColors.primary,
                contentPadding: EdgeInsets.zero,
              )),
          const SizedBox(height: 12),
          const Text('詳細（任意）',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _detailCtrl,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: '対象データの内容など、具体的にご記入ください',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: (_selectedType == null || _submitting) ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('請求を送信する'),
          ),
        ],
      ),
    );
  }
}

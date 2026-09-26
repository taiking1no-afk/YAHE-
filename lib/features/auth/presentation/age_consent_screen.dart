import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/constants/app_colors.dart';
import '../../legal/terms_screen.dart';
import 'auth_provider.dart';

/// 規約バージョン。規約を改定したらこの値を上げると、再同意を求められる。
const String kTermsVersion = '1.0';

/// 年齢確認＋規約同意のゲート画面。
/// - 16歳未満は利用不可
/// - 利用規約・プライバシーポリシーへの同意を取得・記録
/// - 通報により停止されたユーザーには停止画面を表示
class AgeConsentScreen extends ConsumerStatefulWidget {
  const AgeConsentScreen({super.key});

  @override
  ConsumerState<AgeConsentScreen> createState() => _AgeConsentScreenState();
}

class _AgeConsentScreenState extends ConsumerState<AgeConsentScreen> {
  DateTime? _birthDate;
  bool _agreedTerms = false;
  bool _submitting = false;
  String? _error;

  int _ageFrom(DateTime birth) {
    final now = DateTime.now();
    var age = now.year - birth.year;
    if (now.month < birth.month ||
        (now.month == birth.month && now.day < birth.day)) {
      age--;
    }
    return age;
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final initial = DateTime(now.year - 20, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1920),
      lastDate: now,
      helpText: '生年月日を選択',
    );
    if (picked != null) {
      setState(() {
        _birthDate = picked;
        _error = null;
      });
    }
  }

  Future<void> _submit() async {
    final birth = _birthDate;
    if (birth == null) {
      setState(() => _error = '生年月日を選択してください');
      return;
    }
    if (_ageFrom(birth) < 16) {
      setState(() => _error = '本アプリは16歳以上の方のみご利用いただけます');
      return;
    }
    if (!_agreedTerms) {
      setState(() => _error = '利用規約・プライバシーポリシーへの同意が必要です');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(authNotifierProvider.notifier).saveAgeAndConsent(
            birthDate: birth,
            termsVersion: kTermsVersion,
          );
      if (!mounted) return;
      context.go('/splash');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '保存に失敗しました。通信環境をご確認のうえ、もう一度お試しください。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authNotifierProvider).value;

    // 通報により停止されたユーザー
    if (user != null && user.isSuspended) {
      return _SuspendedView(
        onSignOut: () => ref.read(authNotifierProvider.notifier).signOut(),
      );
    }

    final birth = _birthDate;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('ご利用の前に')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '年齢確認と規約への同意',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '安全にご利用いただくため、年齢確認と規約への同意をお願いします。',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 14, height: 1.6),
              ),
              const SizedBox(height: 28),

              // 生年月日
              const Text('生年月日',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
              const SizedBox(height: 8),
              InkWell(
                onTap: _submitting ? null : _pickBirthDate,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.cake_outlined,
                          size: 20, color: AppColors.textMuted),
                      const SizedBox(width: 12),
                      Text(
                        birth == null
                            ? '生年月日を選択'
                            : '${birth.year}年${birth.month}月${birth.day}日',
                        style: TextStyle(
                          color: birth == null
                              ? AppColors.textMuted
                              : AppColors.textPrimary,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // 規約同意
              CheckboxListTile(
                value: _agreedTerms,
                onChanged: _submitting
                    ? null
                    : (v) => setState(() {
                          _agreedTerms = v ?? false;
                          _error = null;
                        }),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                activeColor: AppColors.primary,
                title: const Text(
                  '16歳以上であり、利用規約・プライバシーポリシーに同意します',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 14),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Wrap(
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 0)),
                      onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const TermsScreen())),
                      child: const Text('利用規約', style: TextStyle(fontSize: 13)),
                    ),
                    const Text('  ・  ',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 13)),
                    TextButton(
                      style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 0)),
                      onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const PrivacyPolicyScreen())),
                      child: const Text('プライバシーポリシー',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style:
                        const TextStyle(color: AppColors.error, fontSize: 13)),
              ],

              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('同意して始める'),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed: _submitting
                      ? null
                      : () => ref.read(authNotifierProvider.notifier).signOut(),
                  child: const Text('ログアウト',
                      style:
                          TextStyle(color: AppColors.textMuted, fontSize: 13)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuspendedView extends StatelessWidget {
  final VoidCallback onSignOut;
  const _SuspendedView({required this.onSignOut});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.report_gmailerrorred_outlined,
                  size: 56, color: AppColors.error),
              const SizedBox(height: 20),
              const Text(
                'アカウントが停止されています',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              const Text(
                '複数の通報により、このアカウントの利用を一時停止しています。'
                '誤りと思われる場合は、お問い合わせよりご連絡ください。',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 14, height: 1.7),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              TextButton(
                onPressed: onSignOut,
                child: const Text('ログアウト'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/app_colors.dart';

class ContactScreen extends StatefulWidget {
  const ContactScreen({super.key});

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  late final ValueNotifier<String> _categoryCtrl;
  final _bodyCtrl = TextEditingController();
  bool _isSending = false;

  static const _categories = [
    '不具合の報告',
    'ご意見・ご要望',
    'アカウントについて',
    '不審なユーザーの報告',
    'その他',
  ];

  @override
  void initState() {
    super.initState();
    _categoryCtrl = ValueNotifier<String>('不具合の報告');
  }

  @override
  void dispose() {
    _bodyCtrl.dispose();
    _categoryCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_bodyCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('お問い合わせ内容を入力してください')),
      );
      return;
    }

    setState(() => _isSending = true);

    final subject = Uri.encodeComponent('[YAHE] ${_categoryCtrl.value}');
    final body = Uri.encodeComponent(_bodyCtrl.text.trim());
    final uri =
        Uri.parse('mailto:taiking1.no@gmail.com?subject=$subject&body=$body');

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('メールアプリを開けませんでした')),
        );
      }
    }
    setState(() => _isSending = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('お問い合わせ')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.primary.withOpacity(0.2)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.mail_outline, color: AppColors.primary, size: 18),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'ご意見・ご要望・不具合などお気軽にどうぞ。',
                      style: TextStyle(color: AppColors.primary, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),

            // カテゴリ選択
            const Text('カテゴリ',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
            const SizedBox(height: 8),
            ValueListenableBuilder<String>(
              valueListenable: _categoryCtrl,
              builder: (context, selected, _) => Column(
                children: _categories.map((c) {
                  final isSelected = selected == c;
                  return GestureDetector(
                    onTap: () => _categoryCtrl.value = c,
                    child: Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.primary.withOpacity(0.08)
                            : AppColors.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color:
                              isSelected ? AppColors.primary : AppColors.border,
                          width: isSelected ? 1.5 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isSelected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            size: 18,
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.textMuted,
                          ),
                          const SizedBox(width: 10),
                          Text(c,
                              style: TextStyle(
                                color: isSelected
                                    ? AppColors.primary
                                    : AppColors.textPrimary,
                                fontSize: 14,
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.normal,
                              )),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 16),

            const Text('お問い合わせ内容',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
            const SizedBox(height: 6),
            TextField(
              controller: _bodyCtrl,
              maxLines: 6,
              maxLength: 1000,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: const InputDecoration(hintText: '詳細をご記入ください'),
            ),

            const SizedBox(height: 8),
            const Text('送信するとメールアプリが開きます',
                style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
            const SizedBox(height: 20),

            ElevatedButton.icon(
              onPressed: _isSending ? null : _send,
              icon: const Icon(Icons.send_outlined, size: 18),
              label: const Text('メールで送信'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => launchUrl(
                Uri.parse('https://yahe-legal.netlify.app/support'),
                mode: LaunchMode.inAppWebView,
              ),
              icon: const Icon(Icons.help_outline, size: 18),
              label: const Text('サポートページを開く'),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

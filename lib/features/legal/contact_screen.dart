import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/app_colors.dart';

class ContactScreen extends StatefulWidget {
  final bool isGearRApplication; // Gear R 申請モードで開く
  const ContactScreen({super.key, this.isGearRApplication = false});

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  late final ValueNotifier<String> _categoryCtrl;
  final _bodyCtrl = TextEditingController();

  // Gear R 申請フォーム用フィールド
  final _snsUrlCtrl = TextEditingController();
  final _shopNameCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  bool _isSending = false;

  static const _categories = [
    '不具合の報告',
    'ご意見・ご要望',
    'アカウントについて',
    '不審なユーザーの報告',
    'Gear R 申請',
    'その他',
  ];

  @override
  void initState() {
    super.initState();
    _categoryCtrl = ValueNotifier<String>(
      widget.isGearRApplication ? 'Gear R 申請' : '不具合の報告',
    );
    if (widget.isGearRApplication) {
      _bodyCtrl.text = 'Gear R プランへの申請です。以下の情報をご確認ください。';
    }
  }

  @override
  void dispose() {
    _bodyCtrl.dispose();
    _snsUrlCtrl.dispose();
    _shopNameCtrl.dispose();
    _reasonCtrl.dispose();
    _categoryCtrl.dispose();
    super.dispose();
  }

  bool get _isGearRMode =>
      _categoryCtrl.value == 'Gear R 申請';

  Future<void> _send() async {
    if (_isGearRMode) {
      // Gear R 申請メール
      if (_snsUrlCtrl.text.trim().isEmpty && _shopNameCtrl.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SNS URL またはショップ名を入力してください')),
        );
        return;
      }
    } else {
      if (_bodyCtrl.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('お問い合わせ内容を入力してください')),
        );
        return;
      }
    }

    setState(() => _isSending = true);

    final subject = Uri.encodeComponent('[YAHE] ${_categoryCtrl.value}');
    final body = _buildMailBody();
    final uri = Uri.parse('mailto:support@yahe.jp?subject=$subject&body=$body');

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

  String _buildMailBody() {
    if (_isGearRMode) {
      final sb = StringBuffer();
      sb.writeln('【Gear R 申請】');
      sb.writeln('');
      if (_shopNameCtrl.text.trim().isNotEmpty) {
        sb.writeln('■ 店舗名・ブランド名: ${_shopNameCtrl.text.trim()}');
      }
      if (_snsUrlCtrl.text.trim().isNotEmpty) {
        sb.writeln('■ SNS URL: ${_snsUrlCtrl.text.trim()}');
      }
      if (_reasonCtrl.text.trim().isNotEmpty) {
        sb.writeln('■ 申請理由: ${_reasonCtrl.text.trim()}');
      }
      sb.writeln('');
      sb.writeln('※ 審査には最大3営業日かかります。');
      return Uri.encodeComponent(sb.toString());
    }
    return Uri.encodeComponent(_bodyCtrl.text.trim());
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
            // Gear R 申請バナー
            if (_isGearRMode)
              Container(
                padding: const EdgeInsets.all(14),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF6C63FF).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.3)),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('💥', style: TextStyle(fontSize: 20)),
                        SizedBox(width: 8),
                        Text('Gear R 申請',
                            style: TextStyle(color: Color(0xFF6C63FF), fontWeight: FontWeight.w700, fontSize: 15)),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      '以下に当てはまる方が対象です：\n'
                      '・インフルエンサー（SNS 1,000フォロワー以上）\n'
                      '・自動車関連ショップ・企業・ブランド\n'
                      '・カスタム関連サービスを提供している方\n\n'
                      '認証バッジはGear R加入後、プロフィール編集から設定できます。',
                      style: TextStyle(color: Color(0xFF6C63FF), fontSize: 12, height: 1.6),
                    ),
                  ],
                ),
              )
            else
              // 通常のお問い合わせヘッダー
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
            const Text('カテゴリ', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
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
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? (c == 'Gear R 申請'
                                ? const Color(0xFF6C63FF).withOpacity(0.08)
                                : AppColors.primary.withOpacity(0.08))
                            : AppColors.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isSelected
                              ? (c == 'Gear R 申請' ? const Color(0xFF6C63FF) : AppColors.primary)
                              : AppColors.border,
                          width: isSelected ? 1.5 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                            size: 18,
                            color: isSelected
                                ? (c == 'Gear R 申請' ? const Color(0xFF6C63FF) : AppColors.primary)
                                : AppColors.textMuted,
                          ),
                          const SizedBox(width: 10),
                          Text(c, style: TextStyle(
                            color: isSelected
                                ? (c == 'Gear R 申請' ? const Color(0xFF6C63FF) : AppColors.primary)
                                : AppColors.textPrimary,
                            fontSize: 14,
                            fontWeight: isSelected ? FontWeight.w700 : FontWeight.normal,
                          )),
                          if (c == 'Gear R 申請') ...[
                            const SizedBox(width: 6),
                            const Text('💥', style: TextStyle(fontSize: 14)),
                          ],
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 16),

            // Gear R 専用フォーム
            ValueListenableBuilder<String>(
              valueListenable: _categoryCtrl,
              builder: (context, selected, _) {
                if (selected != 'Gear R 申請') {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('お問い合わせ内容', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _bodyCtrl,
                        maxLines: 6,
                        maxLength: 1000,
                        style: const TextStyle(color: AppColors.textPrimary),
                        decoration: const InputDecoration(hintText: '詳細をご記入ください'),
                      ),
                    ],
                  );
                }
                // Gear R 申請フォーム
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('店舗名・ブランド名（任意）', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _shopNameCtrl,
                      style: const TextStyle(color: AppColors.textPrimary),
                      decoration: const InputDecoration(hintText: '例：タイキカスタムショップ'),
                    ),
                    const SizedBox(height: 12),
                    const Text('SNS URL（Instagram / X など）', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _snsUrlCtrl,
                      keyboardType: TextInputType.url,
                      style: const TextStyle(color: AppColors.textPrimary),
                      decoration: const InputDecoration(hintText: 'https://www.instagram.com/...'),
                    ),
                    const SizedBox(height: 12),
                    const Text('申請理由・活動内容', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _reasonCtrl,
                      maxLines: 4,
                      style: const TextStyle(color: AppColors.textPrimary),
                      decoration: const InputDecoration(
                        hintText: '例：カスタムショップを経営しており、YAHEを通じてお客様との接点を増やしたい',
                      ),
                    ),
                  ],
                );
              },
            ),

            const SizedBox(height: 8),
            const Text('送信するとメールアプリが開きます', style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
            const SizedBox(height: 20),

            ElevatedButton.icon(
              onPressed: _isSending ? null : _send,
              icon: const Icon(Icons.send_outlined, size: 18),
              label: ValueListenableBuilder<String>(
                valueListenable: _categoryCtrl,
                builder: (_, cat, __) => Text(
                  cat == 'Gear R 申請' ? 'Gear R 申請メールを送る' : 'メールで送信',
                ),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

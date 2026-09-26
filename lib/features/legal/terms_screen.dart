import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/app_colors.dart';

/// 法的文書（利用規約・プライバシーポリシー・特商法表記・外部送信について）は
/// アプリ内に別途テキストを保持せず、常に最新の内容を1箇所（Webサイト）で
/// 管理するため、アプリ内では該当ページを開くだけの画面にする。
/// （以前はアプリ内に静的テキストを複製しており、Webサイト側の更新と
/// 内容がずれていく問題があった）
class _LegalLinkScreen extends StatefulWidget {
  final String title;
  final String url;
  const _LegalLinkScreen({required this.title, required this.url});

  @override
  State<_LegalLinkScreen> createState() => _LegalLinkScreenState();
}

class _LegalLinkScreenState extends State<_LegalLinkScreen> {
  bool _launched = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    final uri = Uri.parse(widget.url);
    try {
      await launchUrl(uri, mode: LaunchMode.inAppWebView);
    } catch (_) {
      // 失敗時は下の「開く」ボタンから手動リトライしてもらう
    }
    if (mounted) setState(() => _launched = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_launched)
                const CircularProgressIndicator(color: AppColors.primary)
              else ...[
                const Icon(Icons.open_in_new,
                    size: 32, color: AppColors.textMuted),
                const SizedBox(height: 12),
                const Text(
                  'このページの内容はWebサイトで表示されます',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: _open,
                  child: const Text('もう一度開く'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) => const _LegalLinkScreen(
        title: '利用規約',
        url: 'https://yahe-legal.netlify.app/terms',
      );
}

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) => const _LegalLinkScreen(
        title: 'プライバシーポリシー',
        url: 'https://yahe-legal.netlify.app/privacy',
      );
}

class CommercialTransactionScreen extends StatelessWidget {
  const CommercialTransactionScreen({super.key});

  @override
  Widget build(BuildContext context) => const _LegalLinkScreen(
        title: '特定商取引法に基づく表記',
        url: 'https://yahe-legal.netlify.app/tokushoho',
      );
}

class ExternalTransmissionScreen extends StatelessWidget {
  const ExternalTransmissionScreen({super.key});

  @override
  Widget build(BuildContext context) => const _LegalLinkScreen(
        title: '外部送信について',
        url: 'https://yahe-legal.netlify.app/external-transmission.html',
      );
}

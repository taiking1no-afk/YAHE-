import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/app_colors.dart';

/// URL から表示用のドメイン（host）を取り出す。www. は除去する。
String prettyHost(String url) {
  final uri = Uri.tryParse(url);
  final host = (uri != null && uri.host.isNotEmpty) ? uri.host : url;
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// 他ユーザーのSNSなど外部リンクを開く前に、移動先ドメインを明示して確認する。
/// フィッシング・誤タップ対策。
Future<void> openExternalLink(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  final host = prettyHost(url);

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('外部サイトに移動します'),
      content: Text(
        '次のサイトを開きます。\n\n$host\n\n'
        'リンク先の内容について本アプリは責任を負いません。'
        '不審なURLにはご注意ください。',
        style: const TextStyle(height: 1.6),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
          child: const Text('開く'),
        ),
      ],
    ),
  );

  if (ok == true) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

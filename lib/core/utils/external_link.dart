import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/app_colors.dart';
import '../supabase/supabase_config.dart';

/// URL から表示用のドメイン（host）を取り出す。www. は除去する。
String prettyHost(String url) {
  final uri = Uri.tryParse(url);
  final host = (uri != null && uri.host.isNotEmpty) ? uri.host : url;
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// 他ユーザーのSNSなど外部リンクを開く前に、移動先ドメインを明示して確認する。
/// [ownerUserId] を渡すと、開封を Gear R 解析用に記録する（自分のリンクは渡さない）。
Future<void> openExternalLink(
  BuildContext context,
  String url, {
  String? ownerUserId,
  String? platform,
}) async {
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
    if (ownerUserId != null && ownerUserId.isNotEmpty) {
      // 失敗してもリンク開封自体は続行
      try {
        await SupabaseConfig.client.rpc('record_sns_link_click', params: {
          'p_owner_user_id': ownerUserId,
          'p_platform': platform,
          'p_url': url,
        });
      } catch (_) {}
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

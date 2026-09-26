import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/constants/app_colors.dart';
import '../../core/supabase/storage_url_helper.dart';
import '../../core/utils/share_card_capture.dart';
import '../../features/groups/models/group_model.dart';

/// グループの告知カード画像を生成し、OSの共有シート（X/Instagram/LINE等）
/// へ渡す。外部SNSでのメンバー集めに使う。
/// 招待制(inviteOnly)のグループは呼び出し元で共有ボタン自体を出さないこと。
Future<void> shareGroup(BuildContext context, GroupModel group) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(
        content: Text('シェア画像を作成しています…'), duration: Duration(seconds: 6)),
  );

  final sharePositionOrigin = resolveSharePositionOrigin(context);

  try {
    String? iconUrl;
    if (group.iconUrl != null && group.iconUrl!.isNotEmpty) {
      try {
        iconUrl = await StorageUrlHelper.resolve(group.iconUrl!,
            defaultBucket: 'group-photos');
      } catch (e) {
        debugPrint('[Share] グループ画像の解決に失敗: $e');
      }
    }
    if (context.mounted && iconUrl != null) {
      try {
        await precacheImage(CachedNetworkImageProvider(iconUrl), context);
      } catch (e) {
        debugPrint('[Share] グループ画像の事前読み込みに失敗: $e');
      }
    }
    if (!context.mounted) return;

    final bytes = await captureWidgetAsPng(
      context,
      _GroupShareCard(group: group, iconUrl: iconUrl),
    );

    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/yahe_share_group_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(bytes);

    messenger.hideCurrentSnackBar();
    final result = await Share.shareXFiles(
      [XFile(file.path)],
      text: '🚗 ${group.name}\nYAHEでメンバー募集中！\n#YAHE #すれ違いアプリ',
      sharePositionOrigin: sharePositionOrigin,
    );
    debugPrint('[Share] shareXFiles result: ${result.status}');
    unawaited(file.delete().catchError((_) => file));
  } catch (e, st) {
    debugPrint('[Share] グループシェア画像の作成に失敗: $e\n$st');
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text('シェア画像の作成に失敗しました: $e')),
    );
  }
}

class _GroupShareCard extends StatelessWidget {
  final GroupModel group;
  final String? iconUrl;
  const _GroupShareCard({required this.group, this.iconUrl});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1080,
      height: 1350,
      padding: const EdgeInsets.fromLTRB(60, 100, 60, 60),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A1A2E), Color(0xFF0F0F1A)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(200),
            child: SizedBox(
              width: 320,
              height: 320,
              child: iconUrl != null
                  ? CachedNetworkImage(imageUrl: iconUrl!, fit: BoxFit.cover)
                  : Container(
                      color: Colors.white12,
                      child: const Icon(Icons.groups,
                          color: Colors.white38, size: 140),
                    ),
            ),
          ),
          const SizedBox(height: 48),
          Text(
            group.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white, fontSize: 56, fontWeight: FontWeight.w900),
          ),
          if (group.description != null && group.description!.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              group.description!,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 28, height: 1.5),
            ),
          ],
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.15),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              '👥 ${group.memberCount}人が参加中',
              style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 30,
                  fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 40),
          const Text(
            'YAHE',
            style: TextStyle(
                color: AppColors.primary,
                fontSize: 44,
                fontWeight: FontWeight.w900,
                letterSpacing: 10),
          ),
          const SizedBox(height: 6),
          const Text(
            'でメンバー募集中',
            style: TextStyle(color: Colors.white54, fontSize: 22),
          ),
        ],
      ),
    );
  }
}

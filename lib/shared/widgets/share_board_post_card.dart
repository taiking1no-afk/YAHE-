import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/constants/app_colors.dart';
import '../../core/supabase/storage_url_helper.dart';
import '../../core/utils/share_card_capture.dart';
import '../../features/boards/models/board_post_model.dart';

/// 募集(ツーリング/イベント)の告知カード画像を生成し、OSの共有シート
/// （X/Instagram/LINE等）へ渡す。外部SNSでの集客用。
/// 招待制(invite_only)の募集は呼び出し元で共有ボタン自体を出さないこと。
Future<void> shareBoardPost(BuildContext context, BoardPostModel post) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(
        content: Text('シェア画像を作成しています…'), duration: Duration(seconds: 6)),
  );

  final sharePositionOrigin = resolveSharePositionOrigin(context);

  try {
    String? imageUrl;
    if (post.imagePath != null && post.imagePath!.isNotEmpty) {
      try {
        imageUrl = await StorageUrlHelper.resolve(post.imagePath!,
            defaultBucket: 'board-photos');
      } catch (e) {
        debugPrint('[Share] 募集画像の解決に失敗: $e');
      }
    }
    if (context.mounted && imageUrl != null) {
      try {
        await precacheImage(CachedNetworkImageProvider(imageUrl), context);
      } catch (e) {
        debugPrint('[Share] 募集画像の事前読み込みに失敗: $e');
      }
    }
    if (!context.mounted) return;

    final bytes = await captureWidgetAsPng(
      context,
      _BoardShareCard(post: post, imageUrl: imageUrl),
    );

    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/yahe_share_board_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(bytes);

    final dateLabel = post.scheduledAt != null
        ? DateFormat('M月d日(E) HH:mm', 'ja').format(post.scheduledAt!)
        : '';

    messenger.hideCurrentSnackBar();
    final result = await Share.shareXFiles(
      [XFile(file.path)],
      text: '🚗 ${post.title}\n$dateLabel\nYAHEで参加者募集中！\n#YAHE #すれ違いアプリ',
      sharePositionOrigin: sharePositionOrigin,
    );
    debugPrint('[Share] shareXFiles result: ${result.status}');
    unawaited(file.delete().catchError((_) => file));
  } catch (e, st) {
    debugPrint('[Share] 募集シェア画像の作成に失敗: $e\n$st');
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text('シェア画像の作成に失敗しました: $e')),
    );
  }
}

class _BoardShareCard extends StatelessWidget {
  final BoardPostModel post;
  final String? imageUrl;
  const _BoardShareCard({required this.post, this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1080,
      height: 1350,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A1A2E), Color(0xFF0F0F1A)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 560,
            child: imageUrl != null
                ? CachedNetworkImage(imageUrl: imageUrl!, fit: BoxFit.cover)
                : Container(
                    color: Colors.white12,
                    alignment: Alignment.center,
                    child: Icon(
                      post.postType.value == 'touring'
                          ? Icons.two_wheeler
                          : Icons.event_available_outlined,
                      color: Colors.white38,
                      size: 140,
                    ),
                  ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(60, 48, 60, 48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      post.postType.label,
                      style: const TextStyle(
                          color: AppColors.primary,
                          fontSize: 26,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    post.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 52,
                        fontWeight: FontWeight.w900,
                        height: 1.2),
                  ),
                  const Spacer(),
                  if (post.scheduledAt != null)
                    _InfoLine(
                      icon: Icons.event,
                      text: DateFormat('yyyy年M月d日(E) HH:mm', 'ja')
                          .format(post.scheduledAt!),
                    ),
                  if ((post.meetingPlaceText ?? post.prefecture) != null)
                    _InfoLine(
                      icon: Icons.place_outlined,
                      text: post.meetingPlaceText ?? post.prefecture!,
                    ),
                  _InfoLine(
                    icon: Icons.people_outline,
                    text: post.capacity != null
                        ? '${post.joinedCount} / ${post.capacity}人 参加中'
                        : '${post.joinedCount}人 参加中',
                  ),
                  const SizedBox(height: 24),
                  const Row(
                    children: [
                      Text(
                        'YAHE',
                        style: TextStyle(
                            color: AppColors.primary,
                            fontSize: 40,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 8),
                      ),
                      SizedBox(width: 12),
                      Text('で参加者募集中',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 22)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoLine({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 26),
            ),
          ),
        ],
      ),
    );
  }
}

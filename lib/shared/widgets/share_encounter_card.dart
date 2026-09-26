import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/constants/app_colors.dart';
import '../../core/supabase/storage_url_helper.dart';
import '../../core/utils/share_card_capture.dart';
import '../../features/vehicle/models/vehicle.dart';
import '../models/user_model.dart';

/// 「初めてのすれ違い」「マッチ」の瞬間に、相手の愛車写真・ニックネームを
/// 入れたシェアカード画像を生成し、OSの共有シート（X/Instagram/LINE等）へ渡す。
///
/// プライバシー方針: SNSリンクなど、マッチしていないと開示されない情報は
/// 含めない。ここに載せるのは相手の愛車写真・ニックネームのみで、これらは
/// すれ違った時点でアプリ内のプロフィールシートに既に表示されている情報
/// （オーナー方針：段階1から表示可）であり、共有によって新たに露出する
/// 情報ではない。
Future<void> shareEncounter({
  required BuildContext context,
  required String occasionEmoji,
  required String occasionTitle,
  UserModel? myUser,
  Vehicle? myVehicle,
  UserModel? otherUser,
  Vehicle? otherVehicle,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(
        content: Text('シェア画像を作成しています…'), duration: Duration(seconds: 6)),
  );

  // iOSの共有シートは吹き出しの基準位置(sharePositionOrigin)が必須
  // （未指定/nullだと「argument must be set」でPlatformExceptionになる）。
  // 呼び出し元のボタン位置を、後続のawaitで消える前にここで確定させておく。
  final sharePositionOrigin = resolveSharePositionOrigin(context);

  try {
    final myPhotoUrl = await _resolvePhotoUrl(myVehicle);
    final otherPhotoUrl = await _resolvePhotoUrl(otherVehicle);

    // 事前にデコードしておき、キャプチャ時に非同期の読み込み待ちが発生しないようにする。
    // 1枚の画像取得に失敗しても、その写真だけプレースホルダーにして続行する
    // （ネットワーク瞬断などで共有全体が失敗する事態を避ける）。
    if (context.mounted && myPhotoUrl != null) {
      try {
        await precacheImage(CachedNetworkImageProvider(myPhotoUrl), context);
      } catch (e) {
        debugPrint('[Share] 自分の車両写真の事前読み込みに失敗: $e');
      }
    }
    if (context.mounted && otherPhotoUrl != null) {
      try {
        await precacheImage(CachedNetworkImageProvider(otherPhotoUrl), context);
      } catch (e) {
        debugPrint('[Share] 相手の車両写真の事前読み込みに失敗: $e');
      }
    }
    if (!context.mounted) return;

    final bytes = await captureWidgetAsPng(
      context,
      _ShareCard(
        occasionEmoji: occasionEmoji,
        occasionTitle: occasionTitle,
        myNickname: myUser?.nickname ?? 'あなた',
        myPhotoUrl: myPhotoUrl,
        otherNickname: otherUser?.nickname ?? '???',
        otherPhotoUrl: otherPhotoUrl,
      ),
    );

    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/yahe_share_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(bytes);

    messenger.hideCurrentSnackBar();
    final result = await Share.shareXFiles(
      [XFile(file.path)],
      text: '$occasionEmoji $occasionTitle\n#YAHE #すれ違いアプリ',
      sharePositionOrigin: sharePositionOrigin,
    );
    debugPrint('[Share] shareXFiles result: ${result.status}');
    // 共有シートが閉じた後は不要なので削除する（削除せずに溜め続けると
    // 連続シェアでストレージを圧迫する）。
    unawaited(file.delete().catchError((_) => file));
  } catch (e, st) {
    debugPrint('[Share] シェア画像の作成に失敗: $e\n$st');
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text('シェア画像の作成に失敗しました: $e')),
    );
  }
}

Future<String?> _resolvePhotoUrl(Vehicle? vehicle) async {
  final photo = vehicle?.photos.firstOrNull;
  if (photo == null || photo.isEmpty) return null;
  try {
    return await StorageUrlHelper.resolve(photo);
  } catch (_) {
    return null;
  }
}

class _ShareCard extends StatelessWidget {
  final String occasionEmoji;
  final String occasionTitle;
  final String myNickname;
  final String? myPhotoUrl;
  final String otherNickname;
  final String? otherPhotoUrl;

  const _ShareCard({
    required this.occasionEmoji,
    required this.occasionTitle,
    required this.myNickname,
    this.myPhotoUrl,
    required this.otherNickname,
    this.otherPhotoUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1080,
      height: 1350,
      padding: const EdgeInsets.fromLTRB(60, 90, 60, 60),
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
          Text(occasionEmoji, style: const TextStyle(fontSize: 100)),
          const SizedBox(height: 24),
          Text(
            occasionTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 56,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 60),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                    child: _CardVehicle(
                        nickname: myNickname, photoUrl: myPhotoUrl)),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('✕',
                      style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 48,
                          fontWeight: FontWeight.w900)),
                ),
                Expanded(
                    child: _CardVehicle(
                        nickname: otherNickname, photoUrl: otherPhotoUrl)),
              ],
            ),
          ),
          const SizedBox(height: 40),
          const Text(
            'YAHE',
            style: TextStyle(
              color: AppColors.primary,
              fontSize: 44,
              fontWeight: FontWeight.w900,
              letterSpacing: 10,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '改造車・スポーツカーオーナーのすれ違いマッチング',
            style: TextStyle(color: Colors.white54, fontSize: 22),
          ),
        ],
      ),
    );
  }
}

class _CardVehicle extends StatelessWidget {
  final String nickname;
  final String? photoUrl;
  const _CardVehicle({required this.nickname, this.photoUrl});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: SizedBox(
            width: double.infinity,
            height: 380,
            child: photoUrl != null
                ? CachedNetworkImage(imageUrl: photoUrl!, fit: BoxFit.cover)
                : Container(
                    color: Colors.white12,
                    child: const Icon(Icons.directions_car,
                        color: Colors.white38, size: 72),
                  ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          nickname,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Colors.white, fontSize: 32, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

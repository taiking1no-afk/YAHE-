import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../core/supabase/storage_url_helper.dart';

/// 非公開 Storage オブジェクトを署名付き URL 経由で表示する
class SignedStorageImage extends StatelessWidget {
  final String storedReference;
  final String defaultBucket;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;

  const SignedStorageImage({
    super.key,
    required this.storedReference,
    this.defaultBucket = 'vehicle-photos',
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    if (storedReference.isEmpty) {
      return placeholder ?? const SizedBox.shrink();
    }

    return FutureBuilder<String>(
      future: StorageUrlHelper.resolve(
        storedReference,
        defaultBucket: defaultBucket,
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return placeholder ??
              SizedBox(
                width: width,
                height: height,
                child: const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
        }

        final url = snapshot.data;
        if (url == null || url.isEmpty) {
          return placeholder ?? const SizedBox.shrink();
        }

        // 表示サイズに合わせてデコード解像度を落とす（フル解像度のままだと
        // サムネイル表示でも重いデコード・大きなメモリ確保が走り、リスト描画が重くなる）。
        // width/height に double.infinity が渡されるケース（画面幅いっぱいに表示、等）
        // があるため、有限値のときだけ計算する（Infinity.round() は例外になる）。
        final w = width;
        final h = height;
        final dpr = MediaQuery.of(context).devicePixelRatio;
        final memCacheWidth = (w != null && w.isFinite) ? (w * dpr).round() : null;
        final memCacheHeight = (h != null && h.isFinite) ? (h * dpr).round() : null;

        return CachedNetworkImage(
          imageUrl: url,
          width: width,
          height: height,
          fit: fit,
          memCacheWidth: memCacheWidth,
          memCacheHeight: memCacheHeight,
          placeholder: (_, __) =>
              placeholder ??
              SizedBox(
                width: width,
                height: height,
                child: const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          errorWidget: (_, __, ___) =>
              placeholder ??
              SizedBox(
                width: width,
                height: height,
                child: const Icon(Icons.broken_image_outlined),
              ),
        );
      },
    );
  }
}

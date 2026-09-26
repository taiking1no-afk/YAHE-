import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../core/supabase/storage_url_helper.dart';

/// 非公開 Storage オブジェクトを署名付き URL 経由で表示する
class SignedStorageImage extends StatefulWidget {
  final String storedReference;
  final String defaultBucket;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final Widget? placeholder;

  const SignedStorageImage({
    super.key,
    required this.storedReference,
    this.defaultBucket = 'vehicle-photos',
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.placeholder,
  });

  @override
  State<SignedStorageImage> createState() => _SignedStorageImageState();
}

class _SignedStorageImageState extends State<SignedStorageImage> {
  late Future<String> _future;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant SignedStorageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storedReference != widget.storedReference ||
        oldWidget.defaultBucket != widget.defaultBucket) {
      // 参照先が変わった場合のみ再解決する。
      _resolve();
    }
    // それ以外の再構築（親のRealtime更新など）では同じFutureを使い回すことで、
    // FutureBuilderがwaiting状態にリセットされてサムネイルが定期的に
    // ちらつく・URL取得が重複発行される問題を防ぐ。
  }

  void _resolve() {
    _future = StorageUrlHelper.resolve(
      widget.storedReference,
      defaultBucket: widget.defaultBucket,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.storedReference.isEmpty) {
      return widget.placeholder ?? const SizedBox.shrink();
    }

    return FutureBuilder<String>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return widget.placeholder ??
              SizedBox(
                width: widget.width,
                height: widget.height,
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
          return widget.placeholder ?? const SizedBox.shrink();
        }

        // 表示サイズに合わせてデコード解像度を落とす（フル解像度のままだと
        // サムネイル表示でも重いデコード・大きなメモリ確保が走り、リスト描画が重くなる）。
        // width/height に double.infinity が渡されるケース（画面幅いっぱいに表示、等）
        // があるため、有限値のときだけ計算する（Infinity.round() は例外になる）。
        final w = widget.width;
        final h = widget.height;
        final dpr = MediaQuery.of(context).devicePixelRatio;
        final memCacheWidth =
            (w != null && w.isFinite) ? (w * dpr).round() : null;
        final memCacheHeight =
            (h != null && h.isFinite) ? (h * dpr).round() : null;

        return CachedNetworkImage(
          imageUrl: url,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          alignment: widget.alignment,
          memCacheWidth: memCacheWidth,
          memCacheHeight: memCacheHeight,
          placeholder: (_, __) =>
              widget.placeholder ??
              SizedBox(
                width: widget.width,
                height: widget.height,
                child: const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          errorWidget: (_, __, ___) =>
              widget.placeholder ??
              SizedBox(
                width: widget.width,
                height: widget.height,
                child: const Icon(Icons.broken_image_outlined),
              ),
        );
      },
    );
  }
}

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// 画像として認識できないファイル（拡張子偽装・破損・非画像ファイル等）が
/// アップロードされようとしたときに投げる例外。呼び出し元でユーザーに
/// エラー表示すること。
class InvalidImageException implements Exception {
  final String message;
  const InvalidImageException([this.message = '画像として認識できませんでした']);
  @override
  String toString() => message;
}

/// アップロード前に画像から EXIF（GPS/撮影機器などのメタデータ）を除去し、
/// 必要に応じて縮小する。位置情報の漏洩を防ぐためのセキュリティ処理。
///
/// デコード → 再エンコードすることで EXIF は破棄される。
/// 重い処理なので別 Isolate (compute) で実行する。
///
/// デコードに失敗した場合（非画像ファイル・拡張子偽装・破損データ等）は
/// [InvalidImageException] を投げる。以前は失敗時に元の未検証バイト列を
/// そのままアップロードしてしまっており、非画像ファイルが偽装コンテンツ
/// タイプでStorageに保存され得る実体検査の抜け穴になっていた。
Future<Uint8List> sanitizeImageBytes(
  Uint8List input, {
  int maxDimension = 1600,
  int jpegQuality = 85,
}) async {
  try {
    return await compute(
      _sanitize,
      _SanitizeArgs(input, maxDimension, jpegQuality),
    );
  } catch (e) {
    debugPrint('[ImageSanitizer] 失敗: $e');
    throw const InvalidImageException();
  }
}

class _SanitizeArgs {
  final Uint8List bytes;
  final int maxDimension;
  final int jpegQuality;
  const _SanitizeArgs(this.bytes, this.maxDimension, this.jpegQuality);
}

Uint8List _sanitize(_SanitizeArgs args) {
  final decoded = img.decodeImage(args.bytes);
  if (decoded == null) {
    throw const InvalidImageException('画像を処理できませんでした');
  }

  // EXIF の回転情報を反映してから破棄（向きズレ防止）
  var image = img.bakeOrientation(decoded);

  final longest = image.width > image.height ? image.width : image.height;
  if (longest > args.maxDimension) {
    if (image.width >= image.height) {
      image = img.copyResize(image, width: args.maxDimension);
    } else {
      image = img.copyResize(image, height: args.maxDimension);
    }
  }

  // 再エンコード時にメタデータは引き継がれないため EXIF/GPS は除去される
  return Uint8List.fromList(img.encodeJpg(image, quality: args.jpegQuality));
}

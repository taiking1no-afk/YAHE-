import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// アップロード前に画像から EXIF（GPS/撮影機器などのメタデータ）を除去し、
/// 必要に応じて縮小する。位置情報の漏洩を防ぐためのセキュリティ処理。
///
/// デコード → 再エンコードすることで EXIF は破棄される。
/// 重い処理なので別 Isolate (compute) で実行する。
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
    debugPrint('[ImageSanitizer] 失敗（元画像をそのまま使用）: $e');
    return input;
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
  if (decoded == null) return args.bytes;

  // EXIF の回転情報を反映してから破棄（向きズレ防止）
  var image = img.bakeOrientation(decoded);

  final longest =
      image.width > image.height ? image.width : image.height;
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

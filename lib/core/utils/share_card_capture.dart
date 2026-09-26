import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 画面外にオーバーレイとして一瞬だけ描画し、RepaintBoundary経由でPNGに変換する。
/// シェアカード画像生成（すれ違い/マッチ・募集・グループ）で共通利用する。
Future<Uint8List> captureWidgetAsPng(BuildContext context, Widget card) async {
  if (!context.mounted) {
    throw StateError('画面が閉じられたため、シェア画像を作成できませんでした');
  }
  final repaintKey = GlobalKey();
  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;

  entry = OverlayEntry(
    builder: (_) => Positioned(
      left: -3000,
      top: 0,
      child: Material(
        color: Colors.transparent,
        child: RepaintBoundary(
          key: repaintKey,
          child: card,
        ),
      ),
    ),
  );

  overlay.insert(entry);

  try {
    // insert() 直後はまだ build/layout/paint が済んでいないため、
    // 実際に1フレーム描画完了するまで確実に待つ（固定待機のみだと
    // 実機負荷が高いタイミングで描画が間に合わず失敗することがあった）。
    await WidgetsBinding.instance.endOfFrame;
    // 画像デコード後の再描画分の余裕を持たせる
    await Future.delayed(const Duration(milliseconds: 150));
    await WidgetsBinding.instance.endOfFrame;

    final boundary =
        repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      throw StateError('シェアカードの描画コンテキストを取得できませんでした');
    }
    final image = await boundary.toImage(pixelRatio: 2.0);
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw StateError('画像データへの変換に失敗しました');
      }
      return byteData.buffer.asUint8List();
    } finally {
      // ui.Imageはネイティブ側のメモリを保持したままGCに委ねられないため、
      // 明示的に破棄しないと連続シェアでネイティブメモリを圧迫していた。
      image.dispose();
    }
  } finally {
    entry.remove();
  }
}

/// シェアボタンをタップした位置を、共有シート（iOSのポップオーバー）の
/// 基準位置として使う。取得できない場合は画面中央の1x1矩形を仮の基準にする
/// （iOSの共有シートは sharePositionOrigin が必須で、未指定だとエラーになる）。
Rect resolveSharePositionOrigin(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  final screenSize = MediaQuery.of(context).size;
  if (box != null && box.hasSize) {
    return box.localToGlobal(Offset.zero) & box.size;
  }
  return Rect.fromCenter(
    center: Offset(screenSize.width / 2, screenSize.height / 2),
    width: 1,
    height: 1,
  );
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import '../constants/app_colors.dart';

/// アイコン系画像（プロフィール・グループ）を正方形にトリミングする共通処理。
/// ユーザーが表示したい部分を選べるよう、ネイティブのトリミングUIを挟む。
Future<File?> cropSquareImage(BuildContext context, String sourcePath) async {
  final cropped = await ImageCropper().cropImage(
    sourcePath: sourcePath,
    aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
    compressQuality: 85,
    maxWidth: 800,
    maxHeight: 800,
    uiSettings: [
      AndroidUiSettings(
        toolbarTitle: '表示範囲を選択',
        toolbarColor: AppColors.primary,
        toolbarWidgetColor: Colors.white,
        lockAspectRatio: true,
        hideBottomControls: false,
      ),
      IOSUiSettings(
        title: '表示範囲を選択',
        aspectRatioLockEnabled: true,
        resetAspectRatioEnabled: false,
      ),
    ],
  );
  if (cropped == null) return null;
  return File(cropped.path);
}

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/foundation.dart';

/// iOS App Tracking Transparency（ATT）
/// AdMob 初期化・広告ロードの前に呼ぶこと。
class AttService {
  AttService._();

  static bool get _isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// トラッキング許可をリクエスト。非iOSでは notSupported。
  static Future<TrackingStatus> requestPermission() async {
    if (!_isIos) return TrackingStatus.notSupported;

    final status = await AppTrackingTransparency.trackingAuthorizationStatus;
    if (status != TrackingStatus.notDetermined) {
      debugPrint('[ATT] already decided: $status');
      return status;
    }

    // ダイアログ表示前に短く待つ（初回描画の安定待ち）
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final result =
        await AppTrackingTransparency.requestTrackingAuthorization();
    debugPrint('[ATT] result: $result');
    return result;
  }

  static Future<bool> isTrackingAuthorized() async {
    if (!_isIos) return true;
    final status = await AppTrackingTransparency.trackingAuthorizationStatus;
    return status == TrackingStatus.authorized;
  }
}

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../core/ads/att_service.dart';
import '../../core/config/yahe_secrets.dart';

class AdService {
  static final AdService _instance = AdService._internal();
  factory AdService() => _instance;
  AdService._internal();

  // Google 公式テストユニット（デバッグ専用）
  static const _testIosBanner = 'ca-app-pub-3940256099942544/2934735716';
  static const _testAndroidBanner = 'ca-app-pub-3940256099942544/6300978111';

  bool _initialized = false;

  /// リリースでは本番ユニット必須。未設定なら広告を出さない。
  static bool get _useTestAds => kDebugMode;

  static String get bannerAdUnitId {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      if (_useTestAds || !YaheSecrets.hasIosBanner) {
        if (!_useTestAds && !YaheSecrets.hasIosBanner) {
          debugPrint('[Ad] iOS banner ID 未設定 → 広告スキップ');
        }
        return _useTestAds ? _testIosBanner : '';
      }
      return YaheSecrets.admobIosBannerId;
    }
    if (_useTestAds || !YaheSecrets.hasAndroidBanner) {
      if (!_useTestAds && !YaheSecrets.hasAndroidBanner) {
        debugPrint('[Ad] Android banner ID 未設定 → 広告スキップ');
      }
      return _useTestAds ? _testAndroidBanner : '';
    }
    return YaheSecrets.admobAndroidBannerId;
  }

  static bool get canShowAds => bannerAdUnitId.isNotEmpty;

  Future<void> initialize() async {
    if (_initialized) return;

    // ATT を広告SDK初期化より先に（iOS必須）
    await AttService.requestPermission();

    if (!_useTestAds &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        !YaheSecrets.hasAdMobIosAppId) {
      debugPrint('[Ad] iOS App ID 未設定（Info.plistも確認）→ AdMob初期化スキップ');
      return;
    }
    if (!_useTestAds &&
        defaultTargetPlatform == TargetPlatform.android &&
        !YaheSecrets.hasAdMobAndroidAppId) {
      debugPrint('[Ad] Android App ID 未設定（Manifestも確認）→ AdMob初期化スキップ');
      return;
    }

    await MobileAds.instance.initialize();
    _initialized = true;
    debugPrint('[Ad] MobileAds initialized (testAds=$_useTestAds)');
  }
}

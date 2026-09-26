/// YAHE 本番シークレット（dart-define / dart_defines.json から注入）
///
/// 使い方:
/// 1. `dart_defines.json.example` をコピーして `dart_defines.json` を作成
/// 2. AdMob / RevenueCat の本番値を記入
/// 3. 実行例:
///    flutter run --dart-define-from-file=dart_defines.json
///    flutter build ipa --dart-define-from-file=dart_defines.json
///
/// Info.plist / AndroidManifest の APPLICATION_ID も同じ App ID に揃えること。
class YaheSecrets {
  YaheSecrets._();

  // ── AdMob App ID（ca-app-pub-xxxx~yyyy）────────────────
  static const admobIosAppId = String.fromEnvironment('ADMOB_IOS_APP_ID');
  static const admobAndroidAppId =
      String.fromEnvironment('ADMOB_ANDROID_APP_ID');

  // ── AdMob Banner Unit ID（ca-app-pub-xxxx/yyyy）────────
  static const admobIosBannerId = String.fromEnvironment('ADMOB_IOS_BANNER_ID');
  static const admobAndroidBannerId =
      String.fromEnvironment('ADMOB_ANDROID_BANNER_ID');

  // ── RevenueCat ─────────────────────────────────────────
  static const revenueCatIosKey = String.fromEnvironment(
    'REVENUECAT_IOS_KEY',
    defaultValue: 'appl_EVCBOGVJIBCqjNBaheyAEXoLikk',
  );
  static const revenueCatAndroidKey = String.fromEnvironment(
    'REVENUECAT_ANDROID_KEY',
  );

  static bool get hasAdMobIosAppId =>
      admobIosAppId.startsWith('ca-app-pub-') &&
      !admobIosAppId.contains('3940256099942544');

  static bool get hasAdMobAndroidAppId =>
      admobAndroidAppId.startsWith('ca-app-pub-') &&
      !admobAndroidAppId.contains('3940256099942544');

  static bool get hasIosBanner =>
      admobIosBannerId.startsWith('ca-app-pub-') &&
      !admobIosBannerId.contains('3940256099942544');

  static bool get hasAndroidBanner =>
      admobAndroidBannerId.startsWith('ca-app-pub-') &&
      !admobAndroidBannerId.contains('3940256099942544');

  static bool get hasRevenueCatAndroidKey =>
      revenueCatAndroidKey.startsWith('goog_') &&
      revenueCatAndroidKey.length > 12 &&
      !revenueCatAndroidKey.contains('XXXX');
}

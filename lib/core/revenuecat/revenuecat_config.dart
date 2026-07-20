import 'package:flutter/foundation.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../config/yahe_secrets.dart';

class RevenueCatConfig {
  RevenueCatConfig._();

  // RevenueCat ダッシュボード → Apps → API Keys
  // 本番 Android キーは dart_defines.json の REVENUECAT_ANDROID_KEY で注入
  static String get _iosApiKey => YaheSecrets.revenueCatIosKey;
  static String get _androidApiKey => YaheSecrets.revenueCatAndroidKey;

  static bool get isConfigured {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final key = _iosApiKey;
      return key.startsWith('appl_') && key.length > 12;
    }
    return YaheSecrets.hasRevenueCatAndroidKey;
  }

  // 起動時は runApp をブロックせず並行して初期化する。Purchases.* を呼ぶ
  // 各メソッドはこの Future を待ってから実行することで、初期化未完了のまま
  // SDK を呼んで失敗する事故を防ぐ。
  static Future<void>? _initFuture;

  static Future<void> initialize({String? userId}) {
    return _initFuture ??= _doInitialize(userId: userId);
  }

  static Future<void> _doInitialize({String? userId}) async {
    if (!isConfigured) {
      debugPrint('[RevenueCat] skipped: API key not configured');
      return;
    }

    final config = PurchasesConfiguration(
      defaultTargetPlatform == TargetPlatform.iOS ? _iosApiKey : _androidApiKey,
    );

    if (userId != null) {
      config.appUserID = userId;
    }

    await Purchases.configure(config);

    if (kDebugMode) {
      await Purchases.setLogLevel(LogLevel.debug);
    }

    debugPrint('[RevenueCat] initialized');
  }

  /// ログイン後にユーザーIDを同期
  static Future<void> logIn(String userId) async {
    if (!isConfigured) return;
    await _initFuture;
    try {
      final result = await Purchases.logIn(userId);
      debugPrint('[RevenueCat] logIn: ${result.customerInfo.originalAppUserId}');
    } catch (e) {
      debugPrint('[RevenueCat] logIn error: $e');
    }
  }

  /// ログアウト時にリセット
  static Future<void> logOut() async {
    if (!isConfigured) return;
    await _initFuture;
    try {
      await Purchases.logOut();
    } catch (e) {
      debugPrint('[RevenueCat] logOut error: $e');
    }
  }

  /// サブスクリプションの有効確認
  static Future<bool> isGearPlusActive() async {
    if (!isConfigured) return false;
    await _initFuture;
    try {
      final info = await Purchases.getCustomerInfo();
      return info.entitlements.active.containsKey('gear_plus') ||
          info.entitlements.active.containsKey('gear_r');
    } catch (_) {
      return false;
    }
  }

  /// Gear R 有効確認
  static Future<bool> isGearRActive() async {
    if (!isConfigured) return false;
    await _initFuture;
    try {
      final info = await Purchases.getCustomerInfo();
      return info.entitlements.active.containsKey('gear_r');
    } catch (_) {
      return false;
    }
  }

  /// ピットイン有効確認
  static Future<bool> isPitInActive() async {
    if (!isConfigured) return false;
    await _initFuture;
    try {
      final info = await Purchases.getCustomerInfo();
      return info.entitlements.active.containsKey('pit_in');
    } catch (_) {
      return false;
    }
  }

  /// サブスクを購入（Gear+ / Gear R / ピットイン 共通）
  static Future<CustomerInfo?> purchaseSubscription(String productId) async {
    if (!isConfigured) return null;
    await _initFuture;
    try {
      final result = await Purchases.purchaseProduct(
        productId,
        type: PurchaseType.subs,
      );
      return result;
    } on PurchasesErrorCode catch (e) {
      if (e == PurchasesErrorCode.purchaseCancelledError) return null;
      rethrow;
    }
  }

  /// 購入を復元（ユーザーが「購入を復元」を押した時）
  static Future<CustomerInfo?> restorePurchases() async {
    if (!isConfigured) return null;
    await _initFuture;
    try {
      return await Purchases.restorePurchases();
    } catch (e) {
      debugPrint('[RevenueCat] restore error: $e');
      return null;
    }
  }
}

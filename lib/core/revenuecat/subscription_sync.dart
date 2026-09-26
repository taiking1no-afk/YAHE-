import 'package:flutter/foundation.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import '../supabase/supabase_config.dart';
import 'revenuecat_config.dart';

/// RevenueCat の状態をサーバー検証付きで Supabase に同期する。
/// クライアントから plan を直接書くことは禁止（Edge Function + Webhook のみ）。
class SubscriptionSync {
  SubscriptionSync._();

  /// ログイン後・購入後に呼び出し。同期成功時 true。
  static Future<bool> syncToSupabase(String userId, {String? productId}) async {
    if (!RevenueCatConfig.isConfigured) return false;

    try {
      await Purchases.getCustomerInfo();
      return _invokeSync(productId: productId);
    } catch (e) {
      debugPrint('[SubscriptionSync] sync error: $e');
      return false;
    }
  }

  /// 購入直後の CustomerInfo を反映。
  static Future<bool> applyPurchase(
    String userId,
    CustomerInfo info, {
    String? productId,
  }) async {
    return _invokeSync(productId: productId);
  }

  static Future<bool> _invokeSync({String? productId}) async {
    try {
      final res = await SupabaseConfig.client.functions.invoke(
        'sync-subscription',
        body: {
          if (productId != null) 'product_id': productId,
        },
      );
      final data = res.data;
      if (data is Map && data['ok'] == true) {
        debugPrint('[SubscriptionSync] plan=${data['plan']}');
        return true;
      }
      debugPrint('[SubscriptionSync] unexpected: $data');
      return false;
    } catch (e) {
      debugPrint('[SubscriptionSync] invoke error: $e');
      return false;
    }
  }

  /// Gear+ 初月無料のお試しがまだ使えるか（RevenueCat 側の intro eligibility）。
  static Future<bool> isGearPlusIntroEligible() async {
    if (!RevenueCatConfig.isConfigured) return true;
    try {
      final info = await Purchases.getCustomerInfo();
      if (info.entitlements.active.containsKey('gear_plus') ||
          info.entitlements.active.containsKey('gear_r')) {
        return false;
      }
      if (info.allPurchasedProductIdentifiers
          .contains('yahe_gear_plus_monthly')) {
        return false;
      }
      return true;
    } catch (_) {
      return true;
    }
  }
}

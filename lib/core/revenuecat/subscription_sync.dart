import 'package:flutter/foundation.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import '../constants/app_constants.dart';
import 'revenuecat_config.dart';
import '../../features/profile/data/user_repository.dart';

/// RevenueCat のエンタイトルメント状態を Supabase に同期する。
class SubscriptionSync {
  SubscriptionSync._();

  static const _gearPlusEntitlement = 'gear_plus';
  static const _gearREntitlement = 'gear_r';
  static const _pitInEntitlement = 'pit_in';

  /// ログイン後・購入後に呼び出し。同期成功時 true。
  static Future<bool> syncToSupabase(String userId) async {
    if (!RevenueCatConfig.isConfigured) return false;

    try {
      final info = await Purchases.getCustomerInfo();
      return _applyCustomerInfo(userId, info);
    } catch (e) {
      debugPrint('[SubscriptionSync] sync error: $e');
      return false;
    }
  }

  /// 購入直後の CustomerInfo を反映。
  static Future<bool> applyPurchase(String userId, CustomerInfo info) async {
    return _applyCustomerInfo(userId, info);
  }

  static Future<bool> _applyCustomerInfo(
    String userId,
    CustomerInfo info,
  ) async {
    final gearR = info.entitlements.active[_gearREntitlement];
    if (gearR != null) {
      await UserRepository().syncSubscriptionPlan(
        userId: userId,
        plan: 'gear_r',
        markTrialUsed: true,
      );
      return true;
    }

    final gearPlus = info.entitlements.active[_gearPlusEntitlement];
    if (gearPlus != null) {
      final trialEnds = _introTrialEndsAt(gearPlus);
      await UserRepository().syncSubscriptionPlan(
        userId: userId,
        plan: 'gear_plus',
        trialEndsAt: trialEnds,
        markTrialUsed: true,
      );
      return true;
    }

    final pitIn = info.entitlements.active[_pitInEntitlement];
    if (pitIn != null) {
      await UserRepository().syncSubscriptionPlan(
        userId: userId,
        plan: 'pit_in',
      );
      return true;
    }

    await UserRepository().syncSubscriptionPlan(
      userId: userId,
      plan: 'free',
    );
    return false;
  }

  /// イントロオファー / 無料トライアル期間中のみ終了日時を返す。
  static DateTime? _introTrialEndsAt(EntitlementInfo entitlement) {
    final periodType = entitlement.periodType;
    if (periodType != PeriodType.trial && periodType != PeriodType.intro) {
      return null;
    }
    final raw = entitlement.expirationDate;
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// Gear+ 初月無料のお試しがまだ使えるか（RevenueCat 側の intro eligibility）。
  static Future<bool> isGearPlusIntroEligible() async {
    if (!RevenueCatConfig.isConfigured) return true;
    try {
      final info = await Purchases.getCustomerInfo();
      if (info.entitlements.active.containsKey(_gearPlusEntitlement) ||
          info.entitlements.active.containsKey(_gearREntitlement)) {
        return false;
      }
      if (info.allPurchasedProductIdentifiers
          .contains(AppConstants.gearPlusProductId)) {
        return false;
      }
      return true;
    } catch (_) {
      return true;
    }
  }
}

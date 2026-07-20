import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 同一ユーザーとのすれ違い重複防止の設定。
/// 本番: 1日1回 / テストモード: 5分（連続テスト用）
class EncounterDedupe {
  EncounterDedupe._();

  static const productionWindow = Duration(days: 1);
  static const testWindow = Duration(minutes: 5);

  /// BLE スキャン結果の短時間重複防止（同一端末からの連続パケット）
  static const bleDeviceWindow = Duration(minutes: 5);
}

/// テスト時のみ1日制限を緩和するモード。
/// - デバッグビルド: ローカルトグルのみで有効化可
/// - リリースビルド: Supabase の users.encounter_test_mode = true が必要
class EncounterTestMode {
  EncounterTestMode._();

  static const _prefKey = 'encounter_test_mode_enabled';

  static bool _localEnabled = false;
  static bool _serverAllowed = false;
  static bool _loaded = false;

  static bool get isActive =>
      _localEnabled && (_serverAllowed || kDebugMode);

  static Duration get userDedupeWindow =>
      isActive ? EncounterDedupe.testWindow : EncounterDedupe.productionWindow;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _localEnabled = prefs.getBool(_prefKey) ?? false;
    _loaded = true;
  }

  static void setServerAllowed(bool allowed) {
    _serverAllowed = allowed;
  }

  static Future<void> setLocalEnabled(bool value) async {
    _localEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, value);
  }

  static bool get localEnabled => _localEnabled;
  static bool get serverAllowed => _serverAllowed;

  /// RPC に p_test_mode を渡すか（サーバー側でも短い窓を使う）
  static bool get sendTestModeToServer => isActive;

  static String get statusLabel {
    if (!_loaded) return '読込中...';
    if (!isActive) {
      return 'OFF（同一相手: 1日1回）';
    }
    return 'ON（同一相手: 5分間隔で再テスト可）';
  }
}

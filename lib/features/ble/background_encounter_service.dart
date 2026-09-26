import 'dart:async';
import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/supabase/supabase_config.dart';
import 'ble_encounter_service.dart';

const _kBgEnabledKey = 'background_detection_enabled';
const _kBgUserId = 'background_user_id';
const _kBgIsPremium = 'background_is_premium';

/// バックグラウンドすれ違い検知サービス管理クラス
class BackgroundEncounterService {
  static final _instance = BackgroundEncounterService._();
  factory BackgroundEncounterService() => _instance;
  BackgroundEncounterService._();

  /// ユーザー設定の読み書き
  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kBgEnabledKey) ?? false;
  }

  static Future<void> setEnabled(bool value,
      {String? userId, bool isPremium = false}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBgEnabledKey, value);
    if (userId != null) {
      await prefs.setString(_kBgUserId, userId);
      await prefs.setBool(_kBgIsPremium, isPremium);
    }
    if (value) {
      await _startService();
    } else {
      await _stopService();
    }
  }

  /// サービス初期化（app起動時に呼ぶ）
  static Future<void> initialize() async {
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onServiceStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'yahe_bg_encounter',
        initialNotificationTitle: 'YAHE バックグラウンド検知中',
        initialNotificationContent: 'すれ違いを検知しています...',
        foregroundServiceNotificationId: 9988,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onServiceStart,
        onBackground: _onIosBackground,
      ),
    );

    // 前回有効だった場合は自動起動
    final enabled = await isEnabled();
    if (enabled) {
      await _startService();
    }
  }

  static Future<void> _startService() async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    }
  }

  static Future<void> _stopService() async {
    final service = FlutterBackgroundService();
    service.invoke('stop');
  }
}

// ─── iOS バックグラウンドハンドラー ──────────────────────────────
// BGAppRefreshTask 発火時（数時間に1回）に BLE スキャンが停止していれば再起動する
@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final userId = prefs.getString(_kBgUserId);
  final isPremium = prefs.getBool(_kBgIsPremium) ?? false;
  if (userId != null) {
    try {
      await BleEncounterService().start(userId: userId, isPremium: isPremium);
    } catch (_) {}
  }
  return true;
}

// ─── サービス本体（バックグラウンドで実行） ───────────────────────
@pragma('vm:entry-point')
void _onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // 通知プラグイン初期化（Android フォアグラウンドサービス通知更新用）
  final notifPlugin = FlutterLocalNotificationsPlugin();
  await notifPlugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    ),
  );

  // Supabase 初期化
  // Androidのバックグラウンドサービスは別isolateで動くため、この時点では
  // Supabase.instance に一度も触れておらず、`Supabase.instance` への
  // アクセス自体が LateInitializationError になる（初期化済みかどうかを
  // 判定しようとした行が先に例外を投げていた）。判定せず必ず初期化を試みる。
  try {
    await SupabaseConfig.ensureInitialized();
  } catch (e) {
    debugPrint('[BackgroundService] Supabase 初期化エラー: $e');
  }

  // SharedPrefs からユーザー情報を取得
  final prefs = await SharedPreferences.getInstance();
  final userId = prefs.getString(_kBgUserId);
  final isPremium = prefs.getBool(_kBgIsPremium) ?? false;

  if (userId == null) {
    service.stopSelf();
    return;
  }

  // 停止コマンドを受け付ける
  service.on('stop').listen((_) {
    BleEncounterService()
        .stop()
        .catchError((_) {})
        .whenComplete(service.stopSelf);
  });

  // BLE 検知開始
  try {
    await BleEncounterService().start(userId: userId, isPremium: isPremium);
  } catch (e) {
    debugPrint('[BackgroundService] BLE 開始エラー: $e');
  }

  // Android: フォアグラウンド通知を定期更新（サービスが生きていることを示す）
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((_) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((_) {
      service.setAsBackgroundService();
    });

    Timer.periodic(const Duration(minutes: 5), (_) async {
      if (await service.isForegroundService()) {
        service.setForegroundNotificationInfo(
          title: 'YAHE バックグラウンド検知中',
          content: 'すれ違いを監視しています 🚗',
        );
      }
    });
  }
}

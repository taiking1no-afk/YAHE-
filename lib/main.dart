import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'core/encounter/encounter_dedupe.dart';
import 'core/revenuecat/revenuecat_config.dart';
import 'core/supabase/supabase_config.dart';
import 'features/ads/ad_service.dart';
import 'features/ble/background_encounter_service.dart';
import 'features/notifications/notification_service.dart';
import 'firebase_options.dart';

const _kMotivationKey = 'motivation_notif_enabled';
const _kQuietKey = 'quiet_notif_enabled';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // ① Supabase初期化は runApp をブロックしない。以前はここで await していたため、
  // ネットワークが遅い端末では「ネイティブの起動画面が長く固まる」体感になっていた。
  // 初期化はここで開始だけしておき、実際に Supabase.instance を使う側
  // （AuthNotifier）が SupabaseConfig.ensureInitialized() を待つ構成にすることで、
  // runApp後すぐに自前のスプラッシュ画面（ローディング表示）に切り替わるようにする。
  unawaited(_initSupabase());
  unawaited(EncounterTestMode.load());

  // RevenueCat はネットワーク待ちが起きると起動が数秒遅れる原因になるため
  // runApp をブロックしない。RevenueCatConfig側の各メソッドが初期化完了を
  // 待ってから呼び出すようになっているので、先にログインされても安全。
  unawaited(_initRevenueCat());

  // ProviderContainer を作成して通知サービスと共有
  final container = ProviderContainer();
  NotificationService().setContainer(container);

  // 先に runApp してFlutterスプラッシュを表示
  runApp(
      UncontrolledProviderScope(container: container, child: const SurfApp()));

  // ② Firebase / BackgroundService は認証不要なので runApp 後に並列初期化
  await Future.wait([
    _initFirebase(),
    _initBackgroundService(),
  ]);

  // UI表示後にバックグラウンドで非クリティカルな初期化
  _initInBackground();
}

Future<void> _initSupabase() async {
  try {
    await SupabaseConfig.ensureInitialized().timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        debugPrint('Supabase 初期化タイムアウト → 未ログイン扱いで起動を継続');
      },
    );
  } catch (e) {
    debugPrint('Supabase 初期化エラー: $e');
  }
}

Future<void> _initFirebase() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint('Firebase 初期化エラー: $e');
  }
}

Future<void> _initRevenueCat() async {
  try {
    await RevenueCatConfig.initialize().timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        debugPrint('RevenueCat 初期化タイムアウト → スキップ');
      },
    );
  } catch (e) {
    debugPrint('RevenueCat 初期化エラー: $e');
  }
}

Future<void> _initBackgroundService() async {
  try {
    await BackgroundEncounterService.initialize();
  } catch (e) {
    debugPrint('BackgroundService 初期化エラー: $e');
  }
}

Future<void> _initInBackground() async {
  try {
    await initializeDateFormatting('ja_JP');
  } catch (e) {
    debugPrint('日付ロケール初期化エラー: $e');
  }

  try {
    await AdService().initialize();
  } catch (e) {
    debugPrint('AdMob 初期化エラー: $e');
  }

  try {
    await NotificationService().initialize();
    // 通知の許可/定期通知の開始はオンボーディングでユーザー同意した場合のみ行う。
    // ただし、すでに許可済みで「有効」になっているユーザーは次回起動時も再スケジュールする。
    final prefs = await SharedPreferences.getInstance();
    final motivationEnabled = prefs.getBool(_kMotivationKey) ?? false;
    final quietEnabled = prefs.getBool(_kQuietKey) ?? true;
    if (motivationEnabled) {
      await NotificationService().scheduleMotivationNotifications(
        quietEnabled: quietEnabled,
      );
    }
  } catch (e) {
    debugPrint('通知サービス初期化エラー: $e');
  }
}

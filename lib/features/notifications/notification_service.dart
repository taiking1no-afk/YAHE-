import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import '../../shared/providers/navigation_provider.dart';
import '../../shared/providers/tab_provider.dart';
import '../profile/data/user_repository.dart';

/// 通知ID定数
class _NotifId {
  static const int encounter = 1;
  static const int followWarning = 2; // 追尾（ストーカー）注意喚起
  static const int bluetoothOff = 3; // Bluetoothオフ警告
  static const int motivationBase = 1000; // 1000〜1099 をモチベーション通知用に確保
}

/// 通知チャンネル
class _Channel {
  static const encounter = AndroidNotificationChannel(
    'yahe_encounter',
    'すれ違い通知',
    description: 'YAHEユーザーとすれ違ったときの通知',
    importance: Importance.high,
    playSound: true,
  );

  static const motivation = AndroidNotificationChannel(
    'yahe_motivation',
    'おでかけ通知',
    description: 'ドライブに出かけたくなる定期通知',
    importance: Importance.defaultImportance,
    playSound: true,
  );

  static const like = AndroidNotificationChannel(
    'yahe_like',
    'いいね通知',
    description: 'いいねをもらったときの通知',
    importance: Importance.high,
    playSound: true,
  );
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  // Riverpod コンテナへの参照（通知タップ時にタブ切り替えに使用）
  ProviderContainer? _container;
  void setContainer(ProviderContainer container) => _container = container;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  // ---- 初期化 ------------------------------------------------
  Future<void> initialize() async {
    if (_initialized) return;

    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Tokyo'));

    // 許可のプロンプト自体は requestPermission() 側で明示的に行う。
    // ここで勝手に許可要求が出ないようにする。
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _plugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: _onTap,
    );

    // Android チャンネル登録
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(_Channel.encounter);
    await androidPlugin?.createNotificationChannel(_Channel.motivation);
    await androidPlugin?.createNotificationChannel(_Channel.like);

    // FCM フォアグラウンド設定
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // FCM バックグラウンドメッセージ処理
    FirebaseMessaging.onMessage.listen(_handleFcmMessage);

    _initialized = true;
    debugPrint('[NotificationService] initialized');
  }

  // ---- 権限リクエスト ----------------------------------------
  Future<bool> requestPermission() async {
    // iOS
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    final granted = settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;

    // Android 13+
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    return granted;
  }

  // ---- FCM トークン取得 ------------------------------------
  Future<String?> getFcmToken() async {
    return FirebaseMessaging.instance.getToken();
  }

  // ---- FCM トークンを Supabase に保存 ----------------------
  Future<void> saveFcmTokenToSupabase(String userId) async {
    try {
      final token = await getFcmToken();
      if (token == null) return;
      await UserRepository().saveFcmToken(userId, token);

      // トークン更新時も再保存
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        try {
          await UserRepository().saveFcmToken(userId, newToken);
        } catch (_) {}
      });

      debugPrint('[NotificationService] FCM token saved');
    } catch (e) {
      debugPrint('[NotificationService] FCM token save error: $e');
    }
  }

  // ---- ① すれ違い通知 ------------------------------------
  /// BLE 検知時に呼び出す
  Future<void> showEncounterNotification({required String timeStr}) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'yahe_encounter',
        'すれ違い通知',
        channelDescription: 'YAHEユーザーとすれ違ったときの通知',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        playSound: true,
        enableVibration: true,
        styleInformation: BigTextStyleInformation(''),
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'default',
      ),
    );

    await _plugin.show(
      _NotifId.encounter,
      '⚡ YAHEしたよ！',
      'どんな人か確認してみよう 👀',
      details,
      payload: 'encounter', // タップ時のナビゲーション用
    );
  }

  // ---- ①' 追尾（ストーカー）警告通知 ----------------------
  /// 同一ユーザーと短時間に何度もすれ違ったときに注意喚起する
  Future<void> showFollowWarningNotification() async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'yahe_encounter',
        'すれ違い通知',
        channelDescription: '安全に関する注意喚起',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        playSound: true,
        enableVibration: true,
        styleInformation: BigTextStyleInformation(''),
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'default',
      ),
    );

    await _plugin.show(
      _NotifId.followWarning,
      '⚠️ 同じ相手と頻繁にすれ違っています',
      '不審に感じたら、相手をブロックできます。設定 → ブロックリストから確認を。',
      details,
      payload: 'follow_warning',
    );
  }

  // ---- ①'' Bluetoothオフ警告通知 --------------------------
  /// すれ違い検知中にBluetoothがオフになったときに注意喚起する
  Future<void> showBluetoothOffNotification() async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'yahe_encounter',
        'すれ違い通知',
        channelDescription: 'Bluetoothがオフになった際の警告',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        playSound: true,
        enableVibration: true,
        styleInformation: BigTextStyleInformation(''),
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'default',
      ),
    );

    await _plugin.show(
      _NotifId.bluetoothOff,
      '📴 Bluetoothがオフになっています',
      'このままだとすれ違いを検知できません。設定からオンにしてください。',
      details,
      payload: 'bluetooth_off',
    );
  }

  // ---- ② モチベーション定期通知 ---------------------------
  /// アプリ起動時・設定変更時に呼び出して全スケジュールを再登録
  Future<void> scheduleMotivationNotifications({
    bool quietEnabled = true,
    int quietStartHour = 23,
    int quietEndHour = 6,
  }) async {
    // 既存のモチベーション通知をすべてキャンセル
    for (int i = 0; i < 100; i++) {
      await _plugin.cancel(_NotifId.motivationBase + i);
    }

    final messages = _motivationMessages;
    int idOffset = 0;

    // 今後7日分のスケジュールを登録
    final now = tz.TZDateTime.now(tz.local);
    for (int dayOffset = 0; dayOffset < 7; dayOffset++) {
      for (final slot in _timeSlots) {
        final scheduledTime = tz.TZDateTime(
          tz.local,
          now.year,
          now.month,
          now.day + dayOffset,
          slot.hour,
          slot.minute,
        );

        // 過去 or 深夜帯はスキップ
        if (scheduledTime.isBefore(now)) continue;
        if (quietEnabled && _isQuietHour(scheduledTime.hour, quietStartHour, quietEndHour)) continue;

        final msg = messages[(dayOffset * _timeSlots.length + idOffset) % messages.length];

        await _plugin.zonedSchedule(
          _NotifId.motivationBase + idOffset,
          msg.title,
          msg.body,
          scheduledTime,
          NotificationDetails(
            android: AndroidNotificationDetails(
              'yahe_motivation',
              'おでかけ通知',
              importance: Importance.defaultImportance,
              icon: '@mipmap/ic_launcher',
              styleInformation: BigTextStyleInformation(msg.body),
            ),
            iOS: const DarwinNotificationDetails(
              presentAlert: true,
              presentSound: true,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );

        idOffset++;
        if (idOffset >= 100) return;
      }
    }

    debugPrint('[NotificationService] scheduled $idOffset motivation notifications');
  }

  Future<void> cancelAllMotivationNotifications() async {
    for (int i = 0; i < 100; i++) {
      await _plugin.cancel(_NotifId.motivationBase + i);
    }
  }

  // ---- FCM メッセージ処理 ---------------------------------
  void _handleFcmMessage(RemoteMessage message) {
    final notification = message.notification;
    if (notification == null) return;

    // type に応じて通知チャンネル・タップ時payloadを切り替える
    // （送信元は send-encounter-notification / send-like-notification）
    final type = message.data['type'] ?? 'encounter';
    final (channelId, channelName) = switch (type) {
      'like' => ('yahe_like', 'いいね通知'),
      _ => ('yahe_encounter', 'すれ違い通知'),
    };

    _plugin.show(
      message.hashCode,
      notification.title ?? 'YAHE',
      notification.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: const DarwinNotificationDetails(presentAlert: true, presentSound: true),
      ),
      payload: type,
    );
  }

  void _onTap(NotificationResponse response) {
    debugPrint('[NotificationService] tapped: ${response.payload}');
    final container = _container;
    if (container == null) return;

    final payload = response.payload ?? '';
    // payload に応じてタブを切り替える
    if (payload.contains('match')) {
      container.read(selectedTabProvider.notifier).state = 2; // マッチタブ
    } else if (payload.contains('like')) {
      container.read(selectedTabProvider.notifier).state = 1; // いいねタブ
    } else {
      container.read(selectedTabProvider.notifier).state = 0; // YAHEタブ
    }
    container.read(pendingNavProvider.notifier).state = PendingNav.none;
  }

  // ---- ヘルパー -------------------------------------------
  bool _isQuietHour(int hour, int start, int end) {
    if (start > end) {
      // 例: 23〜6 (日をまたぐ)
      return hour >= start || hour < end;
    }
    return hour >= start && hour < end;
  }

  // 通知を送る時間帯スロット
  static const _timeSlots = [
    _TimeSlot(7, 30),   // 朝の出発時間
    _TimeSlot(10, 0),   // 午前ドライブタイム
    _TimeSlot(14, 0),   // 昼過ぎドライブ
    _TimeSlot(18, 30),  // 仕事帰りドライブ
  ];

  // モチベーションメッセージ一覧
  static const _motivationMessages = [
    _NotifMessage('🚗 今日も走りに行こう！', 'YAHEユーザーが近くにいるかも。タイムラインをチェック！'),
    _NotifMessage('☀️ 天気がいいですね！', 'ドライブ日和です。愛車で出かけてみませんか？'),
    _NotifMessage('⚡ すれ違いのチャンス！', '今この瞬間も、近くを同じ趣味の人が走っているかも。'),
    _NotifMessage('🏁 週末ドライブはいかが？', 'YAHEで新しい仲間を見つけよう。愛車で走り出そう！'),
    _NotifMessage('🌙 夜ドライブの季節！', '夜景を見ながらクルーズ。仲間に出会えるかも。'),
    _NotifMessage('🔥 今日もYAHEしよう！', 'アプリを起動したまま走ると、すれ違いが記録されます。'),
    _NotifMessage('🛣️ 峠？海沿い？どっちに行く？', 'どこへ行っても、YAHEがあなたの出会いを記録します。'),
    _NotifMessage('💨 走りたい気分では？', '出発前にアプリを起動。あとは自動で記録します（運転中は操作しないで）。'),
    _NotifMessage('🎯 近くに気になる車がいるかも', '今日のすれ違いをチェック！いいねを送ってみよう。'),
    _NotifMessage('🌅 朝ドライブのススメ', '早朝は道も空いてます。気持ちいい走りに出かけよう！'),
  ];
}

class _TimeSlot {
  final int hour;
  final int minute;
  const _TimeSlot(this.hour, this.minute);
}

class _NotifMessage {
  final String title;
  final String body;
  const _NotifMessage(this.title, this.body);
}

// FCM バックグラウンドハンドラー（トップレベル関数として定義必須）
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('[FCM Background] ${message.notification?.title}');
}

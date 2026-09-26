import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/supabase/supabase_config.dart';
import '../../core/encounter/encounter_dedupe.dart';
import '../home/data/encounter_repository.dart';
import '../notifications/notification_service.dart';
import '../settings/data/privacy_zone_repository.dart';
import 'ble_peripheral_channel.dart';

/// すれ違い検知サービス
/// GPS + BLE を組み合わせて周辺ユーザーを検知する
///
/// BLE動作:
///   フォアグラウンド: ローカル名 "SURF:<userId>" + サービスUUID FFF0 をアドバタイズ
///   バックグラウンド: iOSはローカル名を省略するため、GATT接続で FFF1 特性からuserIdを読み取る
class BleEncounterService {
  static final BleEncounterService _instance = BleEncounterService._internal();
  factory BleEncounterService() => _instance;
  BleEncounterService._internal();

  final _encounterRepository = EncounterRepository();
  final _privacyZoneRepository = PrivacyZoneRepository();

  StreamSubscription? _scanSubscription;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _isScanningSubscription;
  StreamSubscription? _adapterStateSubscription;
  Timer? _stationaryUploadTimer;
  Position? _currentPosition;
  bool _isRunning = false;

  String? _currentUserId;
  bool _isPremium = false;

  // ── 実機での目視デバッグ用ステータス（DebugScreen から参照） ──
  bool get isRunning => _isRunning;
  String? lastAdvertiseError;
  int scanResultCount = 0;
  String? lastScanDeviceId;
  String? lastScanInfo;
  String? lastMatchedUserId;
  DateTime? lastScanResultAt;

  static const String _blePrefix = 'SURF:';
  static final Guid _surfServiceUuid =
      Guid('0000FFF0-0000-1000-8000-00805F9B34FB');
  static final Guid _surfCharUuid =
      Guid('0000FFF1-0000-1000-8000-00805F9B34FB');
  // Android MSD カンパニー ID（BlePeripheralPlugin.kt の SURF_COMPANY_ID と一致させること）
  static const int _msdCompanyId = 0x5946;

  // デバイスID -> 最後に処理した時刻（BLE重複防止）
  final Map<String, DateTime> _recentlyProcessed = {};
  // userId -> 最後にすれ違い登録した時刻（BLE/GPS横断の重複防止）
  final Map<String, DateTime> _recentlyEncountered = {};

  Duration get _userDedupeWindow => EncounterTestMode.userDedupeWindow;

  // ── 追尾（ストーカー）検知 ─────────────────────────────────
  // 同一ユーザーと短時間に何度もすれ違う＝尾行の可能性。回数を数えて
  // 閾値を超えたらユーザーへ注意喚起し、以後その相手の通知は抑制する。
  final Map<String, List<DateTime>> _encounterHistory = {};
  final Map<String, DateTime> _followWarned = {};
  static const _followWindow = Duration(minutes: 30); // この時間内の回数を数える
  static const _followThreshold = 4; // 30分に4回以上で「追尾の疑い」
  static const _followWarnCooldown = Duration(hours: 1); // 警告は最大1時間に1回

  // GPS近傍チェック用（1秒スロットリング）
  DateTime? _lastGpsProximityCheck;

  // ── BLE GATT同時接続数の制限 ─────────────────────────────
  // 密集した集会では周辺デバイスが一斉にGATTフォールバックへ入り得るが、
  // OS側のBLEスタックは同時接続数に上限があるため、無制限に張ると
  // 接続エラーの連鎖やBluetoothスタック自体の不安定化を招く。
  int _activeGattConnections = 0;
  static const int _maxConcurrentGattConnections = 2;

  // ── すれ違い登録・Push通知のバッチ化 ─────────────────────────
  // 集会などで短時間に多数のユーザーを検知すると、1件ずつRPC/Push関数を
  // 呼ぶと同時多発でサーバー負荷が跳ね上がる。検知結果を一旦キューに溜め、
  // 短い時間窓でまとめて1回のバッチ呼び出しに集約する。
  final Set<String> _pendingEncounterUserIds = {};
  Timer? _batchFlushTimer;
  static const Duration _batchFlushDelay = Duration(milliseconds: 800);

  // ── 盗難対策：愛車ガード（自宅・職場）内では発信・検知・位置送信を止める ──
  // ミーティング会場などでの駐車中は検知させ、自宅・保管場所だけを守る。
  // （駐車中を一律で止めると、停めている車同士が繋がらず本来の機能が死ぬため）
  // 判定できるまでは「ゾーン内（安全側）」を初期値にする。GPS未取得・
  // オフライン等で判定できない間に false（＝発信OK）扱いになってしまうと、
  // 電波の弱いガレージ等でこそ愛車ガードが効かないという本末転倒が起きるため。
  bool _inZone = true;
  DateTime? _lastZoneCheck;
  static const Duration _zoneCheckInterval = Duration(seconds: 3);

  // UI（ホーム画面）から「今すれ違い検知が愛車ガードで止まっているか」を
  // 直接確認できるようにするための公開通知。原因切り分けが困難だった
  // （検知が起きない理由がユーザーからもサポートからも見えなかった）ため追加。
  final ValueNotifier<bool> inZoneNotifier = ValueNotifier(false);
  void _setInZone(bool value) {
    _inZone = value;
    inZoneNotifier.value = value;
  }

  // Bluetoothがオフになった時の警告通知（オンに戻るまで連発しないようにする）
  bool _bluetoothOffNotified = false;

  // start()/stop() が未awaitのまま連続で呼ばれる（例:
  // ログアウト直後に別アカウントで即ログインする）と、後から呼ばれたはずの
  // stop() の完了が start() の完了より後になり、「_isRunning=false で
  // 購読は全部キャンセル済みなのに次のstart()は早期returnで何もしない」
  // という死んだ状態に陥ることがあった。start/stopを直列化し、常に
  // 呼ばれた順に完了させることでこの競合を防ぐ。
  Future<void>? _pendingTransition;

  Future<bool> start({
    required String userId,
    required bool isPremium,
  }) async {
    final prev = _pendingTransition;
    final completer = Completer<void>();
    _pendingTransition = completer.future;
    try {
      if (prev != null) await prev;
      return await _startInternal(userId: userId, isPremium: isPremium);
    } finally {
      completer.complete();
    }
  }

  Future<void> stop() async {
    final prev = _pendingTransition;
    final completer = Completer<void>();
    _pendingTransition = completer.future;
    try {
      if (prev != null) await prev;
      await _stopInternal();
    } finally {
      completer.complete();
    }
  }

  Future<bool> _startInternal({
    required String userId,
    required bool isPremium,
  }) async {
    if (_isRunning) return true;
    _currentUserId = userId;
    _isPremium = isPremium;

    final permitted = await _requestPermissions();
    if (!permitted) {
      debugPrint('[BLE] 権限拒否のため開始しません userId=$userId');
      _isRunning = false;
      return false;
    }

    // _startBleScan() が adapterState の変化リスナーを登録する前に true にしておく。
    // これより後（下のコメント参照）に立てていると、コールドスタート時に
    // CBCentralManager が unknown→poweredOn へ切り替わるタイミングと競合し、
    // 「_isRunning=false のうちに on イベントが来て再スキャンが呼ばれない」
    // ことがあり、その端末のスキャンが二度と始まらないまま(＝相手を検知できない
    // まま)になってしまっていた。実機ログで _isRunning=false のまま on に
    // なっているケースを確認済み。
    _isRunning = true;

    // 愛車ガード対策: 起動直後はGPSのライブ更新（数秒〜屋内では数十秒かかることがある）
    // が届くまで _inZone が初期値 false のままになり、その間だけ発信・検知が
    // 素通りしてしまっていた（自宅ガレージ等、GPS感度が最も弱い場所ほど起きやすい）。
    // 端末にキャッシュされた最終位置（getLastKnownPosition、即時取得）で
    // ライブ更新を待たずに先に判定しておくことで、この起動直後の抜け穴を塞ぐ。
    await _seedZoneStateFromLastKnownPosition();

    _startGpsTracking();
    _startBleScan();

    // ゾーン内と分かっている場合は発信自体を開始しない（保管場所を漏らさない）
    if (_inZone) {
      debugPrint('[BLE-DEBUG] 起動時点で愛車ガード範囲内のため発信を開始しません userId=$userId');
    } else {
      // 広告はメインエンジン上でのみ動作（背景サービスのisolateでは MethodChannel 未登録のため無視）
      // iOS: CBPeripheralManager / Android: BluetoothLeAdvertiser — 両プラットフォームで実装済み
      try {
        await BlePeripheralChannel.startAdvertising(userId);
        lastAdvertiseError = null;
        debugPrint('[BLE-DEBUG] startAdvertising 呼び出し成功 userId=$userId');
      } catch (e) {
        lastAdvertiseError = e.toString();
        debugPrint('[BLE-DEBUG] startAdvertising 失敗: $e');
      }
    }

    debugPrint('[BLE-DEBUG] BleEncounterService.start 完了 userId=$userId');
    return true;
  }

  Future<void> _seedZoneStateFromLastKnownPosition() async {
    try {
      final pos = await Geolocator.getLastKnownPosition();
      // 取得できない場合は _inZone の安全側デフォルト(true)のままにしておく。
      if (pos == null) return;
      _currentPosition = pos;
      // ここで _lastZoneCheck を進めない: 進めてしまうと、直後に届く最初の
      // ライブGPS位置（キャッシュ位置より新しく、実際にゾーン内かもしれない）が
      // _zoneCheckInterval 未満だからと判定をスキップして素通りしてしまう
      // （帰宅直後にアプリを開いた場合など）。最初のライブ更新は必ず判定させる。
      await _updateZoneState(pos);
    } catch (_) {
      // 取得できなくても致命的ではない（_inZone は安全側デフォルトのまま、
      // 直後のライブGPS更新で通常通り判定される）
    }
  }

  Future<void> _stopInternal() async {
    _scanSubscription?.cancel();
    _positionSubscription?.cancel();
    _stationaryUploadTimer?.cancel();
    _stationaryUploadTimer = null;
    _isScanningSubscription?.cancel();
    _isScanningSubscription = null;
    _adapterStateSubscription?.cancel();
    _adapterStateSubscription = null;
    // GPS位置情報をサーバーから削除（プライバシー保護）
    final userId = _currentUserId;
    if (userId != null) {
      SupabaseConfig.client
          .from('user_locations')
          .delete()
          .eq('user_id', userId)
          .then((_) {})
          .catchError((_) {});
    }
    try {
      await BlePeripheralChannel.stopAdvertising();
    } catch (_) {}
    _isRunning = false;
    _setInZone(true);
    _lastZoneCheck = null;
    _bluetoothOffNotified = false;
    _encounterHistory.clear();
    _followWarned.clear();
    _batchFlushTimer?.cancel();
    _batchFlushTimer = null;
    _pendingEncounterUserIds.clear();
    // アカウント切替時に前ユーザーの重複防止キャッシュ等を引き継がないよう、
    // ユーザー固有の状態も合わせてクリアする。
    _currentUserId = null;
    _isPremium = false;
    _currentPosition = null;
    _recentlyProcessed.clear();
    _recentlyEncountered.clear();
    _lastGpsProximityCheck = null;
  }

  Future<bool> _requestPermissions() async {
    final loc = await Geolocator.requestPermission();
    if (loc == LocationPermission.denied ||
        loc == LocationPermission.deniedForever) {
      return false;
    }
    // Android 12+: BLUETOOTH_SCAN / ADVERTISE / CONNECT は実行時にも要求が必要
    // CONNECT が無いと GATT サーバー起動（openGattServer）が SecurityException で失敗し、
    // ネイティブ側の startAdvertising 全体が中断してアドバタイズ自体が始まらなくなる
    if (defaultTargetPlatform == TargetPlatform.android) {
      final advertise = await Permission.bluetoothAdvertise.request();
      final scan = await Permission.bluetoothScan.request();
      final connect = await Permission.bluetoothConnect.request();
      if (!advertise.isGranted || !scan.isGranted || !connect.isGranted) {
        return false;
      }
    }
    return true;
  }

  void _startGpsTracking() {
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(_handlePositionUpdate);

    // distanceFilter: 5 のため、停車中・屋内で立ち止まってのテストでは
    // 5m動かない限り位置情報が一切更新されない。その間 user_locations.updated_at
    // が古くなり、nearby_user_ids の p_max_age_seconds（10秒）フィルタに
    // 引っかかって GPS フォールバックが機能しなくなっていた
    // （実機テストで「iPhone同士がイマイチ検知しない」の主因の一つ）。
    // 動きが無くても直近の位置を定期的に再送信し、鮮度を保つ。
    //
    // 以前は !_inZone のときだけ呼んでいたが、そうすると一度 _inZone が
    // true になった後は端末が5m以上動かない限り愛車ガードの状態が
    // 二度と再評価されなかった（設定画面でガードをOFFにしても、
    // 静止したままだと反映されずすれ違いが検知されないままになる不具合）。
    // _handlePositionUpdate 側で愛車ガード判定のスロットル
    // （_zoneCheckInterval）を持っているため、ここは _inZone に関わらず
    // 常に呼んでよい。
    _stationaryUploadTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      final pos = _currentPosition;
      if (pos != null) _handlePositionUpdate(pos);
    });
  }

  Future<void> _handlePositionUpdate(Position pos) async {
    _currentPosition = pos;
    final now = DateTime.now();

    // 愛車ガード（自宅・職場）内かを定期的に判定し、発信・位置送信を制御。
    // ゾーン内では一切発信・記録せず、保管場所が他ユーザーに知られないようにする。
    if (_lastZoneCheck == null ||
        now.difference(_lastZoneCheck!) >= _zoneCheckInterval) {
      _lastZoneCheck = now;
      await _updateZoneState(pos);
    }
    if (_inZone) return; // 自宅・職場周辺は何も送信・記録しない

    _uploadLocation(pos);
    // GPS近傍チェックは最大1秒に1回（高頻度GPS更新でもSupabaseを過負荷にしない）
    if (_lastGpsProximityCheck == null ||
        now.difference(_lastGpsProximityCheck!) >= const Duration(seconds: 1)) {
      _lastGpsProximityCheck = now;
      _checkGpsProximity(pos);
    }
  }

  // すれ違いを記録し、短時間に閾値以上なら「追尾の疑い」と判定
  bool _recordAndCheckFollowing(String otherUserId) {
    final now = DateTime.now();
    final hist = _encounterHistory.putIfAbsent(otherUserId, () => []);
    hist.add(now);
    hist.removeWhere((t) => now.difference(t) > _followWindow);
    _encounterHistory.removeWhere((_, list) => list.isEmpty);
    return hist.length >= _followThreshold;
  }

  // 追尾の疑いがあるとき、クールダウンを守って一度だけ注意喚起する
  void _maybeWarnFollowing(String otherUserId) {
    final now = DateTime.now();
    final last = _followWarned[otherUserId];
    if (last != null && now.difference(last) < _followWarnCooldown) return;
    _followWarned[otherUserId] = now;
    NotificationService().showFollowWarningNotification();
  }

  // 検知した相手をバッチキューに積み、一定時間内の検知をまとめて1回で送信する
  void _queueEncounter(String otherUserId) {
    _pendingEncounterUserIds.add(otherUserId);
    _batchFlushTimer ??= Timer(_batchFlushDelay, _flushPendingEncounters);
  }

  Future<void> _flushPendingEncounters() async {
    _batchFlushTimer = null;
    if (_pendingEncounterUserIds.isEmpty) return;
    final userId = _currentUserId;
    if (userId == null) {
      _pendingEncounterUserIds.clear();
      return;
    }
    final otherUserIds = _pendingEncounterUserIds.toList();
    _pendingEncounterUserIds.clear();

    try {
      // ブロック済み・愛車未登録・重複防止期間内などの理由で実際には
      // 登録されなかった相手は、例外を投げずに戻り値から単に除外される。
      // 以前はRPCが例外を投げなければ全員に通知を送っていたため、
      // 実際にはDBに何も記録されていないのに「すれ違い通知」だけが届き
      // 一覧には出てこない、という不整合が起きていた。
      final registeredIds = await _encounterRepository.registerEncounters(
        userAId: userId,
        otherUserIds: otherUserIds,
        aIsPremium: _isPremium,
      );
      // ローカル重複防止(APIの呼び過ぎ防止)は試行した相手全員に適用する。
      final now = DateTime.now();
      for (final id in otherUserIds) {
        _recentlyEncountered[id] = now;
      }
      _recentlyEncountered.removeWhere(
        (_, t) => DateTime.now().difference(t) > _userDedupeWindow * 2,
      );
      if (registeredIds.isNotEmpty) {
        _sendPushToOtherUsers(userId, registeredIds);
      }
    } catch (_) {
      // 失敗分をキューに戻して再送を試みる
      _pendingEncounterUserIds.addAll(otherUserIds);
      _batchFlushTimer ??= Timer(_batchFlushDelay, _flushPendingEncounters);
    }
  }

  // 現在地が愛車ガード（プライバシーゾーン）内かを判定し、
  // 状態が変わったタイミングで発信のON/OFFと位置情報の掃除を行う。
  Future<void> _updateZoneState(Position pos) async {
    final userId = _currentUserId;
    if (userId == null) return;

    bool inZone;
    try {
      inZone = await _privacyZoneRepository.isInPrivacyZone(
        userId: userId,
        lat: pos.latitude,
        lng: pos.longitude,
      );
    } catch (_) {
      return; // 判定に失敗したら状態は変えない
    }

    if (inZone == _inZone) return;
    _setInZone(inZone);
    if (inZone) {
      // ゾーン内：BLE発信を止め、サーバー上の現在地も消す（保管場所を残さない）
      try {
        BlePeripheralChannel.stopAdvertising();
      } catch (_) {}
      SupabaseConfig.client
          .from('user_locations')
          .delete()
          .eq('user_id', userId)
          .then((_) {})
          .catchError((_) {});
    } else {
      // ゾーン外：発信を再開
      try {
        BlePeripheralChannel.startAdvertising(userId);
      } catch (_) {}
    }
  }

  // 自分の現在地を Supabase にアップサート
  void _uploadLocation(Position pos) {
    final userId = _currentUserId;
    if (userId == null) return;
    SupabaseConfig.client
        .from('user_locations')
        .upsert({
          'user_id': userId,
          'lat': pos.latitude,
          'lng': pos.longitude,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .then((_) {})
        .catchError((_) {});
  }

  // 他ユーザーを GPS で検索してすれ違い登録（BLEが届かなかった場合の保険）。
  // 半径は速度で切り替える:
  //   通常時(50m): 200mだと「実際にはすれ違っていない別の建物の人」まで
  //                拾ってしまうため、「本当に近くを通った」と言える距離に絞る。
  //   高速移動時(200m): 走行中（時速60km以上）はBLEの到達距離内にいる時間が
  //                短すぎて検知し損ねやすく、車のボディでの遮蔽も重なるため、
  //                半径を広げて確実に拾う。高速で動いている＝実際に道路上で
  //                すれ違った可能性が高く、200mでも近所の別居人と誤認する
  //                リスクは低い。
  //
  // セキュリティ: 他ユーザーの生座標はクライアントに取得しない。
  // 自分の現在地のみをサーバー側RPC(nearby_user_ids)に渡し、
  // 半径内の user_id のみを受け取る（距離計算はサーバーで完結）。
  static const _gpsProximityRadiusM = 50;
  static const _highSpeedRadiusM = 200;
  static const _highSpeedThresholdKmh = 60;

  Future<void> _checkGpsProximity(Position pos) async {
    final userId = _currentUserId;
    if (userId == null) return;

    final speedKmh = pos.speed * 3.6;
    final radiusM = speedKmh >= _highSpeedThresholdKmh
        ? _highSpeedRadiusM
        : _gpsProximityRadiusM;

    try {
      final rows = await SupabaseConfig.client.rpc(
        'nearby_user_ids',
        params: {
          'p_lat': pos.latitude,
          'p_lng': pos.longitude,
          'p_radius_m': radiusM,
          // 8秒おきの定期再送信(_stationaryUploadTimer)に余裕を持たせる
          'p_max_age_seconds': 20,
        },
      ) as List;
      if (rows.isEmpty) return;

      // プライバシーゾーン判定（自分の現在地が自分のゾーン内なら記録しない）。
      // 判定は otherUserId に依存しない（自分の位置だけで決まる）ため、
      // 近くにいる人数分だけ同じ結果を問い合わせるのは無駄。ループの外で1回だけ行う。
      final isInZone = await _privacyZoneRepository.isInPrivacyZone(
        userId: userId,
        lat: pos.latitude,
        lng: pos.longitude,
      );
      if (isInZone) return;

      for (final row in rows) {
        final otherUserId = row['user_id'] as String;
        if (otherUserId == userId) continue;

        // BLE/GPS 横断の重複防止（本番: 同一相手1日1回 / テスト: 5分）
        // DB 成功済み or 送信待ちキュー中はスキップ（成功前に確定しない）
        final lastSeen = _recentlyEncountered[otherUserId];
        if (lastSeen != null &&
            DateTime.now().difference(lastSeen) < _userDedupeWindow) continue;
        if (_pendingEncounterUserIds.contains(otherUserId)) continue;

        // 追尾の疑いがあれば注意喚起し、その相手の通常通知・登録は抑制
        if (_recordAndCheckFollowing(otherUserId)) {
          _maybeWarnFollowing(otherUserId);
          continue;
        }

        final timeStr = DateFormat('HH:mm').format(DateTime.now());
        await NotificationService().showEncounterNotification(timeStr: timeStr);
        _queueEncounter(otherUserId);
      }
    } catch (_) {}
  }

  void _startBleScan() {
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        _processScanResult(result);
      }
    });

    _doStartScan();

    // スキャンが停止したら即座に再開（タイマーポーリングを廃止してギャップゼロ化）
    _isScanningSubscription = FlutterBluePlus.isScanning.listen((isScanning) {
      if (!isScanning && _isRunning) {
        Future.delayed(const Duration(milliseconds: 200), () {
          if (_isRunning && !FlutterBluePlus.isScanningNow) {
            _doStartScan();
          }
        });
      }
    });

    // Bluetooth が OFF→ON に切り替わったタイミングでスキャンを再開する。
    // OFF の間は _isScanningSubscription 側の再試行ループが空振りし続けるだけなので、
    // ここで確実に拾う（_doStartScan 自体は OFF 中は何もしないようガードしてある）。
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      debugPrint(
          '[BLE-DEBUG] adapterState変化: $state (_isRunning=$_isRunning _bluetoothOffNotified=$_bluetoothOffNotified)');
      if (state == BluetoothAdapterState.on) {
        _bluetoothOffNotified = false;
        if (_isRunning) _doStartScan();
      } else if (state == BluetoothAdapterState.off &&
          _isRunning &&
          !_bluetoothOffNotified) {
        // オンに戻るまで連続で通知しない
        _bluetoothOffNotified = true;
        debugPrint('[BLE-DEBUG] Bluetoothオフ通知を送信します');
        NotificationService().showBluetoothOffNotification().then((_) {
          debugPrint('[BLE-DEBUG] Bluetoothオフ通知の送信完了');
        }).catchError((e) {
          debugPrint('[BLE-DEBUG] Bluetoothオフ通知の送信エラー: $e');
        });
      }
    });
  }

  void _doStartScan() {
    // OFF の間に startScan を呼ぶと例外（bluetooth must be turned on）が飛び、
    // 再試行ループと組み合わさって呼び出しが連発することがあるため事前にガードする。
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      debugPrint(
          '[BLE-DEBUG] Bluetoothがオフのためスキャン開始をスキップ (state=${FlutterBluePlus.adapterStateNow})');
      return;
    }
    debugPrint('[BLE-DEBUG] スキャン開始 (service=$_surfServiceUuid)');
    FlutterBluePlus.startScan(
      withServices: [_surfServiceUuid],
      androidScanMode: AndroidScanMode.lowLatency,
      // continuousUpdates: false（既定）だと、同一デバイスからの2回目以降の広告を
      // OSレベルで黙って無視してしまう（特にiOSのCoreBluetoothは重複排除がデフォルト）。
      // これが原因で「一度検知した後、次の検知がスキャン再起動のタイミング任せになり
      // 数分〜十数分と不規則に遅れる」問題が起きていた。true にして毎回の広告を確実に
      // 受け取り、再検知の間隔をアプリ側の重複防止ロジック（5分/1日）だけに委ねる。
      continuousUpdates: true,
    ).catchError((e) {
      debugPrint('[BLE-DEBUG] スキャン開始失敗: $e');
    });
  }

  Future<void> _processScanResult(ScanResult result) async {
    final userId = _currentUserId;
    if (userId == null) return;

    debugPrint('[BLE-DEBUG] スキャン結果受信 device=${result.device.remoteId.str} '
        'name=${result.advertisementData.advName} '
        'services=${result.advertisementData.serviceUuids} '
        'msdKeys=${result.advertisementData.manufacturerData.keys}');

    final deviceId = result.device.remoteId.str;

    // 実機での目視デバッグ用（マッチ成否に関わらず、電波を受信した事実は必ず記録する）
    scanResultCount++;
    lastScanDeviceId = deviceId;
    lastScanInfo = 'name=${result.advertisementData.advName} '
        'services=${result.advertisementData.serviceUuids.length}件 '
        'msd=${result.advertisementData.manufacturerData.keys}';
    lastScanResultAt = DateTime.now();

    // 愛車ガード内では記録しない（盗難・追尾対策）
    if (_inZone) {
      debugPrint('[BLE-DEBUG] 愛車ガード範囲内のためスキップ');
      return;
    }

    // 同一デバイスを短時間内に重複処理しない（BLEパケット連打防止）
    final lastSeen = _recentlyProcessed[deviceId];
    if (lastSeen != null &&
        DateTime.now().difference(lastSeen) < EncounterDedupe.bleDeviceWindow) {
      return;
    }

    // ① ローカル名から取得（フォアグラウンド時）
    String? otherUserId;
    final advName = result.advertisementData.advName;
    if (advName.startsWith(_blePrefix)) {
      otherUserId = advName.substring(_blePrefix.length);
    }

    // ② サービス UUID から取得（バックグラウンド高速検知 — 接続不要・即時）
    //    広告パケット: FFF0（SURFマーカー） + userId そのものを UUID として格納
    if (otherUserId == null) {
      for (final uuid in result.advertisementData.serviceUuids) {
        final str = uuid.toString().toLowerCase();
        // FFF0 マーカー以外の UUID が userId
        if (str != '0000fff0-0000-1000-8000-00805f9b34fb' &&
            _looksLikeUuid(str)) {
          otherUserId = str;
          break;
        }
      }
    }

    // ②' MSD から取得（iOS バックグラウンドでの Android 検知用 — 接続不要・即時）
    //    iOS バックグラウンドスキャンは serviceUuids を FFF0 のみに制限するが
    //    manufacturerData は常に全データを返すため、MSD 経由で userId を確実に届ける
    if (otherUserId == null) {
      final msdBytes = result.advertisementData.manufacturerData[_msdCompanyId];
      if (msdBytes != null && msdBytes.length == 16) {
        otherUserId = _uuidFromBytes(msdBytes);
      }
    }

    // ③ フォールバック：サービスデータから取得（旧実装との互換）
    if (otherUserId == null) {
      final advData = result.advertisementData.serviceData;
      for (final data in advData.values) {
        try {
          final decoded = utf8.decode(data);
          if (decoded.startsWith(_blePrefix)) {
            otherUserId = decoded.substring(_blePrefix.length);
            break;
          }
        } catch (_) {}
      }
    }

    // ④ 最終フォールバック：GATT接続して FFF1 特性を読み取る
    //    （どうしても他の方法で取れなかった場合のみ。低速時のみ有効）
    //    同時接続数が上限に達している場合は今回はスキップし、次のスキャンで再試行する
    //    （processedとしてマークしないため、空きが出れば自然にリトライされる）
    if (otherUserId == null &&
        _activeGattConnections < _maxConcurrentGattConnections) {
      otherUserId = await _readUserIdViaGatt(result.device);
    }

    debugPrint(
        '[BLE-DEBUG] userId抽出結果: device=$deviceId otherUserId=$otherUserId');

    if (otherUserId == null || otherUserId.isEmpty || otherUserId == userId)
      return;

    lastMatchedUserId = otherUserId;

    // 処理済みとしてマーク
    _recentlyProcessed[deviceId] = DateTime.now();
    // 古いエントリを定期クリーンアップ
    _recentlyProcessed.removeWhere(
      (_, t) =>
          DateTime.now().difference(t) > EncounterDedupe.bleDeviceWindow * 2,
    );

    // 同一ユーザーとのすれ違い重複防止（本番: 1日1回 / テスト: 5分）
    // DB 成功後にのみ _recentlyEncountered へ書く（成功前確定によるロスト防止）
    final lastEncounter = _recentlyEncountered[otherUserId];
    if (lastEncounter != null &&
        DateTime.now().difference(lastEncounter) < _userDedupeWindow) {
      return;
    }
    if (_pendingEncounterUserIds.contains(otherUserId)) return;

    // プライバシーゾーン判定
    final pos = _currentPosition;
    if (pos != null) {
      final isInZone = await _privacyZoneRepository.isInPrivacyZone(
        userId: userId,
        lat: pos.latitude,
        lng: pos.longitude,
      );
      if (isInZone) return;
    }

    // 追尾の疑いがあれば注意喚起し、その相手の通常通知・登録は抑制
    if (_recordAndCheckFollowing(otherUserId)) {
      _maybeWarnFollowing(otherUserId);
      return;
    }

    debugPrint('[BLE-DEBUG] すれ違い検知成功！otherUserId=$otherUserId');
    final timeStr = DateFormat('HH:mm').format(DateTime.now());
    await NotificationService().showEncounterNotification(timeStr: timeStr);

    // 登録・Push送信はバッチキューへ（集会などでの同時多発リクエストを抑える）
    _queueEncounter(otherUserId);
  }

  // 相手ユーザーたちへのサーバーサイドプッシュ通知（複数人分を1回のFunction呼び出しにまとめる）
  Future<void> _sendPushToOtherUsers(
      String userAId, List<String> userBIds) async {
    if (userBIds.isEmpty) return;
    try {
      await SupabaseConfig.client.functions.invoke(
        'send-encounter-notification',
        body: {'user_a_id': userAId, 'user_b_ids': userBIds},
      );
    } catch (e) {
      debugPrint('[BleEncounterService] push送信エラー: $e');
    }
  }

  // xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx 形式かどうかを簡易チェック
  static bool _looksLikeUuid(String s) =>
      s.length == 36 &&
      s[8] == '-' &&
      s[13] == '-' &&
      s[18] == '-' &&
      s[23] == '-';

  // MSD の 16 バイトビッグエンディアン → UUID 文字列（Android BlePeripheralPlugin と対称）
  static String? _uuidFromBytes(List<int> bytes) {
    if (bytes.length != 16) return null;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final uuid = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    return _looksLikeUuid(uuid) ? uuid : null;
  }

  // GATT接続 → FFF1 特性読み取り → 切断
  Future<String?> _readUserIdViaGatt(BluetoothDevice device) async {
    _activeGattConnections++;
    try {
      await device.connect(
          timeout: const Duration(seconds: 5), autoConnect: false);
      final services = await device.discoverServices();
      for (final service in services) {
        if (service.serviceUuid == _surfServiceUuid) {
          for (final char in service.characteristics) {
            if (char.characteristicUuid == _surfCharUuid) {
              final value = await char.read();
              await device.disconnect();
              if (value.isEmpty) return null;
              return utf8.decode(value);
            }
          }
        }
      }
      await device.disconnect();
    } catch (_) {
      try {
        await device.disconnect();
      } catch (_) {}
    } finally {
      _activeGattConnections--;
    }
    return null;
  }
}

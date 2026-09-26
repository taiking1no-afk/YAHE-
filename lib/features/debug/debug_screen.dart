import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/constants/app_colors.dart';
import '../../core/encounter/encounter_dedupe.dart';
import '../../core/supabase/supabase_config.dart';
import '../../shared/widgets/yahe_app_bar.dart';
import '../auth/presentation/auth_provider.dart';
import '../ble/ble_encounter_service.dart';
import '../home/data/encounter_repository.dart';
import '../home/presentation/home_provider.dart';
import '../notifications/notification_service.dart';
import '../settings/data/privacy_zone_repository.dart';
import '../settings/presentation/privacy_zone_screen.dart';
import '../vehicle/presentation/vehicle_register_provider.dart';

// デバッグ用のダミー相手ユーザーID（Supabaseに存在するユーザーで差し替える）
const _kTestPartnerUserId = 'TEST_USER_ID_REPLACE_ME';

class DebugScreen extends ConsumerStatefulWidget {
  const DebugScreen({super.key});

  @override
  ConsumerState<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends ConsumerState<DebugScreen> {
  Position? _currentPos;
  bool? _isInZone;
  double? _nearestZoneDistanceM;
  String? _nearestZoneLabel;
  bool _loading = false;
  bool _testModeEnabled = EncounterTestMode.localEnabled;
  String _log = '';
  final _testPartnerCtrl = TextEditingController(text: _kTestPartnerUserId);
  Timer? _bleStatusTimer;
  PermissionStatus? _notifPermStatus;

  @override
  void initState() {
    super.initState();
    _loadTestMode();
    // BLE実行状態（アドバタイズ成否・スキャン受信数）を1秒ごとに画面へ反映
    _bleStatusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadTestMode() async {
    await EncounterTestMode.load();
    if (!mounted) return;
    setState(() => _testModeEnabled = EncounterTestMode.localEnabled);
  }

  Future<void> _toggleTestMode(bool value) async {
    await EncounterTestMode.setLocalEnabled(value);
    if (!mounted) return;
    setState(() => _testModeEnabled = value);
    _appendLog(
      value ? '🧪 テストモードON（同一相手: 5分間隔）' : '✅ テストモードOFF（同一相手: 1日1回）',
    );
  }

  @override
  void dispose() {
    _testPartnerCtrl.dispose();
    _bleStatusTimer?.cancel();
    super.dispose();
  }

  void _appendLog(String msg) {
    final time = DateFormat('HH:mm:ss').format(DateTime.now());
    setState(() => _log = '[$time] $msg\n$_log');
  }

  // ─── GPS現在地取得 ───────────────────────────────────────
  Future<void> _fetchLocation() async {
    setState(() => _loading = true);
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        await Geolocator.requestPermission();
      }
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      setState(() => _currentPos = pos);
      _appendLog(
          'GPS取得: ${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}');
    } catch (e) {
      _appendLog('GPS エラー: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ─── 愛車ガードゾーン判定 ───────────────────────────────
  Future<void> _checkPrivacyZone() async {
    final user = ref.read(authNotifierProvider).value;
    if (user == null) {
      _appendLog('未ログイン');
      return;
    }
    if (_currentPos == null) {
      _appendLog('先にGPSを取得してください');
      return;
    }

    setState(() => _loading = true);
    try {
      final repo = PrivacyZoneRepository();
      final isIn = await repo.isInPrivacyZone(
        userId: user.userId,
        lat: _currentPos!.latitude,
        lng: _currentPos!.longitude,
      );

      // 最近傍ゾーンの距離も計算
      final zones = await repo.fetchZones(user.userId);
      double? minDist;
      String? nearLabel;
      for (final z in zones) {
        if (!z.isActive) continue;
        final d = Geolocator.distanceBetween(
          _currentPos!.latitude,
          _currentPos!.longitude,
          z.lat,
          z.lng,
        );
        if (minDist == null || d < minDist) {
          minDist = d;
          nearLabel = '${z.label}（半径${z.radiusM}m）';
        }
      }

      setState(() {
        _isInZone = isIn;
        _nearestZoneDistanceM = minDist;
        _nearestZoneLabel = nearLabel;
      });

      _appendLog(isIn ? '⛔ プライバシーゾーン内 → すれ違い記録なし' : '✅ ゾーン外 → すれ違い記録OK');
      if (minDist != null) {
        _appendLog('最近傍ゾーン($nearLabel): ${minDist.toStringAsFixed(1)}m');
      }
    } catch (e) {
      _appendLog('ゾーン判定エラー: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ─── テストすれ違いを手動発生 ────────────────────────────
  Future<void> _triggerFakeEncounter() async {
    final user = ref.read(authNotifierProvider).value;
    if (user == null) {
      _appendLog('未ログイン');
      return;
    }

    final partnerId = _testPartnerCtrl.text.trim();
    if (partnerId.isEmpty || partnerId == _kTestPartnerUserId) {
      _appendLog('⚠️ テスト相手のユーザーIDを入力してください');
      return;
    }

    setState(() => _loading = true);
    try {
      // プライバシーゾーン判定（GPS取得済みの場合）
      if (_currentPos != null) {
        final inZone = await PrivacyZoneRepository().isInPrivacyZone(
          userId: user.userId,
          lat: _currentPos!.latitude,
          lng: _currentPos!.longitude,
        );
        if (inZone) {
          _appendLog('⛔ プライバシーゾーン内のためすれ違いはスキップされました');
          if (mounted) setState(() => _loading = false);
          return;
        }
      }

      final repo = EncounterRepository();
      await repo.registerEncounter(
        userAId: user.userId,
        userBId: partnerId,
        aIsPremium: user.isPremium,
        bIsPremium: false,
      );

      // 通知発火
      final timeStr = DateFormat('HH:mm').format(DateTime.now());
      await NotificationService().showEncounterNotification(timeStr: timeStr);

      // タイムライン更新
      ref.invalidate(encountersProvider);

      _appendLog('✅ テストすれ違いを登録 + 通知送信（$timeStr）');
    } catch (e) {
      _appendLog('すれ違い登録エラー: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ─── テスト通知だけ発火 ─────────────────────────────────
  Future<void> _testNotificationOnly() async {
    final timeStr = DateFormat('HH:mm').format(DateTime.now());
    await NotificationService().showEncounterNotification(timeStr: timeStr);
    _appendLog('🔔 テスト通知を送信（$timeStr）');
  }

  // ─── 通知権限の状態を確認（Android 13+ の POST_NOTIFICATIONS 等）───
  Future<void> _checkNotificationPermission() async {
    final status = await Permission.notification.status;
    setState(() => _notifPermStatus = status);
    if (status.isGranted) {
      _appendLog('✅ 通知権限(OS全体): 許可済み');
    } else {
      _appendLog(
          '❌ 通知権限(OS全体): $status → showEncounterNotification が呼ばれても画面には出ません');
      if (status.isPermanentlyDenied) {
        _appendLog('→ 完全拒否状態のため、アプリの設定画面から手動でオンにする必要があります');
      }
    }

    // Android: アプリ単位・チャンネル単位で個別にOFFにされていないかも確認する。
    // permission_handler の許可判定は通っていても、ユーザーがシステム設定から
    // 「すれ違い通知」チャンネルだけを個別にOFFにしていると show() は例外を出さず
    // 黙って何も表示しない（これが最も気づきにくい原因）。
    final androidPlugin = NotificationService().androidPlugin;
    if (androidPlugin != null) {
      final enabled = await androidPlugin.areNotificationsEnabled();
      _appendLog(enabled == true
          ? '✅ アプリの通知(ネイティブ確認): 有効'
          : '❌ アプリの通知(ネイティブ確認): 無効 → 設定→アプリ→YAHE→通知 で有効にしてください');

      final channels = await androidPlugin.getNotificationChannels();
      final matches =
          channels?.where((c) => c.id == 'yahe_encounter').toList() ?? [];
      final encounterChannel = matches.isEmpty ? null : matches.first;
      if (encounterChannel != null) {
        _appendLog('すれ違い通知チャンネルの重要度: ${encounterChannel.importance}'
            '${encounterChannel.importance == Importance.none ? " ← OFFになっています" : ""}');
      }
    }
  }

  // ─── Supabase接続確認 ───────────────────────────────────
  Future<void> _checkSupabase() async {
    setState(() => _loading = true);
    try {
      final result =
          await SupabaseConfig.client.from('users').select('user_id').limit(1);
      _appendLog('✅ Supabase接続OK（users: ${result.length}件）');
    } catch (e) {
      _appendLog('❌ Supabase接続エラー: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ─── 自分のuserId表示 ───────────────────────────────────
  void _showMyUserId() {
    final user = ref.read(authNotifierProvider).value;
    if (user == null) {
      _appendLog('未ログイン');
      return;
    }
    _appendLog('自分のuserId: ${user.userId}');
    Clipboard.setData(ClipboardData(text: user.userId));
    _appendLog('→ クリップボードにコピーしました');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const YaheAppBar(title: 'デバッグ / テスト'),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ─── 警告バナー
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warning.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.warning.withOpacity(0.5)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.science_outlined,
                      color: AppColors.warning, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'このページは開発・テスト専用です。デバッグビルドのみ表示されます。',
                      style: TextStyle(color: AppColors.warning, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ─── GPS & 愛車ガード
            _SectionTitle('① GPS & 愛車ガード判定'),
            _InfoRow(
                '現在地',
                _currentPos != null
                    ? '${_currentPos!.latitude.toStringAsFixed(5)}, ${_currentPos!.longitude.toStringAsFixed(5)}'
                    : '未取得'),
            if (_isInZone != null) ...[
              _InfoRow(
                  'ゾーン内判定', _isInZone! ? '⛔ ゾーン内（すれ違い記録なし）' : '✅ ゾーン外（記録OK）'),
              if (_nearestZoneDistanceM != null)
                _InfoRow('最近傍ゾーン',
                    '$_nearestZoneLabel: ${_nearestZoneDistanceM!.toStringAsFixed(0)}m'),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _loading ? null : _fetchLocation,
                    icon: const Icon(Icons.gps_fixed, size: 16),
                    label: const Text('GPS取得'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _loading ? null : _checkPrivacyZone,
                    icon: const Icon(Icons.shield_outlined, size: 16),
                    label: const Text('ゾーン判定'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PrivacyZoneScreen()),
              ),
              icon: const Icon(Icons.map_outlined, size: 16),
              label: const Text('愛車ガード設定を開く'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 40)),
            ),
            const SizedBox(height: 20),

            // ─── すれ違いテストモード
            _SectionTitle('② すれ違い間隔（テスト用）'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                '連続すれ違いテストモード',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 14),
              ),
              subtitle: Text(
                EncounterTestMode.statusLabel +
                    (EncounterTestMode.serverAllowed
                        ? ''
                        : '\n※ TestFlight等では Supabase で encounter_test_mode = true が必要'),
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: 11, height: 1.4),
              ),
              value: _testModeEnabled,
              onChanged: _toggleTestMode,
            ),
            const SizedBox(height: 20),

            // ─── テストすれ違い
            _SectionTitle('③ テストすれ違い（通知 + DB登録）'),
            const Text(
              'すれ違い相手のユーザーIDを入力（相手もYAHEアカウントが必要）\n'
              '自分のuserIdは下の「コピー」ボタンで確認できます',
              style: TextStyle(
                  color: AppColors.textMuted, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _testPartnerCtrl,
              style:
                  const TextStyle(color: AppColors.textPrimary, fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'テスト相手のuserIdを入力',
                prefixIcon: Icon(Icons.person_search_outlined, size: 18),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _loading ? null : _triggerFakeEncounter,
                    icon: const Icon(Icons.swap_horiz, size: 16),
                    label: const Text('すれ違いを発生させる'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _loading ? null : _testNotificationOnly,
                    icon: const Icon(Icons.notifications_outlined, size: 16),
                    label: const Text('通知のみテスト'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _loading ? null : _showMyUserId,
                    icon: const Icon(Icons.copy_outlined, size: 16),
                    label: const Text('自分のIDコピー'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: _loading ? null : _checkNotificationPermission,
              icon: const Icon(Icons.notifications_active_outlined, size: 16),
              label: const Text('通知権限を確認'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 40)),
            ),
            if (_notifPermStatus != null) ...[
              const SizedBox(height: 4),
              _InfoRow('通知権限', '$_notifPermStatus'),
            ],
            const SizedBox(height: 20),

            // ─── BLE実行状態（実機での目視デバッグ用・1秒ごとに自動更新）
            _SectionTitle('④ BLE実行状態（自動更新）'),
            Builder(builder: (context) {
              final ble = BleEncounterService();
              final adapterState = FlutterBluePlus.adapterStateNow;
              final isScanning = FlutterBluePlus.isScanningNow;
              final lastScanAgo = ble.lastScanResultAt == null
                  ? null
                  : DateTime.now().difference(ble.lastScanResultAt!).inSeconds;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoRow('Bluetoothアダプタ', '$adapterState'),
                  _InfoRow('検知サービス起動', ble.isRunning ? '✅ 起動中' : '❌ 未起動'),
                  _InfoRow('スキャン中', isScanning ? '✅ はい' : '❌ いいえ'),
                  _InfoRow(
                      'アドバタイズ(自分の発信)',
                      ble.lastAdvertiseError == null
                          ? '✅ 成功'
                          : '❌ 失敗: ${ble.lastAdvertiseError}'),
                  _InfoRow('スキャン受信数(累計)', '${ble.scanResultCount}件'),
                  _InfoRow(
                      '直近の受信',
                      ble.lastScanInfo == null
                          ? 'まだ何も受信していません'
                          : '${ble.lastScanInfo}（$lastScanAgo秒前, device=${ble.lastScanDeviceId}）'),
                  _InfoRow(
                      '直近マッチしたuserId', ble.lastMatchedUserId ?? '（まだマッチなし）'),
                ],
              );
            }),
            const SizedBox(height: 20),

            // ─── Supabase確認
            _SectionTitle('③ 接続確認'),
            OutlinedButton.icon(
              onPressed: _loading ? null : _checkSupabase,
              icon: const Icon(Icons.cloud_outlined, size: 16),
              label: const Text('Supabase疎通確認'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 40)),
            ),
            const SizedBox(height: 20),

            // ─── ログ表示
            _SectionTitle('ログ'),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(
                    child: CircularProgressIndicator(color: AppColors.primary)),
              ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(10),
              ),
              child: _log.isEmpty
                  ? const Text('ログはここに表示されます',
                      style:
                          TextStyle(color: AppColors.textMuted, fontSize: 12))
                  : SelectableText(
                      _log,
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 12,
                        fontFamily: 'monospace',
                        height: 1.5,
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => setState(() => _log = ''),
              icon: const Icon(Icons.clear_all, size: 16),
              label: const Text('ログをクリア'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 36),
                foregroundColor: AppColors.textMuted,
                side: const BorderSide(color: AppColors.border),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 100,
              child: Text(label,
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 12)),
            ),
          ],
        ),
      );
}

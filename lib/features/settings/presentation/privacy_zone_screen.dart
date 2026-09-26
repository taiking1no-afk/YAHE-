import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../auth/presentation/auth_provider.dart';
import '../data/privacy_zone_repository.dart';
import '../models/privacy_zone.dart';

final privacyZoneRepositoryProvider =
    Provider<PrivacyZoneRepository>((ref) => PrivacyZoneRepository());

final privacyZonesProvider = FutureProvider.family<List<PrivacyZone>, String>(
  (ref, userId) async {
    final repo = ref.read(privacyZoneRepositoryProvider);
    return repo.fetchZones(userId);
  },
);

class PrivacyZoneScreen extends ConsumerStatefulWidget {
  const PrivacyZoneScreen({super.key});

  @override
  ConsumerState<PrivacyZoneScreen> createState() => _PrivacyZoneScreenState();
}

class _PrivacyZoneScreenState extends ConsumerState<PrivacyZoneScreen> {
  final _mapController = MapController();
  Position? _currentPosition;

  // 地図上でタップした座標（ゾーン追加の中心点）
  LatLng? _pendingLatLng;

  @override
  void initState() {
    super.initState();
    // 端末のキャッシュ済み位置が即座に返るケースでは、initStateから直接
    // 呼ぶと FlutterMap がまだマウントされる前に _mapController.move() が
    // 呼ばれてしまうことがあった（flutter_map既知の問題）。この例外は
    // 非同期コールバック内で発生するため、囲んでいる try/catch では
    // 捕捉できずクラッシュしていた。初回フレーム描画後まで遅延させる。
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchLocation());
  }

  Future<void> _fetchLocation() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        await Geolocator.requestPermission();
      }
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (!mounted) return;
      setState(() => _currentPosition = pos);
      try {
        _mapController.move(LatLng(pos.latitude, pos.longitude), 14);
      } catch (_) {
        // マップがまだ準備できていない場合は無視する（initialCenterで
        // 既に現在地を中心に表示しようとするため、実害はない）。
      }
    } catch (_) {}
  }

  void _onMapTap(TapPosition tapPos, LatLng latlng) {
    // FlutterMapのonTapコールバックは、その地図自身のジェスチャー処理が
    // 完了する前に同期的に呼ばれる。ここで直接setStateしてFlutterMap自体を
    // 再構築したり、さらにshowModalBottomSheetでルートをpushしたりすると、
    // flutter_map側の後始末が間に合わず "_dependents.isEmpty" の
    // フレームワークアサーションでクラッシュすることがあった
    // （タップ→ゾーン追加シートの表示直後にクラッシュする不具合の原因）。
    // 1フレーム後まで処理を遅延させ、タップのジェスチャー処理と
    // ウィジェットツリーの変更を同一フレーム内で競合させないようにする。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _handleMapTap(latlng);
    });
  }

  void _handleMapTap(LatLng latlng) {
    setState(() => _pendingLatLng = latlng);
    final user = ref.read(authNotifierProvider).value;
    if (user == null) return;

    final zoneCount =
        ref.read(privacyZonesProvider(user.userId)).value?.length ?? 0;
    if (!user.isPremium && zoneCount >= AppConstants.freePrivacyZoneLimit) {
      setState(() => _pendingLatLng = null);
      _showZoneLimitReached();
      return;
    }

    _showAddZoneDialog(latlng, user.userId, user.isPremium);
  }

  void _showZoneLimitReached() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '無料プランは愛車ガード${AppConstants.freePrivacyZoneLimit}ヶ所までです。'
          'Gear+以上で無制限に追加できます。',
        ),
        backgroundColor: AppColors.surface,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userAsync = ref.watch(authNotifierProvider);
    final user = userAsync.value;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('愛車ガード'),
        actions: [
          if (_currentPosition != null)
            IconButton(
              icon: const Icon(Icons.my_location),
              tooltip: '現在地に戻る',
              onPressed: () => _mapController.move(
                LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
                14,
              ),
            ),
        ],
      ),
      body: user == null
          ? const Center(child: Text('ログインが必要です'))
          : Column(
              children: [
                // 操作ガイド
                Container(
                  color: AppColors.primary.withOpacity(0.06),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: const Row(
                    children: [
                      Icon(Icons.touch_app_outlined,
                          size: 16, color: AppColors.primary),
                      SizedBox(width: 8),
                      Text(
                        '地図上の好きな場所をタップしてゾーンを追加',
                        style:
                            TextStyle(color: AppColors.primary, fontSize: 13),
                      ),
                    ],
                  ),
                ),

                // 地図（タップで地点選択）
                SizedBox(
                  height: 280,
                  child: _MapView(
                    currentPosition: _currentPosition,
                    mapController: _mapController,
                    zonesAsync: ref.watch(privacyZonesProvider(user.userId)),
                    pendingLatLng: _pendingLatLng,
                    onTap: _onMapTap,
                  ),
                ),
                const Divider(height: 1, color: AppColors.border),

                // ゾーン一覧
                Expanded(
                  child: ref.watch(privacyZonesProvider(user.userId)).when(
                        loading: () => const Center(
                          child: CircularProgressIndicator(
                              color: AppColors.primary),
                        ),
                        error: (e, _) =>
                            const Center(child: Text('読み込みに失敗しました')),
                        data: (zones) {
                          if (zones.isEmpty) {
                            return _EmptyZoneState();
                          }
                          return ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: zones.length,
                            itemBuilder: (context, i) => _ZoneTile(
                              zone: zones[i],
                              onToggle: (v) async {
                                final repo =
                                    ref.read(privacyZoneRepositoryProvider);
                                try {
                                  await repo.toggleZone(zones[i].zoneId, v);
                                  ref.invalidate(
                                      privacyZonesProvider(user.userId));
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('変更に失敗しました: $e')),
                                    );
                                  }
                                }
                              },
                              onDelete: () async {
                                final repo =
                                    ref.read(privacyZoneRepositoryProvider);
                                try {
                                  await repo.deleteZone(zones[i].zoneId);
                                  ref.invalidate(
                                      privacyZonesProvider(user.userId));
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('削除に失敗しました: $e')),
                                    );
                                  }
                                }
                              },
                            ),
                          );
                        },
                      ),
                ),
              ],
            ),
    );
  }

  void _showAddZoneDialog(LatLng latlng, String userId, bool isPremium) {
    int radius = 500;
    final labelCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
        child: StatefulBuilder(
          builder: (ctx, setS) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'プライバシーゾーンを追加',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${latlng.latitude.toStringAsFixed(5)}, ${latlng.longitude.toStringAsFixed(5)}',
                style:
                    const TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 16),

              // 名称（自由入力）
              const Text('ゾーン名',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: labelCtrl,
                autofocus: true,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: const InputDecoration(
                  hintText: '例：自宅、職場、行きつけのショップ など',
                ),
              ),
              const SizedBox(height: 16),

              // サイズスライダー（中心から各辺までの距離）
              Row(
                children: [
                  const Text('サイズ（中心から）',
                      style:
                          TextStyle(color: AppColors.textMuted, fontSize: 12)),
                  const Spacer(),
                  Text(
                    radius >= 1000
                        ? '${(radius / 1000).toStringAsFixed(1)} km'
                        : '$radius m',
                    style: const TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13),
                  ),
                ],
              ),
              SliderTheme(
                // オーバーレイ(リップル)を無効化。ドラッグ直後にシートを閉じた際、
                // アニメーション中のオーバーレイの後始末が間に合わず
                // クラッシュする既知のFlutterの問題を避けるため。
                data: SliderTheme.of(context).copyWith(
                  overlayShape: SliderComponentShape.noOverlay,
                ),
                child: Slider(
                  value: radius.toDouble(),
                  min: 100,
                  max: 3000,
                  divisions: 29,
                  activeColor: AppColors.primary,
                  onChanged: (v) => setS(() => radius = v.round()),
                ),
              ),
              const SizedBox(height: 16),

              ElevatedButton(
                onPressed: () {
                  final name = labelCtrl.text.trim();
                  // TextField(autofocus: true) にフォーカスが残ったまま
                  // ボトムシートをpopすると、フォーカスの解放処理が完了する前に
                  // ウィジェットツリーから取り除かれ、
                  // "_dependents.isEmpty" のフレームワークアサーションで
                  // クラッシュすることがあった。popする前に明示的にフォーカスを外す。
                  FocusScope.of(ctx).unfocus();
                  Navigator.pop(ctx);
                  // popの直後に親画面（地図を含む）へ同期的にsetStateすると、
                  // ボトムシートのpop処理がまだ完了していない同一フレーム内で
                  // FlutterMapを含む親のウィジェットツリーが変更されることになり、
                  // 上と同じ種類のクラッシュが起きていた。次のフレームまで
                  // 完全に遅延させ、popの後始末と完全に切り離す。
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _createZoneAfterDialogClosed(
                      userId: userId,
                      latlng: latlng,
                      radius: radius,
                      name: name,
                    );
                  });
                },
                child: const Text('追加'),
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(() {
      setState(() => _pendingLatLng = null);
      // labelCtrlはこのメソッドのローカル変数のためStateのdispose()では
      // 破棄されず、ダイアログを開くたびにリークしていた。
      labelCtrl.dispose();
    });
  }

  Future<void> _createZoneAfterDialogClosed({
    required String userId,
    required LatLng latlng,
    required int radius,
    required String name,
  }) async {
    if (!mounted) return;
    setState(() => _pendingLatLng = null);
    final repo = ref.read(privacyZoneRepositoryProvider);
    try {
      await repo.createZone(
        userId: userId,
        lat: latlng.latitude,
        lng: latlng.longitude,
        radiusM: radius,
        label: name.isEmpty ? 'ゾーン' : name,
      );
      ref.invalidate(privacyZonesProvider(userId));
    } catch (e) {
      if (!mounted) return;
      if (e.toString().contains('privacy_zone_limit_reached')) {
        _showZoneLimitReached();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('追加に失敗しました: $e')),
        );
      }
    }
  }
}

// ─── 地図ウィジェット ────────────────────────────────────────
class _MapView extends StatelessWidget {
  final Position? currentPosition;
  final MapController mapController;
  final AsyncValue<List<PrivacyZone>> zonesAsync;
  final LatLng? pendingLatLng;
  final Function(TapPosition, LatLng) onTap;

  const _MapView({
    required this.currentPosition,
    required this.mapController,
    required this.zonesAsync,
    required this.pendingLatLng,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pos = currentPosition;
    final initialCenter = pos != null
        ? LatLng(pos.latitude, pos.longitude)
        : const LatLng(35.6812, 139.7671);

    final zones = zonesAsync.value ?? [];

    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: initialCenter,
        initialZoom: 13,
        onTap: onTap,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'jp.nozawataiki.yahe',
        ),
        // 登録済みゾーン（四角形）
        PolygonLayer(
          polygons: [
            ...zones.map(
              (z) => Polygon(
                points: _squareCorners(z.lat, z.lng, z.radiusM.toDouble()),
                color: z.isActive
                    ? AppColors.primary.withOpacity(0.15)
                    : AppColors.textMuted.withOpacity(0.1),
                borderColor: z.isActive
                    ? AppColors.primary.withOpacity(0.6)
                    : AppColors.textMuted.withOpacity(0.4),
                borderStrokeWidth: 1.5,
              ),
            ),
          ],
        ),
        CircleLayer(
          circles: [
            // 現在地マーカー
            if (pos != null)
              CircleMarker(
                point: LatLng(pos.latitude, pos.longitude),
                radius: 8,
                color: Colors.blue,
                borderColor: Colors.white,
                borderStrokeWidth: 2,
                useRadiusInMeter: false,
              ),
            // 選択中（タップ済み）の仮マーカー
            if (pendingLatLng != null)
              CircleMarker(
                point: pendingLatLng!,
                radius: 10,
                color: AppColors.primary.withOpacity(0.5),
                borderColor: AppColors.primary,
                borderStrokeWidth: 2,
                useRadiusInMeter: false,
              ),
          ],
        ),
      ],
    );
  }

  // 中心から半辺 halfM[m] の正方形（緯度経度に沿った矩形）の四隅を返す
  static List<LatLng> _squareCorners(double lat, double lng, double halfM) {
    const metersPerDegLat = 111320.0;
    final metersPerDegLng = 111320.0 * cos(lat * pi / 180);
    final dLat = halfM / metersPerDegLat;
    final dLng = metersPerDegLng == 0 ? 0.0 : halfM / metersPerDegLng;
    return [
      LatLng(lat + dLat, lng - dLng),
      LatLng(lat + dLat, lng + dLng),
      LatLng(lat - dLat, lng + dLng),
      LatLng(lat - dLat, lng - dLng),
    ];
  }
}

// ─── ゾーンタイル ────────────────────────────────────────────
class _ZoneTile extends StatelessWidget {
  final PrivacyZone zone;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  const _ZoneTile({
    required this.zone,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: zone.isActive
              ? AppColors.primary.withOpacity(0.12)
              : AppColors.border,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.shield_outlined,
          color: zone.isActive ? AppColors.primary : AppColors.textMuted,
          size: 20,
        ),
      ),
      title: Text(
        zone.label,
        style: TextStyle(
          color: zone.isActive ? AppColors.textPrimary : AppColors.textMuted,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '範囲 ±${zone.radiusM >= 1000 ? "${(zone.radiusM / 1000).toStringAsFixed(1)}km" : "${zone.radiusM}m"}',
        style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: zone.isActive,
            onChanged: onToggle,
            activeColor: AppColors.primary,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline,
                color: AppColors.error, size: 20),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _EmptyZoneState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.shield_outlined, size: 56, color: AppColors.textMuted),
          SizedBox(height: 12),
          Text(
            'ゾーンがありません',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 15),
          ),
          SizedBox(height: 6),
          Text(
            '地図上をタップして\nプライバシーゾーンを追加できます',
            style: TextStyle(
                color: AppColors.textMuted, fontSize: 12, height: 1.6),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

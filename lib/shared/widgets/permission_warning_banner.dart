import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/constants/app_colors.dart';

class PermissionStatus {
  final bool locationAlways;
  final bool bluetooth;
  final bool notification;

  const PermissionStatus({
    required this.locationAlways,
    required this.bluetooth,
    required this.notification,
  });

  bool get allGranted => locationAlways && bluetooth && notification;

  List<_MissingItem> get missingItems {
    final items = <_MissingItem>[];
    if (!locationAlways) {
      items.add(const _MissingItem(
        icon: Icons.location_off,
        label: '位置情報：「常に許可」が必要',
      ));
    }
    if (!bluetooth) {
      items.add(const _MissingItem(
        icon: Icons.bluetooth_disabled,
        label: 'Bluetooth：オン・許可が必要',
      ));
    }
    if (!notification) {
      items.add(const _MissingItem(
        icon: Icons.notifications_off,
        label: '通知：許可が必要',
      ));
    }
    return items;
  }
}

class _MissingItem {
  final IconData icon;
  final String label;
  const _MissingItem({required this.icon, required this.label});
}

// Bluetoothの電源状態を監視する。これを watch することで、アプリを開いたまま
// コントロールセンター等でBluetoothを切り替えても、バックグラウンド復帰を待たずに
// バナーが即座に再評価されるようにする。
final _bluetoothAdapterStateProvider =
    StreamProvider.autoDispose<BluetoothAdapterState>((ref) {
  return FlutterBluePlus.adapterState;
});

final permissionStatusProvider = FutureProvider.autoDispose<PermissionStatus>((ref) async {
  ref.watch(_bluetoothAdapterStateProvider);
  return checkPermissions();
});

Future<PermissionStatus> checkPermissions() async {
  bool locationAlways = false;
  bool bt = false;
  bool notif = false;

  try {
    final locPerm = await Geolocator.checkPermission();
    debugPrint('[PERM-DEBUG] Geolocator.checkPermission() = $locPerm');
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      locationAlways = locPerm == LocationPermission.always;
    } else {
      locationAlways = locPerm == LocationPermission.always ||
          locPerm == LocationPermission.whileInUse;
    }
  } catch (e) {
    debugPrint('[PERM-DEBUG] location check error: $e');
  }

  try {
    bool permissionOk;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final scan = await Permission.bluetoothScan.isGranted;
      final advertise = await Permission.bluetoothAdvertise.isGranted;
      permissionOk = scan && advertise;
      debugPrint('[PERM-DEBUG] Android bluetoothScan=$scan advertise=$advertise');
    } else {
      // iOS: permission_handler の Permission.bluetooth は実際にBLEを動かしている
      // flutter_blue_plus の内部状態と食い違うことがあり、許可済みでも denied を
      // 返すことがあった。実際にBLEを動かしている flutter_blue_plus の
      // adapterState（unauthorized かどうか）で判定する方が実態に即している。
      permissionOk = FlutterBluePlus.adapterStateNow != BluetoothAdapterState.unauthorized;
    }
    // 許可があっても本体のBluetooth自体がオフだとすれ違い検知は動かないため、
    // 電源状態（adapterState）も合わせてチェックする。
    final adapterState = FlutterBluePlus.adapterStateNow;
    debugPrint('[PERM-DEBUG] FlutterBluePlus.adapterStateNow = $adapterState');
    bt = permissionOk && adapterState == BluetoothAdapterState.on;
  } catch (e) {
    debugPrint('[PERM-DEBUG] bluetooth check error: $e');
    bt = true;
  }

  try {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final status = await Permission.notification.status;
      debugPrint('[PERM-DEBUG] Permission.notification.status = $status');
      notif = status.isGranted;
    } else {
      // iOS: permission_handler の Permission.notification も Bluetooth と同様に
      // 実態と食い違うことがあったため、実際に通知許可をリクエストしている
      // FirebaseMessaging 自身の状態を見る方が実態に即している。
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      debugPrint('[PERM-DEBUG] FirebaseMessaging authorizationStatus = ${settings.authorizationStatus}');
      notif = settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    }
  } catch (e) {
    debugPrint('[PERM-DEBUG] notification check error: $e');
  }

  debugPrint('[PERM-DEBUG] 結果: locationAlways=$locationAlways bluetooth=$bt notification=$notif');

  return PermissionStatus(
    locationAlways: locationAlways,
    bluetooth: bt,
    notification: notif,
  );
}

class PermissionWarningBanner extends ConsumerWidget {
  const PermissionWarningBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(permissionStatusProvider);

    return statusAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (status) {
        if (status.allGranted) return const SizedBox.shrink();

        final missing = status.missingItems;
        return GestureDetector(
          onTap: () => openAppSettings(),
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.warning.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.warning.withOpacity(0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: AppColors.warning, size: 18),
                    SizedBox(width: 6),
                    Text(
                      'すれ違い検知に必要な設定が不足しています',
                      style: TextStyle(
                        color: AppColors.warning,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ...missing.map((m) => Padding(
                  padding: const EdgeInsets.only(left: 24, bottom: 2),
                  child: Row(
                    children: [
                      Icon(m.icon, size: 14, color: AppColors.error),
                      const SizedBox(width: 6),
                      Text(
                        m.label,
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                      ),
                    ],
                  ),
                )),
                const SizedBox(height: 4),
                const Padding(
                  padding: EdgeInsets.only(left: 24),
                  child: Text(
                    'タップして設定を開く',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

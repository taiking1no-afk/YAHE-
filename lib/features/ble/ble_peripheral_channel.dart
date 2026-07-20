import 'package:flutter/services.dart';

// iOS-only platform channel for CoreBluetooth peripheral advertising
class BlePeripheralChannel {
  static const _channel = MethodChannel('surf/ble_peripheral');

  static Future<void> startAdvertising(String userId) async {
    await _channel.invokeMethod('startAdvertising', {'userId': userId});
  }

  static Future<void> stopAdvertising() async {
    await _channel.invokeMethod('stopAdvertising');
  }
}

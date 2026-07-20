import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    // super の後に FlutterViewController が取れれば即座に登録（通常パス）
    tryRegisterBlePlugin()
    return result
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // FlutterImplicitEngineDelegate 使用時は engine 初期化後にも登録を試みる（フォールバック）
    tryRegisterBlePlugin()
  }

  // FlutterViewController が取れた時点で BlePeripheralPlugin を登録する。
  // didFinish / didInitialize の両方から呼ばれるが、setMethodCallHandler は
  // 上書きされるだけなので二重登録しても問題ない。
  private func tryRegisterBlePlugin() {
    if let vc = window?.rootViewController as? FlutterViewController {
      BlePeripheralPlugin.register(with: vc.binaryMessenger)
    }
  }
}

import Flutter
import UIKit
import CoreBluetooth

// SURF BLE Peripheral
// - Foreground: advertises local name "SURF:<userId>" + service UUID FFF0
// - Background: iOS strips local name; exposes GATT characteristic FFF1 so
//   the remote scanner can connect and read the userId even when backgrounded.
class BlePeripheralPlugin: NSObject, CBPeripheralManagerDelegate {

    static let surfServiceUUID        = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    static let surfCharacteristicUUID = CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB")

    private var peripheralManager: CBPeripheralManager?
    private var pendingUserId: String?
    private var currentUserId: String = ""
    private var userIdCharacteristic: CBMutableCharacteristic?

    // Called from AppDelegate to wire up the MethodChannel.
    static func register(with messenger: FlutterBinaryMessenger) {
        let instance = BlePeripheralPlugin()
        let channel = FlutterMethodChannel(name: "surf/ble_peripheral", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak instance] call, result in
            guard let self = instance else { return }
            switch call.method {
            case "startAdvertising":
                let args = call.arguments as? [String: Any]
                let userId = args?["userId"] as? String ?? ""
                self.startAdvertising(userId: userId)
                result(nil)
            case "stopAdvertising":
                self.stopAdvertising()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        objc_setAssociatedObject(channel, "blePeripheralPlugin", instance, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func startAdvertising(userId: String) {
        print("[BLE-DEBUG][iOS] startAdvertising 呼び出し userId=\(userId) managerState=\(String(describing: peripheralManager?.state.rawValue))")
        pendingUserId = userId
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        } else if peripheralManager?.state == .poweredOn {
            setupServiceAndAdvertise(userId: userId)
        }
    }

    private func stopAdvertising() {
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        pendingUserId = nil
        currentUserId = ""
    }

    // サービスを2つ登録してから広告開始（両方の didAdd を待つ）
    private var servicesAdded = 0

    private func setupServiceAndAdvertise(userId: String) {
        currentUserId = userId
        servicesAdded = 0
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()

        // Service 1: FFF0 マーカー + userId 特性（GATT フォールバック用）
        let characteristic = CBMutableCharacteristic(
            type: BlePeripheralPlugin.surfCharacteristicUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )
        userIdCharacteristic = characteristic
        let markerService = CBMutableService(type: BlePeripheralPlugin.surfServiceUUID, primary: true)
        markerService.characteristics = [characteristic]
        peripheralManager?.add(markerService)

        // Service 2: userId そのものをサービス UUID として広告
        // → バックグラウンド広告パケットに含まれ、接続なしで即座に読み取れる
        let userUUID = CBUUID(string: userId.lowercased())
        let userService = CBMutableService(type: userUUID, primary: true)
        peripheralManager?.add(userService)
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        print("[BLE-DEBUG][iOS] peripheralManagerDidUpdateState state=\(peripheral.state.rawValue)")
        if peripheral.state == .poweredOn, let userId = pendingUserId {
            setupServiceAndAdvertise(userId: userId)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            print("[BLE-DEBUG][iOS] didAdd service エラー: \(error)")
            return
        }
        servicesAdded += 1
        print("[BLE-DEBUG][iOS] didAdd service 成功 (\(servicesAdded)/2) uuid=\(service.uuid)")
        guard servicesAdded >= 2 else { return } // 両サービス登録完了を待つ

        let advertisementData: [String: Any] = [
            // フォアグラウンド時のみ送出（バックグラウンドでは iOS が省略）
            CBAdvertisementDataLocalNameKey: "SURF:\(currentUserId)",
            // バックグラウンドでも送出される（FFF0 + userId UUID 両方）
            CBAdvertisementDataServiceUUIDsKey: [
                BlePeripheralPlugin.surfServiceUUID,         // SURF マーカー
                CBUUID(string: currentUserId.lowercased()),  // userId = UUID そのもの
            ],
        ]
        peripheral.startAdvertising(advertisementData)
        print("[BLE-DEBUG][iOS] startAdvertising(adData) 呼び出し完了 userId=\(currentUserId)")
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            print("[BLE-DEBUG][iOS] アドバタイズ開始エラー: \(error)")
        } else {
            print("[BLE-DEBUG][iOS] アドバタイズ開始成功")
        }
    }

    // GATT フォールバック: Central が FFF1 特性を読みに来たら userId を返す
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if request.characteristic.uuid == BlePeripheralPlugin.surfCharacteristicUUID {
            request.value = currentUserId.data(using: .utf8)
            peripheral.respond(to: request, withResult: .success)
        } else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
        }
    }
}

package jp.nozawataiki.yahe

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.ParcelUuid
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.UUID

/**
 * Android BLE Peripheral (アドバタイズ) プラグイン
 *
 * iOS の BlePeripheralPlugin.swift と同等の機能を Android で実装。
 *
 * プライマリ広告パケット（25 bytes）:
 *   Flags           :  3 bytes
 *   FFF0 (16-bit)   :  4 bytes  ← iOS スキャンフィルター用
 *   userId (128-bit): 18 bytes  ← iOS フォアグラウンド検知 (方法②)
 *
 * スキャンレスポンス（20 bytes）:
 *   MSD company_id  :  2 bytes  (0x5946)
 *   userId (16 bytes): 16 bytes ← iOS バックグラウンド検知 (方法②')
 *   ※ iOS バックグラウンドでは serviceUuids が FFF0 のみに制限されるため
 *      MSD で userId を確実に届ける
 */
@SuppressLint("MissingPermission")
class BlePeripheralPlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    private val SURF_SERVICE_UUID = UUID.fromString("0000FFF0-0000-1000-8000-00805F9B34FB")
    private val SURF_CHAR_UUID    = UUID.fromString("0000FFF1-0000-1000-8000-00805F9B34FB")

    private val bluetoothManager: BluetoothManager by lazy {
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    }
    private val bluetoothAdapter get() = bluetoothManager.adapter

    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var gattServer: BluetoothGattServer? = null
    private var currentUserId = ""

    companion object {
        // YAHE アプリ用 MSD カンパニー ID（Bluetooth SIG 未登録の私用値）
        private const val SURF_COMPANY_ID = 0x5946

        fun register(channel: MethodChannel, context: Context) {
            channel.setMethodCallHandler(BlePeripheralPlugin(context))
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startAdvertising" -> {
                val userId = call.argument<String>("userId") ?: ""
                startAdvertising(userId)
                result.success(null)
            }
            "stopAdvertising" -> {
                stopAdvertising()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startAdvertising(userId: String) {
        stopAdvertising()
        currentUserId = userId

        val userUUID = try {
            UUID.fromString(userId.lowercase())
        } catch (_: IllegalArgumentException) {
            return
        }

        // GATT サーバーは低速時のフォールバック用に過ぎないため、権限不足などで
        // 失敗してもアドバタイズ本体（検知の主役）は継続させる
        try {
            startGattServer()
        } catch (e: SecurityException) {
            android.util.Log.w("BlePeripheralPlugin", "GATTサーバー起動失敗（権限不足の可能性）: $e")
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0)
            .build()

        // プライマリ: FFF0 マーカー + userId UUID（iOS フォアグラウンド向け）
        val primaryData = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SURF_SERVICE_UUID))
            .addServiceUuid(ParcelUuid(userUUID))
            .build()

        // スキャンレスポンス: MSD に userId を16バイトバイナリで格納（iOS バックグラウンド向け）
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addManufacturerData(SURF_COMPANY_ID, userUUID.toBytes())
            .build()

        val cb = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {}
            override fun onStartFailure(errorCode: Int) {}
        }
        advertiseCallback = cb
        advertiser = bluetoothAdapter.bluetoothLeAdvertiser
        advertiser?.startAdvertising(settings, primaryData, scanResponse, cb)
    }

    private fun stopAdvertising() {
        advertiseCallback?.let { advertiser?.stopAdvertising(it) }
        advertiseCallback = null
        advertiser = null
        gattServer?.close()
        gattServer = null
        currentUserId = ""
    }

    // GATT サーバー: FFF1 特性で userId を返す（低速時のフォールバック用）
    private fun startGattServer() {
        val server = bluetoothManager.openGattServer(context, object : BluetoothGattServerCallback() {
            override fun onCharacteristicReadRequest(
                device: BluetoothDevice, requestId: Int, offset: Int,
                characteristic: BluetoothGattCharacteristic
            ) {
                if (characteristic.uuid == SURF_CHAR_UUID) {
                    gattServer?.sendResponse(
                        device, requestId, BluetoothGatt.GATT_SUCCESS, 0,
                        currentUserId.toByteArray(Charsets.UTF_8)
                    )
                } else {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
                }
            }
        }) ?: return

        val service = BluetoothGattService(
            SURF_SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY
        )
        val characteristic = BluetoothGattCharacteristic(
            SURF_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ
        )
        service.addCharacteristic(characteristic)
        server.addService(service)
        gattServer = server
    }

    // UUID → 16バイトビッグエンディアン変換
    private fun UUID.toBytes(): ByteArray {
        val bb = ByteBuffer.allocate(16)
        bb.putLong(mostSignificantBits)
        bb.putLong(leastSignificantBits)
        return bb.array()
    }
}

import 'dart:async';

/// 一覧画面等の初期ロードで使う既定タイムアウト。
/// サーバー無応答時に画面が無限ローディングのままにならないようにする。
const kNetworkTimeout = Duration(seconds: 15);

extension NetworkTimeoutExtension<T> on Future<T> {
  /// [kNetworkTimeout]で打ち切り、TimeoutExceptionを投げる。
  Future<T> withNetworkTimeout() => timeout(
        kNetworkTimeout,
        onTimeout: () => throw TimeoutException('通信がタイムアウトしました'),
      );
}

import 'dart:async';

/// Realtime購読のコールバックで使う、先頭+末尾方式のスロットル。
///
/// 大人数が短時間に一斉操作（参加・気になる等）すると、テーブル変更イベントが
/// 連続で届き、そのたびに ref.invalidate() → 画面再構築が走って「チカチカ」
/// して見えてしまう。かといって間引きすぎると、他のユーザーの反映が
/// 遅れすぎたり、サーバー側の実データと画面がズレたまま長時間放置される
/// （定員判定などは常にサーバー側RPCがFOR UPDATEロックで最終防衛するため
/// 安全だが、UI上の「あと何人」表示は多少ズレる）。
///
/// そのため: 直近 [window] 以内に呼ばれていなければ即座に反映（先頭）。
/// 連続で呼ばれた場合はまとめて、window経過後に最後の状態を1回だけ反映
/// （末尾）する。これにより反映回数は最大でも「window間隔に1回」になる。
class InvalidationThrottle {
  InvalidationThrottle({this.window = const Duration(milliseconds: 800)});

  final Duration window;
  Timer? _timer;
  DateTime? _lastFired;
  bool _pending = false;

  void trigger(void Function() invalidate) {
    final now = DateTime.now();
    if (_lastFired == null || now.difference(_lastFired!) >= window) {
      _lastFired = now;
      invalidate();
      return;
    }
    _pending = true;
    _timer ??= Timer(window, () {
      _timer = null;
      if (_pending) {
        _pending = false;
        _lastFired = DateTime.now();
        invalidate();
      }
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

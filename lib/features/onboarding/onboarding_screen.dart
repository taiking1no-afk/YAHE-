import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/ads/att_service.dart';
import '../../core/constants/app_colors.dart';
import '../notifications/notification_service.dart';

const _kOnboardingDone = 'onboarding_done_v1';
const _kMotivationKey = 'motivation_notif_enabled';
const _kQuietKey = 'quiet_notif_enabled';

Future<bool> isOnboardingDone() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kOnboardingDone) ?? false;
}

Future<void> markOnboardingDone() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kOnboardingDone, true);
}

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onFinish;
  const OnboardingScreen({super.key, required this.onFinish});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _pages = [
    _Page(
      emoji: '🚗',
      title: 'YAHEへようこそ',
      body: '改造車・スポーツカーオーナー同士が\n公道で「すれ違った瞬間」を記録する\nマッチングアプリです。',
    ),
    _Page(
      emoji: '⚡',
      title: 'すれ違いを検知',
      body:
          'アプリを起動したまま走ると\nBluetooth + GPSで近くのYAHEユーザーを検知。\nすれ違い時刻が記録されます（位置情報は近傍判定のために最新位置のみを一時利用し、他人には閲覧できません）。',
    ),
    _Page(
      emoji: '❤️',
      title: 'いいねしてマッチ',
      body: 'タイムラインで気になった車にいいね！\n相手もいいねしたら「マッチ成立」。\nそのままSNSで繋がれます。',
    ),
    _Page(
      emoji: '🛡️',
      title: 'プライバシーを守る',
      body: '自宅・職場周辺は「愛車ガード」で\nすれ違い記録をOFF。\n個人情報はマッチ後のみ相手に開示されます。',
    ),
    _Page(
      emoji: '🛞',
      title: '安全運転でお願いします',
      body: 'すれ違いの検知・記録は\nすべて自動で行われます。\n\n運転中は絶対にスマホを操作しないでください。\n確認は停車してから。',
    ),
    _Page(
      emoji: '🚀',
      title: '準備完了！',
      body: 'まず愛車を登録して、\nドライブに出かけよう！\nすれ違いを楽しんで。',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _pages.length - 1;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // スキップボタン
            if (!isLast)
              Align(
                alignment: Alignment.topRight,
                child: TextButton(
                  onPressed: _finish,
                  child: const Text('スキップ',
                      style: TextStyle(color: AppColors.textMuted)),
                ),
              )
            else
              const SizedBox(height: 40),

            // ページ本体
            Expanded(
              child: PageView.builder(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                itemCount: _pages.length,
                itemBuilder: (_, i) => _PageView(page: _pages[i]),
              ),
            ),

            // ドットインジケーター
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pages.length, (i) {
                final active = i == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: active ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: active ? AppColors.primary : AppColors.border,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
            const SizedBox(height: 32),

            // ボタン
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ElevatedButton(
                onPressed: isLast
                    ? _finish
                    : () => _controller.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        ),
                child: Text(isLast ? 'はじめる' : '次へ'),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Future<void> _finish() async {
    if (!mounted) return;

    // 権限周りのプラグインが端末依存の例外を投げても、チュートリアルが
    // 完了不能（無限ループ）にならないよう全体を保護する。
    try {
      await _runPermissionSteps();
    } catch (e) {
      debugPrint('[Onboarding] permission flow error: $e');
    }

    if (!mounted) return;
    await markOnboardingDone();
    widget.onFinish();
  }

  Future<void> _runPermissionSteps() async {
    // ── STEP 1: 位置情報 ──
    await _showPermissionStep(
      emoji: '📍',
      title: '位置情報の許可',
      body: 'すれ違いを検知するために位置情報を使用します。\n\n'
          'この機能は、アプリを閉じているときや使用していないときも、'
          'バックグラウンドで位置情報を取得して近くのユーザーとの'
          'すれ違いを記録します。\n\n'
          'iOSの場合は「常に許可」を、Androidの場合は「常に許可」'
          '（バックグラウンドでの位置情報の使用を許可）を選択してください。',
      buttonLabel: '続ける',
      onRequest: () async {
        final perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) {
          return false;
        }
        // iOSで「使用中のみ」が許可された場合、以前はここで「常に許可に
        // 変更してください」という追加のダイアログを表示してオンボーディングの
        // 続行をブロックしていた。ネイティブの許可ダイアログに答えた直後に
        // さらに別のダイアログで足止めされる形になり、App Store審査で
        // 「続けるを押しても何も起きない（先に進めない）」という不具合として
        // 却下された（Guideline 2.1(a)）。「常に許可」の案内は本文に既に
        // 含めてあり、未設定の場合はホーム画面のPermissionWarningBannerが
        // 後から非ブロッキングでリマインドするため、ここでは先に進める。
        return true;
      },
    );
    if (!mounted) return;

    // ── STEP 2: Bluetooth ──
    await _showPermissionStep(
      emoji: '📡',
      title: 'Bluetoothの許可',
      body: 'すれ違ったユーザーを正確に検知するために\nBluetoothが必要です。',
      buttonLabel: '続ける',
      onRequest: () async {
        if (defaultTargetPlatform == TargetPlatform.android) {
          final scan = await Permission.bluetoothScan.request();
          final advertise = await Permission.bluetoothAdvertise.request();
          final connect = await Permission.bluetoothConnect.request();
          return scan.isGranted && advertise.isGranted && connect.isGranted;
        } else {
          final status = await Permission.bluetooth.request();
          return status.isGranted || status.isLimited;
        }
      },
    );
    if (!mounted) return;

    // ── STEP 3: 通知 ──
    final prefs = await SharedPreferences.getInstance();
    final quietEnabled = prefs.getBool(_kQuietKey) ?? true;
    await NotificationService().initialize();

    final notifGranted = await _showPermissionStep(
      emoji: '🔔',
      title: '通知の許可',
      body: 'すれ違い通知やマッチ通知を受け取れます。\n\n'
          'ドライブに出たくなる定期通知もお届けします。\n'
          'あとから「設定」でいつでも変更できます。',
      buttonLabel: '続ける',
      onRequest: () async {
        return await NotificationService().requestPermission();
      },
    );
    if (!mounted) return;

    if (notifGranted) {
      await prefs.setBool(_kMotivationKey, true);
      await prefs.setBool(_kQuietKey, quietEnabled);
      await NotificationService().scheduleMotivationNotifications(
        quietEnabled: quietEnabled,
      );
    } else {
      await prefs.setBool(_kMotivationKey, false);
      await NotificationService().cancelAllMotivationNotifications();
    }

    // ── STEP 4: ATT（広告トラッキング・iOSのみ）──
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _showPermissionStep(
        emoji: '📣',
        title: 'トラッキングの許可',
        body: '無料プラン向けの広告を適切に表示するため、\n'
            'トラッキングの許可をお願いします。\n\n'
            '許可しなくても、すれ違い・いいね・マッチなど\n'
            'アプリの主要機能はすべて使えます。',
        buttonLabel: '次へ',
        onRequest: () async {
          await AttService.requestPermission();
          return true;
        },
      );
      if (!mounted) return;
    }
  }

  Future<bool> _showPermissionStep({
    required String emoji,
    required String title,
    required String body,
    required String buttonLabel,
    required Future<bool> Function() onRequest,
  }) async {
    // 既に許可済みの権限は onRequest() が即座に返るため、連打すると
    // 1回目の Navigator.pop でダイアログが閉じた後、2回目の pop が
    // ダイアログではなく OnboardingScreen 自体を pop してしまっていた。
    // このダイアログ呼び出し1回に対して一度しか処理しないようにガードする。
    var handled = false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 18))),
          ],
        ),
        content: Text(
          body,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
            height: 1.7,
          ),
        ),
        // Apple審査ガイドライン 5.1.1(iv): カスタムの事前案内画面を出した場合、
        // ユーザーは必ずOSの許可ダイアログへ進む必要がある。「後で」等でOSダイアログ
        // 自体をスキップできる導線は不可のため、ボタンは1つ（続ける）のみにする。
        actions: [
          ElevatedButton(
            onPressed: () async {
              if (handled) return;
              handled = true;
              // onRequest() が例外を投げる、あるいは端末依存の問題で
              // 応答が返らないまま固まると、Navigator.pop まで到達せず
              // ダイアログが「続ける」を押しても消えないまま残っていた。
              // 例外を拾い、一定時間で応答が無ければ「未許可」扱いで
              // 必ずダイアログを閉じて先へ進めるようにする。
              var granted = false;
              try {
                granted = await onRequest().timeout(
                  const Duration(seconds: 15),
                  onTimeout: () => false,
                );
              } catch (e) {
                debugPrint('[Onboarding] onRequest error: $e');
              }
              if (context.mounted) Navigator.pop(context, granted);
            },
            child: Text(buttonLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

class _PageView extends StatelessWidget {
  final _Page page;
  const _PageView({required this.page});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(page.emoji, style: const TextStyle(fontSize: 80)),
          const SizedBox(height: 32),
          Text(
            page.title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w800,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            page.body,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 15,
              height: 1.8,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _Page {
  final String emoji;
  final String title;
  final String body;
  const _Page({required this.emoji, required this.title, required this.body});
}

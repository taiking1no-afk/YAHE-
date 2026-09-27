import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../core/constants/app_colors.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../ble/background_encounter_service.dart';
import '../../debug/debug_screen.dart';
import '../../store/presentation/store_screen.dart';
import '../../store/presentation/plans_screen.dart';
import '../../legal/terms_screen.dart';
import '../../legal/contact_screen.dart';
import '../../notifications/notification_service.dart';
import '../../profile/data/user_repository.dart';
import '../../profile/presentation/profile_edit_screen.dart';
import 'data_subject_request_screen.dart';
import 'privacy_zone_screen.dart';
import 'block_list_screen.dart';

final _userRepoProvider = Provider<UserRepository>((ref) => UserRepository());

const _kMotivationKey = 'motivation_notif_enabled';
const _kQuietKey = 'quiet_notif_enabled';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _motivationEnabled = false;
  bool _quietEnabled = true;
  bool _bgDetectionEnabled = false;
  bool _prefsLoaded = false;

  // authNotifierProviderの再取得(ネットワーク往復)を待たずにスイッチを
  // 即座に反映するための楽観的更新用オーバーライド。失敗時のみnullに戻す。
  bool? _anonymousModeOverride;
  bool? _isPrivateOverride;

  Future<void> _setAnonymousMode(String userId, bool v) async {
    setState(() => _anonymousModeOverride = v);
    try {
      await ref.read(_userRepoProvider).setAnonymousMode(userId, v);
      ref.invalidate(authNotifierProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _anonymousModeOverride = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('設定の保存に失敗しました')));
    }
  }

  Future<void> _setPrivate(String userId, bool v) async {
    setState(() => _isPrivateOverride = v);
    try {
      await ref.read(_userRepoProvider).setPrivate(userId, v);
      ref.invalidate(authNotifierProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isPrivateOverride = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('設定の保存に失敗しました')));
    }
  }

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final bgEnabled = await BackgroundEncounterService.isEnabled();
    // 保存されている設定値だけを見ていたため、OS側の設定で通知を切られても
    // トグルはONのまま食い違っていた。実際のOS許可状態も確認し、既にOFFに
    // なっているなら合わせてローカル設定もOFFにする。
    var motivationEnabled = prefs.getBool(_kMotivationKey) ?? false;
    if (motivationEnabled) {
      final hasPermission = await NotificationService().hasPermission();
      if (!hasPermission) {
        motivationEnabled = false;
        await prefs.setBool(_kMotivationKey, false);
      }
    }
    setState(() {
      _motivationEnabled = motivationEnabled;
      _quietEnabled = prefs.getBool(_kQuietKey) ?? true;
      _bgDetectionEnabled = bgEnabled;
      _prefsLoaded = true;
    });
  }

  Future<void> _setMotivation(bool v) async {
    setState(() => _motivationEnabled = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kMotivationKey, v);

    if (!v) {
      await NotificationService().cancelAllMotivationNotifications();
      return;
    }

    // ON したときに、明示的に通知許可を取る（拒否時は設定/誘導）。
    // 権限リクエストが例外を投げる、あるいは端末依存の理由で応答が
    // 返らないまま固まると、スイッチがONのまま何も起きなくなっていた
    // （オンボーディングの許可ダイアログと同じ問題）ため、保護する。
    var granted = false;
    try {
      await NotificationService().initialize();
      granted = await NotificationService().requestPermission().timeout(
            const Duration(seconds: 15),
            onTimeout: () => false,
          );
    } catch (e) {
      debugPrint('[Settings] motivation permission error: $e');
    }
    if (!granted) {
      await prefs.setBool(_kMotivationKey, false);
      if (!mounted) return;
      setState(() => _motivationEnabled = false);

      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('通知の許可が必要です'),
          content: const Text(
            '通知が拒否されています。定期通知を受け取るには、設定で通知を有効にしてください。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                openAppSettings();
              },
              child: const Text('設定を開く'),
            ),
          ],
        ),
      );

      await NotificationService().cancelAllMotivationNotifications();
      return;
    }

    await NotificationService().scheduleMotivationNotifications(
      quietEnabled: _quietEnabled,
    );
  }

  Future<void> _setQuiet(bool v, String? userId) async {
    setState(() => _quietEnabled = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kQuietKey, v);
    if (userId != null) {
      final repo = ref.read(_userRepoProvider);
      await repo.setQuietHours(userId, v ? 23 : 0, v ? 6 : 0);
    }
    if (_motivationEnabled) {
      await NotificationService().scheduleMotivationNotifications(
        quietEnabled: v,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final userAsync = ref.watch(authNotifierProvider);
    final user = userAsync.value;
    final anonymousMode =
        _anonymousModeOverride ?? user?.anonymousMode ?? false;
    final isPrivate = _isPrivateOverride ?? user?.isPrivate ?? true;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _SectionHeader('プライバシー'),
          _SettingsTile(
            icon: Icons.shield_outlined,
            title: '愛車ガード',
            subtitle: 'プライバシーゾーンを設定',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PrivacyZoneScreen()),
            ),
          ),
          _SwitchTile(
            icon: Icons.person_off_outlined,
            title: '匿名モード',
            subtitle: 'ONにするとすれ違い対象から外れます',
            value: anonymousMode,
            onChanged:
                user == null ? null : (v) => _setAnonymousMode(user.userId, v),
          ),
          _SwitchTile(
            icon: Icons.lock_outline,
            title: '鍵アカウント',
            subtitle: 'OFFに「公開」表示になり、相手からマッチしてなくても交流ができるようになります。',
            value: isPrivate,
            onChanged: user == null ? null : (v) => _setPrivate(user.userId, v),
          ),
          _SectionHeader('バックグラウンド検知'),
          // バックグラウンド検知の説明バナー
          if (_bgDetectionEnabled)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.success.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.success.withOpacity(0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.sensors, color: AppColors.success, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'バックグラウンド検知が有効です。アプリを閉じていてもすれ違いを記録します。',
                      style: TextStyle(
                          color: AppColors.success, fontSize: 12, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          _SwitchTile(
            icon: Icons.sensors,
            title: 'バックグラウンド検知',
            subtitle: 'アプリを閉じていてもすれ違いを検知\n（電池消耗が増加します）',
            value: _bgDetectionEnabled,
            onChanged: user == null || !_prefsLoaded
                ? null
                : (v) async {
                    if (v) {
                      // 有効化前に警告ダイアログ
                      // ここから先の権限リクエストが例外を投げる、あるいは
                      // 端末依存の理由で応答が返らないまま固まると、スイッチが
                      // 反応しなくなっていた（オンボーディングの許可ダイアログと
                      // 同じ問題）ため、全体を保護する。
                      try {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          backgroundColor: AppColors.surface,
                          title: const Row(
                            children: [
                              Icon(Icons.battery_alert_outlined,
                                  color: AppColors.warning),
                              SizedBox(width: 8),
                              Expanded(child: Text('バックグラウンド検知')),
                            ],
                          ),
                          content: const Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('アプリを閉じていても常時すれ違いを検知します。'),
                              SizedBox(height: 12),
                              _WarningLine(text: '電池の消耗が通常より増加します。'),
                              SizedBox(height: 4),
                              _WarningLine(text: 'Androidでは常時通知が表示されます。'),
                              SizedBox(height: 4),
                              _WarningLine(
                                  text: 'iOSでは位置情報を「常に許可」に設定してください。'),
                              SizedBox(height: 12),
                              Text('有効にしますか？'),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('キャンセル'),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('有効にする'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true) return;

                      // 権限チェック（拒否時は設定/誘導）
                      final locationPerm = await Geolocator.requestPermission()
                          .timeout(const Duration(seconds: 15),
                              onTimeout: () => LocationPermission.denied);
                      final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
                      if (locationPerm == LocationPermission.denied ||
                          locationPerm ==
                              LocationPermission.unableToDetermine) {
                        await showDialog<void>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('位置情報が必要です'),
                            content: const Text(
                              'すれ違い検知には位置情報の許可が必要です。設定で許可してください。',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('OK'),
                              ),
                              ElevatedButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                  openAppSettings();
                                },
                                child: const Text('設定を開く'),
                              ),
                            ],
                          ),
                        );
                        return;
                      }
                      if (locationPerm == LocationPermission.deniedForever) {
                        await showDialog<void>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('位置情報が拒否されています'),
                            content: const Text(
                              '位置情報を「常に許可」にする必要があります。端末の設定で変更してください。',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('OK'),
                              ),
                              ElevatedButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                  openAppSettings();
                                },
                                child: const Text('設定を開く'),
                              ),
                            ],
                          ),
                        );
                        return;
                      }
                      if (isIOS && locationPerm != LocationPermission.always) {
                        await showDialog<void>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('「常に許可」が必要です'),
                            content: const Text(
                              'iOSではバックグラウンド検知のため、位置情報を「常に許可」に設定してください。',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('OK'),
                              ),
                              ElevatedButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                  openAppSettings();
                                },
                                child: const Text('設定を開く'),
                              ),
                            ],
                          ),
                        );
                        return;
                      }

                      if (defaultTargetPlatform == TargetPlatform.android) {
                        final btStatus = await Permission.bluetoothAdvertise
                            .request()
                            .timeout(const Duration(seconds: 15),
                                onTimeout: () => PermissionStatus.denied);
                        if (!btStatus.isGranted) {
                          await showDialog<void>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('Bluetooth の許可が必要です'),
                              content: const Text(
                                'すれ違い検知には Bluetooth 広告の許可が必要です。設定で許可してください。',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('OK'),
                                ),
                                ElevatedButton(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    openAppSettings();
                                  },
                                  child: const Text('設定を開く'),
                                ),
                              ],
                            ),
                          );
                          return;
                        }
                      }
                      } catch (e) {
                        debugPrint('[Settings] bg detection permission error: $e');
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('権限の確認に失敗しました。もう一度お試しください。')),
                          );
                        }
                        return;
                      }
                    }
                    setState(() => _bgDetectionEnabled = v);
                    await BackgroundEncounterService.setEnabled(
                      v,
                      userId: user.userId,
                      isPremium: user.isPremium,
                    );
                  },
          ),
          _SectionHeader('通知'),
          _SwitchTile(
            icon: Icons.notifications_outlined,
            title: 'おでかけ通知',
            subtitle: 'ドライブに出たくなる定期通知',
            value: _motivationEnabled,
            onChanged: _prefsLoaded ? (v) => _setMotivation(v) : null,
          ),
          _SwitchTile(
            icon: Icons.nights_stay_outlined,
            title: '深夜通知オフ',
            subtitle: '23:00〜6:00 は通知しない',
            value: _quietEnabled,
            onChanged: _prefsLoaded ? (v) => _setQuiet(v, user?.userId) : null,
          ),
          _SectionHeader('アカウント'),
          _SettingsTile(
            icon: Icons.edit_outlined,
            title: 'プロフィール編集',
            subtitle: 'ニックネーム・エリア・SNSリンク',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfileEditScreen()),
            ),
          ),
          _SettingsTile(
            icon: Icons.block,
            title: 'ブロックリスト',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BlockListScreen()),
            ),
          ),
          _SectionHeader('プラン・ストア'),
          if (user != null)
            _GearPlusTile(
              plan: user.effectivePlan,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PlansScreen()),
              ),
            ),
          // アイテム購入
          _SettingsTile(
            icon: Icons.storefront_outlined,
            title: 'ストア（アイテム購入）',
            subtitle: 'ニトロ・渋！などを購入',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const StoreScreen()),
            ),
          ),
          // プラン変更
          _SettingsTile(
            icon: Icons.workspace_premium,
            title: 'プランを見る / 変更',
            subtitle: 'Gear+ · Gear R',
            iconColor: AppColors.primary,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PlansScreen()),
            ),
          ),
          _SectionHeader('その他'),
          _SettingsTile(
            icon: Icons.description_outlined,
            title: '利用規約',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TermsScreen()),
            ),
          ),
          _SettingsTile(
            icon: Icons.privacy_tip_outlined,
            title: 'プライバシーポリシー',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
            ),
          ),
          _SettingsTile(
            icon: Icons.receipt_long_outlined,
            title: '特定商取引法に基づく表記',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const CommercialTransactionScreen()),
            ),
          ),
          _SettingsTile(
            icon: Icons.outbond_outlined,
            title: '外部送信について',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const ExternalTransmissionScreen()),
            ),
          ),
          _SettingsTile(
            icon: Icons.mail_outline,
            title: 'お問い合わせ',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ContactScreen()),
            ),
          ),
          _SettingsTile(
            icon: Icons.fact_check_outlined,
            title: '個人情報に関する請求',
            subtitle: '開示・訂正・利用停止・削除の請求',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const DataSubjectRequestScreen()),
            ),
          ),
          const SizedBox(height: 8),
          _SettingsTile(
            icon: Icons.logout,
            title: 'ログアウト',
            iconColor: AppColors.error,
            titleColor: AppColors.error,
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: AppColors.surface,
                  title: const Text('ログアウト'),
                  content: const Text('ログアウトしますか？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('キャンセル'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('ログアウト',
                          style: TextStyle(color: AppColors.error)),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                ref.read(authNotifierProvider.notifier).signOut();
              }
            },
          ),
          _SettingsTile(
            icon: Icons.delete_forever_outlined,
            title: 'アカウントを削除',
            subtitle: 'すべてのデータが完全に削除されます',
            iconColor: AppColors.error,
            titleColor: AppColors.error,
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: AppColors.surface,
                  title: const Text('アカウント削除'),
                  content: const Text(
                    'アカウントを削除すると、愛車情報・マッチ履歴・すれ違い履歴などすべてのデータが完全に削除されます。\n\nこの操作は取り消せません。',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('キャンセル'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('削除する',
                          style: TextStyle(
                              color: AppColors.error,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              );
              if (confirmed == true && user != null) {
                try {
                  final repo = ref.read(authRepositoryProvider);
                  final verified = await repo.deleteAccount();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(verified
                            ? 'アカウントを削除しました'
                            : 'アカウントの削除処理を実行しました（完了確認は取得できませんでした）'),
                      ),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('削除に失敗しました。もう一度お試しください。')),
                    );
                  }
                }
              }
            },
          ),
          // デバッグ専用メニュー（デバッグビルドのみ表示）
          if (kDebugMode) ...[
            _SectionHeader('開発・テスト'),
            _SettingsTile(
              icon: Icons.science_outlined,
              title: 'デバッグ / テスト画面',
              subtitle: '愛車ガード・すれ違いのテストができます',
              iconColor: AppColors.warning,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DebugScreen()),
              ),
            ),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Color? iconColor;
  final Color? titleColor;

  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.iconColor,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading:
          Icon(icon, color: iconColor ?? AppColors.textSecondary, size: 22),
      title: Text(title,
          style: TextStyle(
              color: titleColor ?? AppColors.textPrimary, fontSize: 15)),
      subtitle: subtitle != null
          ? Text(subtitle!,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12))
          : null,
      trailing: onTap != null
          ? const Icon(Icons.chevron_right,
              color: AppColors.textMuted, size: 18)
          : null,
      onTap: onTap,
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _SwitchTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: Icon(icon, color: AppColors.textSecondary, size: 22),
      title: Text(title,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 15)),
      subtitle: subtitle != null
          ? Text(subtitle!,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12))
          : null,
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeColor: AppColors.primary,
      ),
    );
  }
}

class _GearPlusTile extends StatelessWidget {
  final String plan;
  final VoidCallback onTap;

  const _GearPlusTile({required this.plan, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final (title, subtitle, accent) = switch (plan) {
      'gear_r' => ('Gear R 加入中', '認証バッジ・すべての特典', const Color(0xFF6C63FF)),
      'gear_plus' => ('Gear+ 加入中', 'いいね無制限・履歴7日間', const Color(0xFFFFD700)),
      'pit_in' => ('ピットイン加入中', '毎月ニトロ1個＋渋！10個をお届け', const Color(0xFFFF8C00)),
      _ => ('Gear+ にアップグレード', '月額¥500 · いいね無制限', AppColors.primary),
    };

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [accent.withOpacity(0.08), accent.withOpacity(0.04)],
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent, width: 1.5),
        ),
        child: ListTile(
          leading: Icon(Icons.workspace_premium, color: accent),
          title: Text(
            title,
            style: TextStyle(color: accent, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            subtitle,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          trailing: Icon(Icons.chevron_right, color: accent),
        ),
      ),
    );
  }
}

class _WarningLine extends StatelessWidget {
  final String text;
  const _WarningLine({required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(LucideIcons.alertTriangle,
            size: 15, color: AppColors.warning),
        const SizedBox(width: 6),
        Expanded(child: Text(text)),
      ],
    );
  }
}

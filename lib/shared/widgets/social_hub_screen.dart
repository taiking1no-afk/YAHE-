import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/likes/presentation/likes_screen.dart';
import '../../features/match/presentation/match_screen.dart';
import '../providers/tab_provider.dart';
import 'notification_bell_button.dart';
import 'yahe_app_bar.dart';

/// 「YAHE・いいね・マッチ」をまとめたタブページ。
class SocialHubScreen extends ConsumerStatefulWidget {
  const SocialHubScreen({super.key});

  @override
  ConsumerState<SocialHubScreen> createState() => _SocialHubScreenState();
}

class _SocialHubScreenState extends ConsumerState<SocialHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TabController(
      length: 3,
      vsync: this,
      initialIndex: ref.read(socialHubSubTabProvider),
    );
    _controller.addListener(() {
      if (!_controller.indexIsChanging) {
        ref.read(socialHubSubTabProvider.notifier).state = _controller.index;
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 外部（ポップアップの「マッチを見る」等）からの指定に追従する
    ref.listen<int>(socialHubSubTabProvider, (previous, next) {
      if (_controller.index != next) _controller.animateTo(next);
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: YaheAppBar(
        showBack: false,
        actions: const [NotificationBellButton()],
        bottom: TabBar(
          controller: _controller,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textMuted,
          indicatorColor: AppColors.primary,
          dividerColor: AppColors.border,
          tabs: const [Tab(text: 'YAHE'), Tab(text: 'いいね'), Tab(text: 'マッチ')],
        ),
      ),
      body: TabBarView(
        controller: _controller,
        children: const [
          HomeScreen(embedded: true),
          LikesScreen(embedded: true),
          MatchScreen(embedded: true),
        ],
      ),
    );
  }
}

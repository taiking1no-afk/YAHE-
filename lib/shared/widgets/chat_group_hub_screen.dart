import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../features/chat/presentation/chat_thread_list_screen.dart';
import '../../features/groups/presentation/group_list_screen.dart';
import '../providers/tab_provider.dart';
import 'notification_bell_button.dart';
import 'yahe_app_bar.dart';

/// 「チャット・グループ」をまとめたタブページ。
class ChatGroupHubScreen extends ConsumerStatefulWidget {
  const ChatGroupHubScreen({super.key});

  @override
  ConsumerState<ChatGroupHubScreen> createState() => _ChatGroupHubScreenState();
}

class _ChatGroupHubScreenState extends ConsumerState<ChatGroupHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TabController(
      length: 2,
      vsync: this,
      initialIndex: ref.read(chatGroupHubSubTabProvider),
    );
    _controller.addListener(() {
      if (!_controller.indexIsChanging) {
        ref.read(chatGroupHubSubTabProvider.notifier).state = _controller.index;
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
    ref.listen<int>(chatGroupHubSubTabProvider, (previous, next) {
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
          tabs: const [Tab(text: 'チャット'), Tab(text: 'グループ')],
        ),
      ),
      body: TabBarView(
        controller: _controller,
        children: const [
          ChatThreadListScreen(embedded: true),
          GroupListScreen(embedded: true),
        ],
      ),
    );
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// ボトムナビのタブインデックスを管理
/// 0: YAHE/いいね/マッチ（まとまり）, 1: チャット/グループ（まとまり）,
/// 2: 掲示板, 3: プロフィール（マイカーは下部から遷移）
final selectedTabProvider = StateProvider<int>((ref) => 0);

/// 0のタブ内（YAHE/いいね/マッチ）で、どのサブタブを表示するか。
/// SocialHubScreen の TabController と同期する。
/// 0: YAHE, 1: いいね, 2: マッチ
final socialHubSubTabProvider = StateProvider<int>((ref) => 0);

/// 1のタブ内（チャット/グループ）で、どのサブタブを表示するか。
/// 0: チャット, 1: グループ
final chatGroupHubSubTabProvider = StateProvider<int>((ref) => 0);

/// 「YAHE/いいね/マッチ」まとまりタブの、指定したサブタブへ遷移する
void goToSocialSubTab(WidgetRef ref, int subTab) {
  ref.read(selectedTabProvider.notifier).state = 0;
  ref.read(socialHubSubTabProvider.notifier).state = subTab;
}

/// 「チャット/グループ」まとまりタブの、指定したサブタブへ遷移する
void goToChatGroupSubTab(WidgetRef ref, int subTab) {
  ref.read(selectedTabProvider.notifier).state = 1;
  ref.read(chatGroupHubSubTabProvider.notifier).state = subTab;
}

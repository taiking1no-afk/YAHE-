import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:intl/intl.dart';
import '../../../core/constants/app_colors.dart';
import '../../../features/ads/banner_ad_widget.dart';
import '../../../shared/widgets/ad_grid_helper.dart';
import '../../../shared/widgets/error_view.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../match/data/match_repository.dart';
import '../../match/presentation/match_detail_screen.dart';
import '../data/chat_prefs.dart';
import '../data/chat_prefs_provider.dart';
import '../data/chat_repository.dart';
import '../models/chat_thread_model.dart';
import 'chat_room_screen.dart';

final chatRepositoryProvider =
    Provider<ChatRepository>((ref) => ChatRepository());

final chatThreadListProvider =
    FutureProvider.autoDispose<List<ChatThreadModel>>((ref) async {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return [];
  return ref.watch(chatRepositoryProvider).fetchThreadList(user.userId);
});

String _dmPrefKey(String matchId) => 'dm:$matchId';

class ChatThreadListScreen extends ConsumerStatefulWidget {
  /// 統合タブ（ChatGroupHubScreen）内に埋め込む場合はtrue。
  final bool embedded;
  const ChatThreadListScreen({super.key, this.embedded = false});

  @override
  ConsumerState<ChatThreadListScreen> createState() =>
      _ChatThreadListScreenState();
}

class _ChatThreadListScreenState extends ConsumerState<ChatThreadListScreen> {
  Set<String> _pinned = {};
  Set<String> _muted = {};
  Map<String, DateTime> _hiddenAt = {};
  bool _prefsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final pinned = await ChatPrefs.pinnedIds();
    final muted = await ChatPrefs.mutedIds();
    final hiddenAt = await ChatPrefs.hiddenAt();
    if (mounted) {
      setState(() {
        _pinned = pinned;
        _muted = muted;
        _hiddenAt = hiddenAt;
        _prefsLoaded = true;
      });
    }
  }

  Future<void> _togglePin(ChatThreadModel t) async {
    final key = _dmPrefKey(t.matchId);
    final next = !_pinned.contains(key);
    await ChatPrefs.setPinned(key, next);
    setState(() => next ? _pinned.add(key) : _pinned.remove(key));
  }

  Future<void> _toggleMute(ChatThreadModel t) async {
    final key = _dmPrefKey(t.matchId);
    final next = !_muted.contains(key);
    await ChatPrefs.setMuted(key, next);
    setState(() => next ? _muted.add(key) : _muted.remove(key));
    ref.invalidate(mutedChatIdsProvider);
  }

  Future<void> _hideThread(ChatThreadModel t) async {
    final key = _dmPrefKey(t.matchId);
    await ChatPrefs.hide(key);
    setState(() => _hiddenAt[key] = DateTime.now().toUtc());
  }

  @override
  Widget build(BuildContext context) {
    final threadsAsync = ref.watch(chatThreadListProvider);

    final body = threadsAsync.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
      error: (e, _) => ErrorView(
          message: '読み込みに失敗しました',
          onRetry: () => ref.invalidate(chatThreadListProvider)),
      data: (threads) {
        if (threads.isEmpty) {
          return const Center(
            child: Text('マッチするとここにチャットが表示されます',
                style: TextStyle(color: AppColors.textMuted)),
          );
        }
        if (!_prefsLoaded) {
          return const Center(
              child: CircularProgressIndicator(color: AppColors.primary));
        }

        Future<void> openThread(ChatThreadModel t) async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatRoomScreen(
                matchId: t.matchId,
                otherUserId: t.otherUserId,
                otherNickname: t.otherNickname ?? '名無し',
              ),
            ),
          );
          final key = _dmPrefKey(t.matchId);
          if (_hiddenAt.containsKey(key)) {
            await ChatPrefs.unhide(key);
            setState(() => _hiddenAt.remove(key));
          }
          ref.invalidate(chatThreadListProvider);
        }

        Future<void> openProfile(ChatThreadModel t) async {
          final myId = ref.read(authNotifierProvider).value?.userId;
          if (myId == null) return;
          final match = await MatchRepository().fetchMatch(t.matchId, myId);
          if (match == null || !context.mounted) return;
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => MatchDetailScreen(match: match)));
        }

        // まだメッセージのやり取りがない（threadId未作成）＝新規マッチ
        final newMatches = threads.where((t) => t.threadId == null).toList();
        final activeThreads = threads.where((t) => t.threadId != null).toList();

        // 削除（非表示）されたスレッドは、削除した時刻より後に新着メッセージ
        // （自分・相手どちらの送信でも）があれば一覧に戻す。
        final visibleActive = activeThreads.where((t) {
          final hiddenSince = _hiddenAt[_dmPrefKey(t.matchId)];
          if (hiddenSince == null) return true;
          final lastMessageAt = t.lastMessageAt;
          return lastMessageAt != null && lastMessageAt.isAfter(hiddenSince);
        }).toList();

        // ピン留めを先頭に（元の並び順=更新日時降順は維持したまま安定ソート）
        final indexed = visibleActive.asMap().entries.toList()
          ..sort((a, b) {
            final aPinned = _pinned.contains(_dmPrefKey(a.value.matchId));
            final bPinned = _pinned.contains(_dmPrefKey(b.value.matchId));
            if (aPinned != bPinned) return aPinned ? -1 : 1;
            return a.key.compareTo(b.key);
          });
        final sortedActive = indexed.map((e) => e.value).toList();
        // 他画面(home/likes/match)はisPremiumで広告表示をガードしているのに
        // ここだけ漏れており、課金ユーザーにもチャット一覧に広告が出ていた。
        final isPremium =
            ref.watch(authNotifierProvider).value?.isPremium ?? false;
        final items = isPremium
            ? sortedActive
            : interleaveItemsWithAds<ChatThreadModel>(sortedActive);

        return ListView(
          children: [
            if (newMatches.isNotEmpty)
              _NewMatchesStrip(matches: newMatches, onTap: openThread),
            if (sortedActive.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Text('マッチした人にチャットを送ろう！',
                      style: TextStyle(color: AppColors.textMuted)),
                ),
              )
            else
              ...List.generate(items.length * 2 - 1, (idx) {
                if (idx.isOdd)
                  return const Divider(
                      height: 1, color: AppColors.border, indent: 72);
                final item = items[idx ~/ 2];
                if (item == 'ad') return const InlineBannerAdCard();
                final t = item as ChatThreadModel;
                final key = _dmPrefKey(t.matchId);
                final isPinned = _pinned.contains(key);
                final isMuted = _muted.contains(key);

                return Slidable(
                  key: ValueKey(t.matchId),
                  endActionPane: ActionPane(
                    motion: const ScrollMotion(),
                    extentRatio: 0.75,
                    children: [
                      SlidableAction(
                        onPressed: (_) => _togglePin(t),
                        backgroundColor: AppColors.warning,
                        foregroundColor: Colors.white,
                        icon:
                            isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                        label: isPinned ? '解除' : 'ピン留め',
                      ),
                      SlidableAction(
                        onPressed: (_) => _toggleMute(t),
                        backgroundColor: AppColors.textMuted,
                        foregroundColor: Colors.white,
                        icon: isMuted
                            ? Icons.notifications
                            : Icons.notifications_off,
                        label: isMuted ? '解除' : 'ミュート',
                      ),
                      SlidableAction(
                        onPressed: (_) => _hideThread(t),
                        backgroundColor: AppColors.error,
                        foregroundColor: Colors.white,
                        icon: Icons.delete_outline,
                        label: '削除',
                      ),
                    ],
                  ),
                  child: ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: GestureDetector(
                      onTap: () => openProfile(t),
                      child: _ThreadAvatar(
                          url: t.otherAvatarUrl, nickname: t.otherNickname),
                    ),
                    title: Row(
                      children: [
                        if (isPinned) ...[
                          const Icon(Icons.push_pin,
                              size: 13, color: AppColors.warning),
                          const SizedBox(width: 4),
                        ],
                        Flexible(
                          child: Text(t.otherNickname ?? '名無し',
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                        if (isMuted) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.notifications_off,
                              size: 13, color: AppColors.textMuted),
                        ],
                        if (t.isDissolved) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppColors.textMuted.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('マッチ解消済み',
                                style: TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      t.lastMessagePreview ?? 'まだメッセージがありません',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 13),
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (t.lastMessageAt != null)
                          Text(DateFormat('M/d HH:mm').format(t.lastMessageAt!),
                              style: const TextStyle(
                                  color: AppColors.textMuted, fontSize: 11)),
                        if (t.unreadCount > 0 && !isMuted) ...[
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: const BoxDecoration(
                                color: AppColors.primary,
                                shape: BoxShape.circle),
                            constraints: const BoxConstraints(minWidth: 18),
                            child: Text(
                              '${t.unreadCount}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ],
                    ),
                    onTap: () => openThread(t),
                  ),
                );
              }),
          ],
        );
      },
    );

    if (widget.embedded) return body;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const YaheAppBar(title: 'チャット'),
      body: body,
    );
  }
}

/// まだチャットを始めていない新規マッチを横スクロールで見せる「送ろう」導線。
class _NewMatchesStrip extends StatelessWidget {
  final List<ChatThreadModel> matches;
  final ValueChanged<ChatThreadModel> onTap;
  const _NewMatchesStrip({required this.matches, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.only(top: 12, bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '新しいマッチ・チャットを送ろう！',
              style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: matches.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (context, i) {
                final m = matches[i];
                return GestureDetector(
                  onTap: () => onTap(m),
                  child: SizedBox(
                    width: 64,
                    child: Column(
                      children: [
                        _ThreadAvatar(
                            url: m.otherAvatarUrl,
                            nickname: m.otherNickname,
                            radius: 28),
                        const SizedBox(height: 6),
                        Text(
                          m.otherNickname ?? '名無し',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreadAvatar extends StatelessWidget {
  final String? url;
  final String? nickname;
  final double radius;
  const _ThreadAvatar({this.url, this.nickname, this.radius = 24});

  @override
  Widget build(BuildContext context) {
    if (url != null && url!.isNotEmpty) {
      return ClipOval(
        child: SignedStorageImage(
          storedReference: url!,
          defaultBucket: 'profile-photos',
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          placeholder: _initials(),
        ),
      );
    }
    return _initials();
  }

  Widget _initials() => CircleAvatar(
        radius: radius,
        backgroundColor: AppColors.primary.withOpacity(0.15),
        child: Text(
          (nickname != null && nickname!.isNotEmpty)
              ? nickname!.substring(0, 1).toUpperCase()
              : 'U',
          style: TextStyle(
              color: AppColors.primary,
              fontSize: radius * 0.55,
              fontWeight: FontWeight.w800),
        ),
      );
}

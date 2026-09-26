import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/constants/app_colors.dart';
import '../../../features/ads/banner_ad_widget.dart';
import '../../../shared/widgets/ad_grid_helper.dart';
import '../../../shared/widgets/error_view.dart';
import '../../../shared/widgets/notification_bell_button.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../chat/data/chat_prefs.dart';
import '../data/board_repository.dart';
import '../models/board_post_model.dart';
import '../utils/prefecture_match.dart';
import 'board_calendar_screen.dart';
import 'board_detail_screen.dart';
import 'create_board_post_screen.dart';

final _boardRepoProvider =
    Provider<BoardRepository>((ref) => BoardRepository());

final boardFilterProvider =
    StateProvider.autoDispose<BoardPostType?>((ref) => null);

final boardSearchQueryProvider = StateProvider.autoDispose<String>((ref) => '');

final boardMyOrganizedOnlyProvider =
    StateProvider.autoDispose<bool>((ref) => false);

final boardInterestedOnlyProvider =
    StateProvider.autoDispose<bool>((ref) => false);

final boardJoinedOnlyProvider = StateProvider.autoDispose<bool>((ref) => false);

enum BoardSortMode { dateAsc, dateDesc, newest, mostInterested, mostJoined }

extension BoardSortModeX on BoardSortMode {
  String get label => switch (this) {
        BoardSortMode.dateAsc => '開催日が早い順',
        BoardSortMode.dateDesc => '開催日が遅い順',
        BoardSortMode.newest => '新着順',
        BoardSortMode.mostInterested => '気になるが多い順',
        BoardSortMode.mostJoined => '参加者が多い順',
      };
}

final boardSortModeProvider =
    StateProvider.autoDispose<BoardSortMode>((ref) => BoardSortMode.dateAsc);

int _modeComparator(BoardPostModel a, BoardPostModel b, BoardSortMode mode) {
  switch (mode) {
    case BoardSortMode.dateAsc:
      if (a.scheduledAt == null) return 1;
      if (b.scheduledAt == null) return -1;
      return a.scheduledAt!.compareTo(b.scheduledAt!);
    case BoardSortMode.dateDesc:
      if (a.scheduledAt == null) return 1;
      if (b.scheduledAt == null) return -1;
      return b.scheduledAt!.compareTo(a.scheduledAt!);
    case BoardSortMode.newest:
      return b.createdAt.compareTo(a.createdAt);
    case BoardSortMode.mostInterested:
      return b.interestedCount.compareTo(a.interestedCount);
    case BoardSortMode.mostJoined:
      return b.joinedCount.compareTo(a.joinedCount);
  }
}

List<BoardPostModel> _sortPosts(
    List<BoardPostModel> posts, BoardSortMode mode) {
  final sorted = List<BoardPostModel>.of(posts);
  // 終了済みの募集はソート順に関わらず常に最下部へ沈める。
  sorted.sort((a, b) {
    if (a.isEnded != b.isEnded) return a.isEnded ? 1 : -1;
    return _modeComparator(a, b, mode);
  });
  return sorted;
}

final boardPostsProvider =
    FutureProvider.autoDispose<List<BoardPostModel>>((ref) {
  final filter = ref.watch(boardFilterProvider);
  final query = ref.watch(boardSearchQueryProvider);
  final myUserId = ref.watch(authNotifierProvider).value?.userId;
  return ref
      .watch(_boardRepoProvider)
      .fetchPosts(postType: filter, searchQuery: query, myUserId: myUserId);
});

/// 自分が主催する募集ごとの参加申請(pending)件数（一覧のバッジ表示・下タブのバッジ用）。
final boardMyOrganizedPendingCountsProvider =
    FutureProvider.autoDispose<Map<String, int>>((ref) {
  final myUserId = ref.watch(authNotifierProvider).value?.userId;
  if (myUserId == null) return Future.value(const {});
  return ref.watch(_boardRepoProvider).fetchMyOrganizedPendingCounts(myUserId);
});

class BoardListScreen extends ConsumerStatefulWidget {
  const BoardListScreen({super.key});

  @override
  ConsumerState<BoardListScreen> createState() => _BoardListScreenState();
}

class _BoardListScreenState extends ConsumerState<BoardListScreen> {
  static const _recommendedSectionKey = 'board_recommended_section';
  bool _recommendedCollapsed = false;
  bool _prefsLoaded = false;
  // タップした瞬間にハートの見た目を反映する（サーバーの再取得を待たない）。
  // ref.invalidate()後の再フェッチがネットワーク状況によっては遅延することがあり、
  // 画面を切り替えるまで反映されないように見えてしまうのを防ぐ。
  final Map<String, bool> _interestOverrides = {};

  List<BoardPostModel> _applyOverrides(List<BoardPostModel> posts) {
    if (_interestOverrides.isEmpty) return posts;
    return posts.map((p) {
      final override = _interestOverrides[p.postId];
      if (override == null || override == p.isInterestedByMe) return p;
      return p.copyWithCounts(
        joinedCount: p.joinedCount,
        interestedCount:
            (p.interestedCount + (override ? 1 : -1)).clamp(0, 1 << 30),
        isInterestedByMe: override,
        isJoinedByMe: p.isJoinedByMe,
      );
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final collapsedSections = await ChatPrefs.collapsedSections();
    if (mounted) {
      setState(() {
        _recommendedCollapsed =
            collapsedSections.contains(_recommendedSectionKey);
        _prefsLoaded = true;
      });
    }
  }

  Future<void> _toggleRecommendedCollapsed() async {
    final next = !_recommendedCollapsed;
    await ChatPrefs.setSectionCollapsed(_recommendedSectionKey, next);
    setState(() => _recommendedCollapsed = next);
  }

  @override
  Widget build(BuildContext context) {
    final postsAsync = ref.watch(boardPostsProvider);
    final filter = ref.watch(boardFilterProvider);
    final myArea = ref.watch(authNotifierProvider).value?.area;
    final myUserId = ref.watch(authNotifierProvider).value?.userId;
    final pendingCounts =
        ref.watch(boardMyOrganizedPendingCountsProvider).value ??
            const <String, int>{};
    final organizedOnly = ref.watch(boardMyOrganizedOnlyProvider);
    final interestedOnly = ref.watch(boardInterestedOnlyProvider);
    final joinedOnly = ref.watch(boardJoinedOnlyProvider);
    final sortMode = ref.watch(boardSortModeProvider);

    Future<void> createPost() async {
      final created = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const CreateBoardPostScreen()),
      );
      if (created == true) ref.invalidate(boardPostsProvider);
    }

    Future<void> toggleInterest(BoardPostModel post) async {
      final next = !post.isInterestedByMe;
      setState(() => _interestOverrides[post.postId] = next);
      try {
        if (post.isInterestedByMe) {
          await BoardRepository().cancelInterest(post.postId);
        } else {
          await BoardRepository().expressInterest(post.postId);
        }
        ref.invalidate(boardPostsProvider);
      } catch (e) {
        if (mounted) setState(() => _interestOverrides.remove(post.postId));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('失敗しました: $e')),
          );
        }
      }
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: YaheAppBar(
        title: '掲示板',
        actions: [
          const NotificationBellButton(),
          PopupMenuButton<BoardSortMode>(
            icon: const Icon(Icons.sort),
            tooltip: '並べ替え',
            initialValue: sortMode,
            onSelected: (m) =>
                ref.read(boardSortModeProvider.notifier).state = m,
            itemBuilder: (context) => [
              for (final m in BoardSortMode.values)
                PopupMenuItem(
                  value: m,
                  child: Row(
                    children: [
                      if (m == sortMode)
                        const Icon(Icons.check,
                            size: 16, color: AppColors.primary)
                      else
                        const SizedBox(width: 16),
                      const SizedBox(width: 8),
                      Text(m.label),
                    ],
                  ),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.calendar_month_outlined),
            tooltip: '開催カレンダー',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BoardCalendarScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_prefsLoaded && myArea != null && myArea.isNotEmpty)
            postsAsync.maybeWhen(
              data: (posts) {
                final recommended = posts
                    .where((p) =>
                        !p.isEnded && prefectureMatches(myArea, p.prefecture))
                    .toList();
                if (recommended.isEmpty) return const SizedBox.shrink();
                return _RecommendedStrip(
                  area: myArea,
                  posts: recommended,
                  collapsed: _recommendedCollapsed,
                  onToggleCollapsed: _toggleRecommendedCollapsed,
                );
              },
              orElse: () => const SizedBox.shrink(),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: '掲示板を検索',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (v) =>
                        ref.read(boardSearchQueryProvider.notifier).state = v,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: const Icon(Icons.add),
                  tooltip: '投稿する',
                  onPressed: createPost,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('すべて'),
                    selected: filter == null,
                    onSelected: (_) =>
                        ref.read(boardFilterProvider.notifier).state = null,
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('ツーリング'),
                    selected: filter == BoardPostType.touring,
                    onSelected: (_) => ref
                        .read(boardFilterProvider.notifier)
                        .state = BoardPostType.touring,
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('イベント'),
                    selected: filter == BoardPostType.event,
                    onSelected: (_) => ref
                        .read(boardFilterProvider.notifier)
                        .state = BoardPostType.event,
                  ),
                  const SizedBox(width: 12),
                  Container(width: 1, height: 24, color: AppColors.border),
                  const SizedBox(width: 12),
                  FilterChip(
                    label: const Text('参加予定のみ'),
                    avatar: const Icon(Icons.event_available,
                        size: 16, color: AppColors.success),
                    selected: joinedOnly,
                    onSelected: (v) =>
                        ref.read(boardJoinedOnlyProvider.notifier).state = v,
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('自分の主催のみ'),
                    avatar: const Icon(Icons.person_outline, size: 16),
                    selected: organizedOnly,
                    onSelected: (v) => ref
                        .read(boardMyOrganizedOnlyProvider.notifier)
                        .state = v,
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('気になるのみ'),
                    avatar: const Icon(Icons.favorite,
                        size: 16, color: Colors.pink),
                    selected: interestedOnly,
                    onSelected: (v) => ref
                        .read(boardInterestedOnlyProvider.notifier)
                        .state = v,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: postsAsync.hasValue
                // 更新中(invalidate直後)も直前のデータを表示し続け、画面全体が
                // ローディング表示に差し替わって広告位置が動くのを防ぐ。
                ? _BoardPostsList(
                    allPosts: _applyOverrides(postsAsync.value!),
                    organizedOnly: organizedOnly,
                    interestedOnly: interestedOnly,
                    joinedOnly: joinedOnly,
                    myUserId: myUserId,
                    pendingCounts: pendingCounts,
                    sortMode: sortMode,
                    onToggleInterest: toggleInterest,
                  )
                : postsAsync.when(
                    loading: () => const Center(
                        child: CircularProgressIndicator(
                            color: AppColors.primary)),
                    error: (e, _) => ErrorView(
                        message: '読み込みに失敗しました',
                        onRetry: () => ref.invalidate(boardPostsProvider)),
                    data: (_) => const SizedBox.shrink(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _BoardPostsList extends StatelessWidget {
  final List<BoardPostModel> allPosts;
  final bool organizedOnly;
  final bool interestedOnly;
  final bool joinedOnly;
  final String? myUserId;
  final Map<String, int> pendingCounts;
  final BoardSortMode sortMode;
  final ValueChanged<BoardPostModel> onToggleInterest;

  const _BoardPostsList({
    required this.allPosts,
    required this.organizedOnly,
    required this.interestedOnly,
    required this.joinedOnly,
    required this.myUserId,
    required this.pendingCounts,
    required this.sortMode,
    required this.onToggleInterest,
  });

  @override
  Widget build(BuildContext context) {
    var posts = allPosts;
    if (organizedOnly && myUserId != null) {
      posts = posts.where((p) => p.organizerId == myUserId).toList();
    }
    if (interestedOnly) {
      posts = posts.where((p) => p.isInterestedByMe).toList();
    }
    if (joinedOnly) {
      // 「参加予定」なので、既に終了したものは対象外にする
      posts = posts.where((p) => p.isJoinedByMe && !p.isEnded).toList();
    }
    if (posts.isEmpty) {
      return const Center(
          child:
              Text('募集はまだありません', style: TextStyle(color: AppColors.textMuted)));
    }
    posts = _sortPosts(posts, sortMode);
    final items = interleaveItemsWithAds<BoardPostModel>(posts);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final item = items[i];
        if (item == 'ad') return const InlineBannerAdCard();
        final post = item as BoardPostModel;
        return _BoardPostCard(
          post: post,
          pendingCount: post.organizerId == myUserId
              ? (pendingCounts[post.postId] ?? 0)
              : 0,
          // 参加/招待ボタンは終了時に無効化されているのに、こちらは
          // チェックが漏れており終了後も「気になる」を切り替えられていた。
          onToggleInterest: post.isEnded ? null : () => onToggleInterest(post),
        );
      },
    );
  }
}

class _RecommendedStrip extends StatelessWidget {
  final String area;
  final List<BoardPostModel> posts;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;
  const _RecommendedStrip({
    required this.area,
    required this.posts,
    required this.collapsed,
    required this.onToggleCollapsed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: EdgeInsets.only(top: 12, bottom: collapsed ? 12 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggleCollapsed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '$area のおすすめ',
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                  Icon(
                    collapsed ? Icons.expand_more : Icons.expand_less,
                    size: 20,
                    color: AppColors.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: posts.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final p = posts[i];
                  return GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => BoardDetailScreen(postId: p.postId)),
                    ),
                    child: Container(
                      width: 180,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.postType.label,
                            style: const TextStyle(
                                color: AppColors.primary,
                                fontSize: 10,
                                fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            p.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          if (p.scheduledAt != null)
                            Text(
                              DateFormat('M月d日').format(p.scheduledAt!),
                              style: const TextStyle(
                                  color: AppColors.textMuted, fontSize: 11),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BoardPostCard extends StatelessWidget {
  final BoardPostModel post;
  final int pendingCount;
  final VoidCallback? onToggleInterest;
  const _BoardPostCard(
      {required this.post,
      this.pendingCount = 0,
      required this.onToggleInterest});

  @override
  Widget build(BuildContext context) {
    final capacityLabel = post.capacity != null
        ? '${post.joinedCount} / ${post.capacity}人'
        : '${post.joinedCount}人参加';
    return Stack(
      children: [
        _buildCard(context, capacityLabel),
        // ハートボタンはカード全体のInkWellと兄弟(Stack上の別レイヤー)にすることで、
        // ネストしたタップ領域同士の競合を避け、確実にタップを拾えるようにする。
        Positioned(
          top: 6,
          right: 6,
          child: IconButton(
            onPressed: onToggleInterest,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            icon: Icon(
              post.isInterestedByMe ? Icons.favorite : Icons.favorite_border,
              size: 20,
              color: post.isInterestedByMe ? Colors.pink : AppColors.textMuted,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCard(BuildContext context, String capacityLabel) {
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => BoardDetailScreen(postId: post.postId)),
      ),
      child: Opacity(
        opacity: post.isEnded ? 0.55 : 1.0,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 40),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: (post.postType == BoardPostType.touring
                                ? AppColors.tagEngine
                                : AppColors.tagAero)
                            .withOpacity(0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        post.postType.label,
                        style: TextStyle(
                          color: post.postType == BoardPostType.touring
                              ? AppColors.tagEngine
                              : AppColors.tagAero,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (post.mode != null)
                      Text(post.mode!.label,
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 11)),
                    if (post.isEnded)
                      _StatusBadge(
                        label: post.daysUntilAutoDelete != null
                            ? '終了（あと${post.daysUntilAutoDelete}日で削除）'
                            : '終了',
                        color: AppColors.textMuted,
                      )
                    else if (post.isFull)
                      _StatusBadge(label: '締め切り', color: AppColors.error),
                    if (post.isJoinedByMe)
                      _StatusBadge(label: '参加予定', color: AppColors.success),
                    if (pendingCount > 0)
                      _StatusBadge(
                          label: '参加希望者がいます ($pendingCount)',
                          color: AppColors.warning),
                    Text(_visibilityLabel(post.visibility),
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 11)),
                  ],
                ),
              ),
              if (post.imagePath != null && post.imagePath!.isNotEmpty) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SignedStorageImage(
                    storedReference: post.imagePath!,
                    defaultBucket: 'board-photos',
                    width: double.infinity,
                    height: 120,
                    fit: BoxFit.cover,
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text(post.title,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (post.scheduledAt != null) ...[
                    const Icon(Icons.event,
                        size: 13, color: AppColors.textMuted),
                    const SizedBox(width: 4),
                    Text(DateFormat('M月d日 HH:mm').format(post.scheduledAt!),
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 12)),
                    const SizedBox(width: 12),
                  ],
                  const Icon(Icons.people_outline,
                      size: 13, color: AppColors.textMuted),
                  const SizedBox(width: 4),
                  Text(capacityLabel,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 12)),
                  if (post.interestedCount > 0) ...[
                    const SizedBox(width: 12),
                    Text('興味あり ${post.interestedCount}人',
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 12)),
                  ],
                ],
              ),
              if (_locationLabel(post) != null) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.place_outlined,
                        size: 13, color: AppColors.textMuted),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _locationLabel(post)!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String? _locationLabel(BoardPostModel post) {
    final place = post.meetingPlaceText?.trim();
    final prefecture = post.prefecture?.trim();
    if (place != null &&
        place.isNotEmpty &&
        prefecture != null &&
        prefecture.isNotEmpty) {
      return '$prefecture ・ $place';
    }
    if (place != null && place.isNotEmpty) return place;
    if (prefecture != null && prefecture.isNotEmpty) return prefecture;
    return null;
  }

  String _visibilityLabel(BoardVisibility v) => v.label;
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }
}

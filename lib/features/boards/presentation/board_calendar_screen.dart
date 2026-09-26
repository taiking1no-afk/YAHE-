import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import '../../../core/constants/app_colors.dart';
import '../../../shared/widgets/error_view.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../../auth/presentation/auth_provider.dart';
import '../data/board_repository.dart';
import '../models/board_post_model.dart';
import '../utils/prefecture_match.dart';
import 'board_detail_screen.dart';

final _calendarBoardRepoProvider =
    Provider<BoardRepository>((ref) => BoardRepository());

final allBoardPostsProvider =
    FutureProvider.autoDispose<List<BoardPostModel>>((ref) {
  return ref.watch(_calendarBoardRepoProvider).fetchPosts();
});

final myParticipatedBoardPostsProvider =
    FutureProvider.autoDispose<List<BoardPostModel>>((ref) {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return Future.value(const []);
  return ref
      .watch(_calendarBoardRepoProvider)
      .fetchMyParticipatedPosts(user.userId);
});

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

enum BoardCalendarMode { national, area, mine }

extension _BoardCalendarModeX on BoardCalendarMode {
  String get label => switch (this) {
        BoardCalendarMode.national => '全国',
        BoardCalendarMode.area => '地域',
        BoardCalendarMode.mine => '自分',
      };
}

class BoardCalendarScreen extends ConsumerStatefulWidget {
  const BoardCalendarScreen({super.key});

  @override
  ConsumerState<BoardCalendarScreen> createState() =>
      _BoardCalendarScreenState();
}

class _BoardCalendarScreenState extends ConsumerState<BoardCalendarScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  BoardCalendarMode _mode = BoardCalendarMode.national;

  @override
  void initState() {
    super.initState();
    _selectedDay = _dateOnly(DateTime.now());
  }

  Map<DateTime, List<BoardPostModel>> _groupByDay(List<BoardPostModel> posts) {
    final map = <DateTime, List<BoardPostModel>>{};
    for (final p in posts) {
      if (p.scheduledAt == null) continue;
      final day = _dateOnly(p.scheduledAt!);
      map.putIfAbsent(day, () => []).add(p);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final myArea = ref.watch(authNotifierProvider).value?.area;

    final postsAsync = _mode == BoardCalendarMode.mine
        ? ref.watch(myParticipatedBoardPostsProvider)
        : ref.watch(allBoardPostsProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const YaheAppBar(title: '開催カレンダー'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<BoardCalendarMode>(
              segments: [
                for (final m in BoardCalendarMode.values)
                  ButtonSegment(
                    value: m,
                    label: Text(m.label),
                    enabled: m != BoardCalendarMode.area ||
                        (myArea != null && myArea.isNotEmpty),
                  ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ),
          if (_mode == BoardCalendarMode.area &&
              myArea != null &&
              myArea.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'プロフィールで設定した地域「$myArea」に基づいて表示しています',
                style:
                    const TextStyle(color: AppColors.textMuted, fontSize: 11),
              ),
            ),
          Expanded(
            child: postsAsync.when(
              loading: () => const Center(
                  child: CircularProgressIndicator(color: AppColors.primary)),
              error: (e, _) {
                final provider = _mode == BoardCalendarMode.mine
                    ? myParticipatedBoardPostsProvider
                    : allBoardPostsProvider;
                return ErrorView(
                    message: '読み込みに失敗しました',
                    onRetry: () => ref.invalidate(provider));
              },
              data: (rawPosts) {
                final posts = _mode == BoardCalendarMode.area
                    ? rawPosts
                        .where((p) => prefectureMatches(myArea, p.prefecture))
                        .toList()
                    : rawPosts;
                final byDay = _groupByDay(posts);
                final selectedEvents =
                    byDay[_selectedDay] ?? const <BoardPostModel>[];

                return Column(
                  children: [
                    TableCalendar<BoardPostModel>(
                      locale: 'ja_JP',
                      firstDay:
                          DateTime.now().subtract(const Duration(days: 365)),
                      lastDay: DateTime.now().add(const Duration(days: 365)),
                      focusedDay: _focusedDay,
                      selectedDayPredicate: (day) =>
                          isSameDay(_selectedDay, day),
                      eventLoader: (day) => byDay[_dateOnly(day)] ?? const [],
                      onDaySelected: (selected, focused) {
                        setState(() {
                          _selectedDay = _dateOnly(selected);
                          _focusedDay = focused;
                        });
                      },
                      onPageChanged: (focused) => _focusedDay = focused,
                      calendarStyle: CalendarStyle(
                        todayDecoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.4),
                            shape: BoxShape.circle),
                        selectedDecoration: const BoxDecoration(
                            color: AppColors.primary, shape: BoxShape.circle),
                        markerDecoration: const BoxDecoration(
                            color: AppColors.primary, shape: BoxShape.circle),
                      ),
                      headerStyle: const HeaderStyle(
                        formatButtonVisible: false,
                        titleCentered: true,
                      ),
                      calendarBuilders: CalendarBuilders(
                        markerBuilder: (context, day, events) {
                          if (events.isEmpty) return null;
                          return Positioned(
                            bottom: 2,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                  color: AppColors.primary,
                                  borderRadius: BorderRadius.circular(8)),
                              child: Text(
                                '${events.length}件',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const Divider(height: 1, color: AppColors.border),
                    Expanded(
                      child: selectedEvents.isEmpty
                          ? Center(
                              child: Text(
                                _mode == BoardCalendarMode.mine
                                    ? 'この日は参加・興味あり登録がありません'
                                    : 'この日の開催予定はありません',
                                style:
                                    const TextStyle(color: AppColors.textMuted),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.all(16),
                              itemCount: selectedEvents.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, i) =>
                                  _CalendarPostCard(post: selectedEvents[i]),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CalendarPostCard extends StatelessWidget {
  final BoardPostModel post;
  const _CalendarPostCard({required this.post});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => BoardDetailScreen(postId: post.postId)),
      ),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(post.title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                  if (post.scheduledAt != null)
                    Text(
                      DateFormat('HH:mm').format(post.scheduledAt!),
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 12),
                    ),
                  if ((post.meetingPlaceText ?? post.prefecture) != null) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(Icons.place_outlined,
                            size: 12, color: AppColors.textMuted),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            post.meetingPlaceText ?? post.prefecture!,
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
            const Icon(Icons.chevron_right, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}

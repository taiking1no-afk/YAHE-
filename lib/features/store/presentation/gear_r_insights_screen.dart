import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/constants/app_colors.dart';
import '../../auth/presentation/auth_provider.dart';
import '../data/store_repository.dart';
import '../models/gear_r_insights_model.dart';

const _gearRAccent = Color(0xFF6C63FF);
const _accentLikes = Color(0xFFFF4500);
const _accentLinks = Color(0xFF20C997);

final _storeRepoProvider =
    Provider<StoreRepository>((ref) => StoreRepository());

final gearRInsightsPeriodProvider = StateProvider.autoDispose<int>((ref) => 30);

final gearRInsightsProvider =
    FutureProvider.autoDispose<GearRInsights?>((ref) async {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null || !user.isGearR) return null;
  final days = ref.watch(gearRInsightsPeriodProvider);
  return ref.read(_storeRepoProvider).fetchGearRInsights(days: days);
});

String _pct(double v) => '${v.toStringAsFixed(1)}%';

/// Gear R限定「インサイトアクティビティ」。
/// 月次バッチのレポートと違い、いつでもその場で最新の状態を集計して表示する。
class GearRInsightsScreen extends ConsumerWidget {
  const GearRInsightsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insightsAsync = ref.watch(gearRInsightsProvider);
    final period = ref.watch(gearRInsightsPeriodProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('インサイトアクティビティ'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '更新',
            onPressed: () => ref.invalidate(gearRInsightsProvider),
          ),
        ],
        // 期間チップをAppBar側に固定しておくことで、期間切替のたび
        // insightsAsyncがローディング状態に戻って画面全体がスピナーになり
        // チップごと消えてしまう問題（連続切替不可・スクロール位置リセット）
        // を避ける。
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                for (final d in [7, 30, 90]) ...[
                  ChoiceChip(
                    label: Text('$d日間'),
                    selected: period == d,
                    selectedColor: _gearRAccent.withOpacity(0.18),
                    labelStyle: TextStyle(
                      color: period == d ? _gearRAccent : AppColors.textMuted,
                      fontWeight:
                          period == d ? FontWeight.w800 : FontWeight.w500,
                    ),
                    onSelected: (_) => ref
                        .read(gearRInsightsPeriodProvider.notifier)
                        .state = d,
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ),
      ),
      body: insightsAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: _gearRAccent)),
        error: (_, __) => const Center(
          child:
              Text('読み込みに失敗しました', style: TextStyle(color: AppColors.textMuted)),
        ),
        data: (insights) {
          if (insights == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Gear R限定の機能です',
                    style: TextStyle(color: AppColors.textMuted)),
              ),
            );
          }
          final p = insights.period;
          final l = insights.lifetime;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
              const _SectionHeader(
                icon: Icons.person_outline,
                title: 'プロフィールインサイト',
              ),
              const SizedBox(height: 12),
              _SubLabel('期間内（直近$period日間）'),
              const SizedBox(height: 8),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.55,
                children: [
                  _MetricCard(
                    icon: Icons.visibility_outlined,
                    label: 'プロフィール閲覧数',
                    value: '${p.profileViews}',
                  ),
                  _MetricCard(
                    icon: Icons.favorite_border,
                    label: 'もらったいいね',
                    value: '${p.likesReceived}',
                    sub: p.likesReceived > 0
                        ? 'うちすれ違いなし ${p.likesReceivedNonEncounter}人（${_pct(p.likesReceivedNonEncounterPct)}）'
                        : null,
                  ),
                  _MetricCard(
                    icon: Icons.favorite,
                    label: '送ったいいね',
                    value: '${p.likesSent}',
                  ),
                  _MetricCard(
                    icon: Icons.handshake_outlined,
                    label: 'マッチ',
                    value: '${p.matches}',
                  ),
                  _MetricCard(
                    icon: Icons.link,
                    label: 'SNSリンクタップ',
                    value: '${p.linkClicks}',
                    sub: 'プロフィール閲覧の${_pct(p.linkClickPct)}',
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _SubLabel('累計（アカウント開設からの合計）'),
              const SizedBox(height: 4),
              const Text(
                'すれ違いの記録は一定期間で自動的に消去される仕様のため、すれ違い関連の指標は期間指定に関わらず常に累計値です。',
                style: TextStyle(color: AppColors.textMuted, fontSize: 11),
              ),
              const SizedBox(height: 10),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.55,
                children: [
                  _MetricCard(
                    icon: Icons.directions_car_filled_outlined,
                    label: '累計すれ違い数',
                    value: '${l.encounterCount}',
                  ),
                  _MetricCard(
                    icon: Icons.percent,
                    label: 'すれ違い→いいね率',
                    value: _pct(l.encounterToLikeRate),
                    sub: '${l.likesReceivedEncounter}人がいいね',
                  ),
                  _MetricCard(
                    icon: Icons.favorite_rounded,
                    label: 'すれ違い起点のマッチ',
                    value: '${l.matchesFromEncounter}',
                    sub:
                        '全マッチ${l.matchesTotal}件中 ${_pct(l.matchesFromEncounterPct)}',
                  ),
                  _MetricCard(
                    icon: Icons.trending_up,
                    label: 'リンク→マッチ',
                    value: '${l.linkClickToMatch}人',
                    sub: 'SNSリンクを開いてマッチに至った人数',
                  ),
                ],
              ),
              const SizedBox(height: 28),
              const Text('日別の推移',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: const [
                  _LegendDot(color: _gearRAccent, label: 'プロフィール閲覧'),
                  _LegendDot(color: _accentLikes, label: 'もらったいいね'),
                  _LegendDot(color: _accentLinks, label: 'SNSリンクタップ'),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 200,
                child: _DailyChart(daily: insights.daily),
              ),
              const SizedBox(height: 32),
              const _SectionHeader(
                icon: Icons.event_outlined,
                title: '作成したイベントのインサイト',
              ),
              const SizedBox(height: 4),
              const Text(
                '自分が主催したツーリング・イベント募集ごとの反応です（累計）。',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              if (insights.posts.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('まだ募集を作成していません',
                      style: TextStyle(color: AppColors.textMuted)),
                )
              else
                ...insights.posts.map((post) => _PostInsightCard(post: post)),
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  const _SectionHeader({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: _gearRAccent),
        const SizedBox(width: 8),
        Text(title,
            style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w800)),
      ],
    );
  }
}

class _SubLabel extends StatelessWidget {
  final String text;
  const _SubLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? sub;
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    this.sub,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _gearRAccent.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: _gearRAccent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(value,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800)),
          if (sub != null) ...[
            const SizedBox(height: 2),
            Text(sub!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: 10.5)),
          ],
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
      ],
    );
  }
}

class _DailyChart extends StatelessWidget {
  final List<GearRInsightsDailyPoint> daily;
  const _DailyChart({required this.daily});

  @override
  Widget build(BuildContext context) {
    if (daily.isEmpty) {
      return const Center(
          child:
              Text('データがありません', style: TextStyle(color: AppColors.textMuted)));
    }
    final maxY = [
      1,
      ...daily.map((d) => d.profileViews),
      ...daily.map((d) => d.linkClicks),
      ...daily.map((d) => d.likesReceived),
    ].reduce((a, b) => a > b ? a : b).toDouble();

    // 横軸のラベルが密集しすぎないよう、日数に応じて間引く
    final labelStep = (daily.length / 6).ceil().clamp(1, daily.length);

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxY * 1.2,
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                interval: (maxY / 4).clamp(1, double.infinity)),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: labelStep.toDouble(),
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= daily.length) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    DateFormat('M/d').format(daily[i].date),
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 10),
                  ),
                );
              },
            ),
          ),
        ),
        lineBarsData: [
          _line(daily.map((d) => d.profileViews.toDouble()).toList(),
              _gearRAccent),
          _line(daily.map((d) => d.likesReceived.toDouble()).toList(),
              _accentLikes),
          _line(
              daily.map((d) => d.linkClicks.toDouble()).toList(), _accentLinks),
        ],
      ),
    );
  }

  LineChartBarData _line(List<double> values, Color color) {
    return LineChartBarData(
      spots: [
        for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i])
      ],
      isCurved: true,
      color: color,
      barWidth: 2.5,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(show: true, color: color.withOpacity(0.08)),
    );
  }
}

class _PostInsightCard extends StatelessWidget {
  final GearRInsightsPost post;
  const _PostInsightCard({required this.post});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(post.title,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
          if (post.scheduledAt != null) ...[
            const SizedBox(height: 2),
            Text(
              DateFormat('yyyy年M月d日').format(post.scheduledAt!),
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _PostStat(
                  icon: Icons.visibility_outlined,
                  label: '閲覧',
                  value: post.viewCount),
              _PostStat(
                  icon: Icons.favorite,
                  label: '気になる（延べ）',
                  value: post.everInterestedCount),
              _PostStat(
                  icon: Icons.people_outline,
                  label: '参加',
                  value: post.joinedCount),
            ],
          ),
          const SizedBox(height: 12),
          _RatioRow(
            label: '気になる→参加',
            pct: post.interestedToJoinedPct,
            detail:
                '${post.everInterestedCount}人中 ${post.interestedToJoinedCount}人が参加',
            color: _gearRAccent,
          ),
          const SizedBox(height: 8),
          _RatioRow(
            label: '参加者による招待（拡散）',
            pct: post.participantInvitedPct,
            detail:
                '参加者${post.joinedCount}人中 ${post.participantInvitedCount}人が他の参加者を招待',
            color: _accentLinks,
          ),
        ],
      ),
    );
  }
}

class _PostStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final int value;
  const _PostStat(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.textMuted),
        const SizedBox(width: 4),
        Text('$label $value',
            style:
                const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
      ],
    );
  }
}

class _RatioRow extends StatelessWidget {
  final String label;
  final double pct;
  final String detail;
  final Color color;
  const _RatioRow({
    required this.label,
    required this.pct,
    required this.detail,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
            Text(_pct(pct),
                style: TextStyle(
                    color: color, fontSize: 13, fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: (pct / 100).clamp(0, 1),
            minHeight: 6,
            backgroundColor: color.withOpacity(0.12),
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
        const SizedBox(height: 3),
        Text(detail,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 10.5)),
      ],
    );
  }
}

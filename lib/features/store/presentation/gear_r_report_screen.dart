import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../auth/presentation/auth_provider.dart';
import '../data/store_repository.dart';
import '../models/gear_r_report_model.dart';

final _storeRepoProvider = Provider<StoreRepository>((ref) => StoreRepository());

final gearRReportsProvider = FutureProvider.autoDispose<List<GearRMonthlyReport>>((ref) async {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null || !user.isGearR) return [];
  return ref.read(_storeRepoProvider).fetchGearRReports(user.userId);
});

class GearRReportScreen extends ConsumerWidget {
  const GearRReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reportsAsync = ref.watch(gearRReportsProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('月次アクセスレポート'),
      ),
      body: reportsAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: Color(0xFF6C63FF)),
        ),
        error: (_, __) => const Center(
          child: Text('レポートの読み込みに失敗しました', style: TextStyle(color: AppColors.textMuted)),
        ),
        data: (reports) {
          if (reports.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'まだレポートがありません。\n毎月1日に前月分が自動で届きます。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary, height: 1.6),
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: reports.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, i) => _ReportCard(report: reports[i]),
          );
        },
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final GearRMonthlyReport report;
  const _ReportCard({required this.report});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('📊', style: TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              Text(
                report.periodLabel,
                style: const TextStyle(
                  color: Color(0xFF6C63FF),
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _MetricRow(label: 'すれ違い', value: '${report.encounters}回', icon: Icons.swap_horiz),
          _MetricRow(label: 'プロフィール閲覧', value: '${report.profileViews}回', icon: Icons.visibility_outlined),
          _MetricRow(label: 'もらったいいね', value: '${report.likesReceived}件', icon: Icons.favorite_border),
          _MetricRow(label: '送ったいいね', value: '${report.likesSent}件', icon: Icons.favorite),
          _MetricRow(label: 'マッチ', value: '${report.matches}件', icon: Icons.handshake_outlined),
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _MetricRow({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
          ),
          Text(value, style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

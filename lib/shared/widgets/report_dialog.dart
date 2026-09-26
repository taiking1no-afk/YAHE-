import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../features/profile/data/user_repository.dart';

/// 通報理由（開発者指定の10分類）。submit_report RPC の category と対応する。
const Map<String, String> reportCategoryLabels = {
  'harassment': '迷惑行為',
  'spam': 'スパム',
  'fraud': '詐欺',
  'threat': '脅迫',
  'stalking': 'ストーカー',
  'sexual_harassment': '性的嫌がらせ',
  'doxxing': '個人情報の公開',
  'impersonation': 'なりすまし',
  'dangerous_driving_solicitation': '危険運転の勧誘',
  'inappropriate_photo': '不適切な写真',
  'other': 'その他',
};

/// 通報ダイアログを表示し、選択・送信まで完結させる共通ウィジェット。
/// ユーザー/プロフィール/写真通報は [targetId] を、メッセージ/投稿通報は
/// 対応する id のみを渡す（reporter は submit_report 側で auth.uid() から解決）。
Future<void> showReportDialog(
  BuildContext context, {
  required String targetType,
  String? targetId,
  String? chatMessageId,
  String? groupMessageId,
  String? boardPostId,
}) async {
  String? selectedCategory;
  final detailController = TextEditingController();

  final submitted = await showDialog<bool>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('通報'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('理由を選んでください',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
              const SizedBox(height: 12),
              ...reportCategoryLabels.entries.map((e) => RadioListTile<String>(
                    value: e.key,
                    groupValue: selectedCategory,
                    title: Text(e.value, style: const TextStyle(fontSize: 14)),
                    activeColor: AppColors.primary,
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) => setState(() => selectedCategory = v),
                  )),
              const SizedBox(height: 8),
              TextField(
                controller: detailController,
                decoration: const InputDecoration(
                  hintText: '詳細（任意）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                maxLines: 2,
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: selectedCategory == null
                ? null
                : () => Navigator.pop(ctx, true),
            child: const Text('送信'),
          ),
        ],
      ),
    ),
  );

  if (submitted == true && selectedCategory != null && context.mounted) {
    try {
      final result = await UserRepository().report(
        targetType: targetType,
        category: selectedCategory!,
        detail: detailController.text,
        targetId: targetId,
        chatMessageId: chatMessageId,
        groupMessageId: groupMessageId,
        boardPostId: boardPostId,
      );
      if (!context.mounted) return;
      if (result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('通報を送信しました。ありがとうございます。')),
        );
      } else if (result['error'] == 'already_reported') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('この対象は既に通報済みです')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('エラーが発生しました')),
        );
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('エラーが発生しました')),
      );
    }
  }
  detailController.dispose();
}

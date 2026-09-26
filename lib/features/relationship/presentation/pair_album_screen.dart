import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/constants/app_colors.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../data/relationship_repository.dart';
import '../models/pair_relationship_model.dart';

class PairAlbumScreen extends StatefulWidget {
  final String myUserId;
  final String otherUserId;
  final String otherNickname;
  const PairAlbumScreen({
    super.key,
    required this.myUserId,
    required this.otherUserId,
    required this.otherNickname,
  });

  @override
  State<PairAlbumScreen> createState() => _PairAlbumScreenState();
}

class _PairAlbumScreenState extends State<PairAlbumScreen> {
  List<PairAlbumEntryModel>? _entries;
  bool _loadError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() => _loadError = false);
    RelationshipRepository()
        .fetchAlbum(widget.myUserId, widget.otherUserId)
        .then((e) {
      if (mounted) setState(() => _entries = e);
    }).catchError((_) {
      if (mounted) setState(() => _loadError = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: YaheAppBar(title: '${widget.otherNickname}さんとのアルバム'),
      body: _loadError
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('読み込みに失敗しました',
                      style: TextStyle(color: AppColors.textMuted)),
                  const SizedBox(height: 12),
                  TextButton(onPressed: _load, child: const Text('再試行')),
                ],
              ),
            )
          : entries == null
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : entries.isEmpty
              ? const Center(
                  child: Text('まだ思い出がありません',
                      style: TextStyle(color: AppColors.textMuted)))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.milestoneType.emoji,
                              style: const TextStyle(fontSize: 20)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppColors.border),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    DateFormat('yyyy年M月d日')
                                        .format(e.occurredAt),
                                    style: const TextStyle(
                                        color: AppColors.textMuted,
                                        fontSize: 11),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    e.milestoneType.label,
                                    style: const TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}

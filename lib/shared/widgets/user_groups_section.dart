import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../features/groups/data/group_repository.dart';
import '../../features/groups/models/group_model.dart';
import '../../features/groups/presentation/group_detail_screen.dart';
import '../../features/groups/presentation/group_list_screen.dart';
import 'signed_storage_image.dart';

final myGroupsProvider =
    FutureProvider.autoDispose.family<List<GroupModel>, String>((ref, userId) {
  return GroupRepository().fetchMyGroups(userId);
});

/// 指定ユーザーの所属グループ一覧。自分のプロフィールにも他人のプロフィールにも使う。
class UserGroupsSection extends ConsumerStatefulWidget {
  final String userId;
  final bool showSearchLink;
  const UserGroupsSection(
      {super.key, required this.userId, this.showSearchLink = true});

  @override
  ConsumerState<UserGroupsSection> createState() => _UserGroupsSectionState();
}

class _UserGroupsSectionState extends ConsumerState<UserGroupsSection> {
  bool _expanded = false;

  static const _collapsedCount = 2;

  @override
  Widget build(BuildContext context) {
    final groupsAsync = ref.watch(myGroupsProvider(widget.userId));
    final groups = groupsAsync.value;
    final hasMore = groups != null && groups.length > _collapsedCount;
    final visible = groups == null
        ? const <GroupModel>[]
        : (_expanded ? groups : groups.take(_collapsedCount).toList());

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '所属グループ',
                style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (widget.showSearchLink)
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const GroupListScreen()),
                  ),
                  child: const Text('グループを探す', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          if (groups == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(color: AppColors.primary),
            )
          else if (groups.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('まだどのグループにも参加していません',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
            )
          else ...[
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 2.6,
              children: visible.map((g) => _GroupCard(group: g)).toList(),
            ),
            if (hasMore)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(
                      _expanded
                          ? '閉じる'
                          : 'もっと見る（+${groups.length - _collapsedCount}）',
                      style: const TextStyle(fontSize: 12)),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final GroupModel group;
  const _GroupCard({required this.group});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => GroupDetailScreen(groupId: group.groupId)),
      ),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.surfaceCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            (group.iconUrl != null && group.iconUrl!.isNotEmpty)
                ? ClipOval(
                    child: SignedStorageImage(
                      storedReference: group.iconUrl!,
                      defaultBucket: 'group-photos',
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                    ),
                  )
                : const CircleAvatar(
                    radius: 24,
                    backgroundColor: AppColors.background,
                    child:
                        Icon(Icons.group, size: 24, color: AppColors.primary),
                  ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                group.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

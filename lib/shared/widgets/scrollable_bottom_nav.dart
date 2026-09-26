import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';

class ScrollableBottomNavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final int? badgeCount;

  const ScrollableBottomNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    this.badgeCount,
  });
}

/// 標準の BottomNavigationBar は5項目を超えると視認性が破綻するため、
/// タブ数が増えても横スクロールで対応できる自作の下タブバー。
/// 挙動（currentIndex/onTap）は BottomNavigationBar と同じインターフェースに揃えてある。
class ScrollableBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<ScrollableBottomNavItem> items;

  const ScrollableBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  static const double _tabWidth = 72;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 60,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: items.length <= 5
            ? const NeverScrollableScrollPhysics()
            : const ClampingScrollPhysics(),
        child: Row(
          children: [
            for (int i = 0; i < items.length; i++)
              _NavTab(
                item: items[i],
                selected: i == currentIndex,
                width: items.length <= 5
                    ? MediaQuery.of(context).size.width / items.length
                    : _tabWidth,
                onTap: () => onTap(i),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  final ScrollableBottomNavItem item;
  final bool selected;
  final double width;
  final VoidCallback onTap;

  const _NavTab({
    required this.item,
    required this.selected,
    required this.width,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.primary : AppColors.textMuted;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: 60,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(selected ? item.activeIcon : item.icon,
                    color: color, size: 24),
                if ((item.badgeCount ?? 0) > 0)
                  Positioned(
                    top: -4,
                    right: -8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      constraints: const BoxConstraints(minWidth: 14),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        // 真円(BoxShape.circle)だと「99+」のような3文字が
                        // 円の外にはみ出していたため、幅に応じて伸びる
                        // ピル型（大きい半径の角丸）に変更する。
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: Text(
                        item.badgeCount! > 99
                            ? '99+'
                            : item.badgeCount.toString(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

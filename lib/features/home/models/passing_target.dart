import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// すれ違いたい相手の種別（users.passing_target）
enum PassingTarget { car, bike, both }

extension PassingTargetX on PassingTarget {
  String get value {
    switch (this) {
      case PassingTarget.car:
        return 'car';
      case PassingTarget.bike:
        return 'bike';
      case PassingTarget.both:
        return 'both';
    }
  }

  /// ホーム上部の短い表示（絵文字を除いたテキスト。アイコンは[icons]を別途表示する）
  String get shortLabel {
    switch (this) {
      case PassingTarget.car:
        return '車のり';
      case PassingTarget.bike:
        return 'バイカー';
      case PassingTarget.both:
        return 'どちらも';
    }
  }

  /// shortLabelの前に並べて表示するアイコン群
  List<IconData> get icons {
    switch (this) {
      case PassingTarget.car:
        return const [LucideIcons.car];
      case PassingTarget.bike:
        return const [LucideIcons.bike];
      case PassingTarget.both:
        return const [LucideIcons.car, LucideIcons.bike];
    }
  }

  String get label {
    switch (this) {
      case PassingTarget.car:
        return '車のりとすれ違う';
      case PassingTarget.bike:
        return 'バイカーとすれ違う';
      case PassingTarget.both:
        return 'どちらともすれ違う';
    }
  }

  String get description {
    switch (this) {
      case PassingTarget.car:
        return '車を登録しているユーザーとだけすれ違います';
      case PassingTarget.bike:
        return 'バイクを登録しているユーザーとだけすれ違います';
      case PassingTarget.both:
        return '車・バイクどちらのユーザーともすれ違います';
    }
  }

  static PassingTarget fromString(String? v) {
    switch (v) {
      case 'car':
        return PassingTarget.car;
      case 'bike':
        return PassingTarget.bike;
      default:
        return PassingTarget.both;
    }
  }
}

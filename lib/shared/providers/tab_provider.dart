import 'package:flutter_riverpod/flutter_riverpod.dart';

/// ボトムナビのタブインデックスを管理
/// 0: YAHE, 1: いいね, 2: マッチ, 3: マイカー, 4: プロフィール
final selectedTabProvider = StateProvider<int>((ref) => 0);

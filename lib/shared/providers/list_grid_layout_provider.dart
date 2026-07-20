import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ListGridLayout { list, grid }

/// 画面ごとに一覧をリスト/グリッドで切り替えるための汎用プロバイダ。
/// [screenKey] ごとに選択状態を SharedPreferences に永続化する
/// （例: 'likes_sent', 'likes_received', 'match'）。
class ListGridLayoutNotifier extends FamilyNotifier<ListGridLayout, String> {
  @override
  ListGridLayout build(String arg) {
    _load();
    return ListGridLayout.list;
  }

  String get _prefKey => 'list_grid_layout_$arg';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKey);
    if (saved == ListGridLayout.grid.name) {
      state = ListGridLayout.grid;
    }
  }

  Future<void> toggle() async {
    state = state == ListGridLayout.list ? ListGridLayout.grid : ListGridLayout.list;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, state.name);
  }
}

final listGridLayoutProvider =
    NotifierProvider.family<ListGridLayoutNotifier, ListGridLayout, String>(
  ListGridLayoutNotifier.new,
);

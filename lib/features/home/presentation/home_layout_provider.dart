import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum HomeLayout { list, grid }

const _prefKey = 'home_layout_mode';

class HomeLayoutNotifier extends Notifier<HomeLayout> {
  @override
  HomeLayout build() {
    _load();
    return HomeLayout.list;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKey);
    if (saved == HomeLayout.grid.name) {
      state = HomeLayout.grid;
    }
  }

  Future<void> toggle() async {
    state = state == HomeLayout.list ? HomeLayout.grid : HomeLayout.list;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, state.name);
  }
}

final homeLayoutProvider =
    NotifierProvider<HomeLayoutNotifier, HomeLayout>(HomeLayoutNotifier.new);

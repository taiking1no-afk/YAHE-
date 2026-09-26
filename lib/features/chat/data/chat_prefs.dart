import 'package:shared_preferences/shared_preferences.dart';

/// チャット行（個人・グループ共通）のピン留め・ミュート・非表示（削除）を
/// 端末ローカルに保持する。トーク自体は削除せず、自分の一覧表示だけを操作する
/// （LINEの「トーク削除」と同じく相手側には影響しない）。
class ChatPrefs {
  static const _pinnedKey = 'chat_pinned_ids';
  static const _mutedKey = 'chat_muted_ids';
  static const _hiddenKey = 'chat_hidden_ids';
  static const _hiddenAtPrefix = 'chat_hidden_at_';
  static const _collapsedSectionsKey = 'chat_collapsed_sections';

  static Future<Set<String>> _get(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(key) ?? []).toSet();
  }

  static Future<void> _toggle(String key, String id, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(key) ?? []).toSet();
    if (value) {
      set.add(id);
    } else {
      set.remove(id);
    }
    await prefs.setStringList(key, set.toList());
  }

  static Future<Set<String>> pinnedIds() => _get(_pinnedKey);
  static Future<Set<String>> mutedIds() => _get(_mutedKey);
  static Future<Set<String>> hiddenIds() => _get(_hiddenKey);

  static Future<void> setPinned(String id, bool value) =>
      _toggle(_pinnedKey, id, value);
  static Future<void> setMuted(String id, bool value) =>
      _toggle(_mutedKey, id, value);

  /// 「削除」= 一覧から非表示にする。削除した時刻より後に新着メッセージ
  /// （自分・相手どちらの送信でも）があれば再度表示する。
  static Future<void> hide(String id) async {
    await _toggle(_hiddenKey, id, true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        '$_hiddenAtPrefix$id', DateTime.now().toUtc().toIso8601String());
  }

  static Future<void> unhide(String id) async {
    await _toggle(_hiddenKey, id, false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_hiddenAtPrefix$id');
  }

  /// 削除（非表示）した時刻。削除していなければnull。
  static Future<Map<String, DateTime>> hiddenAt() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = (prefs.getStringList(_hiddenKey) ?? []);
    final result = <String, DateTime>{};
    for (final id in ids) {
      final iso = prefs.getString('$_hiddenAtPrefix$id');
      final parsed = iso != null ? DateTime.tryParse(iso) : null;
      if (parsed != null) result[id] = parsed;
    }
    return result;
  }

  /// 一覧のセクション（「マイグループチャット」等）をしまう（折りたたむ）状態。
  static Future<Set<String>> collapsedSections() => _get(_collapsedSectionsKey);
  static Future<void> setSectionCollapsed(String id, bool value) =>
      _toggle(_collapsedSectionsKey, id, value);
}

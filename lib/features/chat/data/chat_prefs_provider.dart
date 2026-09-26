import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'chat_prefs.dart';

/// ミュート中のチャットID（'dm:<matchId>' / 'group:<groupId>'）。
/// 下タブの未読バッジ集計で、ミュート分を除外するために使う。
final mutedChatIdsProvider =
    FutureProvider<Set<String>>((ref) => ChatPrefs.mutedIds());

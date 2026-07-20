import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 通知タップなどから発火する遷移先
enum PendingNav { none, timeline, match }

final pendingNavProvider = StateProvider<PendingNav>((ref) => PendingNav.none);

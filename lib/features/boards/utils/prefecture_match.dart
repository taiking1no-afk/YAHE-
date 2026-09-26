/// ユーザーの居住エリア（例：「東京都」）と募集の開催地域が一致するかを判定する。
/// どちらも自由記入のため、厳密一致ではなく前方/部分一致で緩く判定する。
bool prefectureMatches(String? userArea, String? postPrefecture) {
  if (userArea == null || userArea.trim().isEmpty) return false;
  if (postPrefecture == null || postPrefecture.trim().isEmpty) return false;
  final a = userArea.trim();
  final b = postPrefecture.trim();
  return a.contains(b) || b.contains(a);
}

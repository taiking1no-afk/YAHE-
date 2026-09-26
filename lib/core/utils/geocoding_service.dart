import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class GeocodingResult {
  final String displayName;
  final LatLng latLng;
  const GeocodingResult({required this.displayName, required this.latLng});
}

/// OpenStreetMap Nominatim を使った地名検索（既存の地図タイルと同じOSM系サービス）。
/// 無料APIのため利用ポリシーに従い、識別可能なUser-Agentを付け、
/// 呼び出し側で連続叩き（1秒未満の連打）をしないよう注意すること。
class GeocodingService {
  static const _endpoint = 'https://nominatim.openstreetmap.org/search';

  static Future<List<GeocodingResult>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final uri = Uri.parse(_endpoint).replace(queryParameters: {
      'q': trimmed,
      'format': 'json',
      'limit': '8',
      'countrycodes': 'jp',
      'accept-language': 'ja',
    });

    try {
      final response = await http.get(
        uri,
        headers: {'User-Agent': 'jp.nozawataiki.yahe (YAHE app board search)'},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) return [];

      final list = jsonDecode(response.body) as List;
      return list.map((r) {
        final map = r as Map<String, dynamic>;
        return GeocodingResult(
          displayName: map['display_name'] as String,
          latLng: LatLng(double.parse(map['lat'] as String),
              double.parse(map['lon'] as String)),
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }
}

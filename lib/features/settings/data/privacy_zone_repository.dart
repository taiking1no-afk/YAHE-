import 'dart:math';
import '../../../core/supabase/supabase_config.dart';
import '../models/privacy_zone.dart';

class PrivacyZoneRepository {
  final _client = SupabaseConfig.client;

  Future<List<PrivacyZone>> fetchZones(String userId) async {
    final rows = await _client
        .from('privacy_zones')
        .select()
        .eq('user_id', userId)
        .order('created_at', ascending: false);

    return rows.map((r) => PrivacyZone.fromJson(r)).toList();
  }

  Future<PrivacyZone> createZone({
    required String userId,
    required double lat,
    required double lng,
    required int radiusM,
    required String label,
  }) async {
    final data = await _client
        .from('privacy_zones')
        .insert({
          'user_id': userId,
          'lat': lat,
          'lng': lng,
          'radius_m': radiusM,
          'label': label,
        })
        .select()
        .single();

    return PrivacyZone.fromJson(data);
  }

  Future<void> toggleZone(String zoneId, bool isActive) async {
    await _client
        .from('privacy_zones')
        .update({'is_active': isActive}).eq('zone_id', zoneId);
  }

  Future<void> deleteZone(String zoneId) async {
    await _client.from('privacy_zones').delete().eq('zone_id', zoneId);
  }

  // 現在地がアクティブなプライバシーゾーン（四角形）内かどうかを判定。
  // radius_m を「中心から各辺までの距離（＝正方形の半辺）」として扱う。
  Future<bool> isInPrivacyZone({
    required String userId,
    required double lat,
    required double lng,
  }) async {
    final zones = await _client
        .from('privacy_zones')
        .select('lat, lng, radius_m')
        .eq('user_id', userId)
        .eq('is_active', true);

    for (final zone in zones) {
      final zoneLat = (zone['lat'] as num).toDouble();
      final zoneLng = (zone['lng'] as num).toDouble();
      final radiusM = (zone['radius_m'] as num).toDouble();

      if (_isInSquare(lat, lng, zoneLat, zoneLng, radiusM)) return true;
    }

    return false;
  }

  // 中心(centerLat,centerLng)から半辺halfM[m]の正方形（緯度経度に沿った矩形）に
  // 点(lat,lng)が含まれるか判定
  static bool _isInSquare(
    double lat,
    double lng,
    double centerLat,
    double centerLng,
    double halfM,
  ) {
    const metersPerDegLat = 111320.0;
    final metersPerDegLng = 111320.0 * cos(centerLat * pi / 180);
    if (metersPerDegLng == 0) return false;

    final dLatM = (lat - centerLat) * metersPerDegLat;
    final dLngM = (lng - centerLng) * metersPerDegLng;
    return dLatM.abs() <= halfM && dLngM.abs() <= halfM;
  }
}

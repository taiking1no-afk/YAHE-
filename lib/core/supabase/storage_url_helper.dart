import 'supabase_config.dart';

/// Storage 上のオブジェクト参照（DB には `bucket:path` 形式で保存）
class StorageRef {
  final String bucket;
  final String path;
  const StorageRef(this.bucket, this.path);
}

/// 非公開バケットの画像を署名付き URL に変換するヘルパー
class StorageUrlHelper {
  StorageUrlHelper._();

  static const _buckets = ['vehicle-photos', 'profile-photos'];
  static final _cache = <String, _CachedSigned>{};

  /// アップロード後に DB へ保存する形式
  static String toStoredPath(String bucket, String objectPath) =>
      '$bucket:$objectPath';

  /// レガシー public URL / 署名 URL / `bucket:path` をパース
  static StorageRef? parseStored(
    String stored, {
    String defaultBucket = 'vehicle-photos',
  }) {
    if (stored.isEmpty) return null;

    if (!stored.contains('://') && stored.contains(':')) {
      final colon = stored.indexOf(':');
      final bucket = stored.substring(0, colon);
      final path = stored.substring(colon + 1);
      if (_buckets.contains(bucket) && path.isNotEmpty) {
        return StorageRef(bucket, path);
      }
    }

    if (stored.startsWith('http')) {
      for (final bucket in _buckets) {
        for (final marker in [
          '/object/public/$bucket/',
          '/object/sign/$bucket/',
          '/object/authenticated/$bucket/',
        ]) {
          final idx = stored.indexOf(marker);
          if (idx == -1) continue;
          final raw = stored.substring(idx + marker.length).split('?').first;
          return StorageRef(bucket, Uri.decodeComponent(raw));
        }
      }
      return null;
    }

    if (!stored.contains('://')) {
      return StorageRef(defaultBucket, stored);
    }

    return null;
  }

  static bool isStorageReference(String value) =>
      parseStored(value) != null;

  static Future<String> resolve(
    String stored, {
    String defaultBucket = 'vehicle-photos',
  }) async {
    final ref = parseStored(stored, defaultBucket: defaultBucket);
    if (ref == null) return stored;

    final cacheKey = '${ref.bucket}/${ref.path}';
    final cached = _cache[cacheKey];
    if (cached != null &&
        cached.expiresAt.isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
      return cached.url;
    }

    final signed = await SupabaseConfig.client.storage
        .from(ref.bucket)
        .createSignedUrl(ref.path, 3600);

    _cache[cacheKey] = _CachedSigned(
      url: signed,
      expiresAt: DateTime.now().add(const Duration(seconds: 3600)),
    );
    return signed;
  }

  static Future<List<String>> resolveList(
    List<String> stored, {
    String defaultBucket = 'vehicle-photos',
  }) async {
    if (stored.isEmpty) return const [];
    return Future.wait(
      stored.map((s) => resolve(s, defaultBucket: defaultBucket)),
    );
  }
}

class _CachedSigned {
  final String url;
  final DateTime expiresAt;
  const _CachedSigned({required this.url, required this.expiresAt});
}

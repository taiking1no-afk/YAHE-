import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;
import '../../../core/supabase/supabase_config.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/image_sanitizer.dart';
import '../../../core/supabase/storage_url_helper.dart';
import '../models/vehicle.dart';
import '../models/vehicle_customization_part.dart';
export '../models/vehicle.dart' show VehicleType, VehicleTypeX;

class VehicleRepository {
  final _client = SupabaseConfig.client;

  Future<List<Vehicle>> fetchAllVehicles(String userId) async {
    final rows = await _client
        .from('vehicles')
        .select()
        .eq('user_id', userId)
        .eq('is_active', true)
        .order('created_at', ascending: true);
    return rows.map((r) => Vehicle.fromJson(r)).toList();
  }

  Future<Vehicle?> fetchMyVehicle(String userId) async {
    final data = await _client
        .from('vehicles')
        .select()
        .eq('user_id', userId)
        .eq('is_active', true)
        .order('created_at', ascending: true)
        .limit(1)
        .maybeSingle();
    if (data == null) return null;
    return Vehicle.fromJson(data);
  }

  Future<int> countVehicles(String userId) async {
    final rows = await _client
        .from('vehicles')
        .select('vehicle_id')
        .eq('user_id', userId)
        .eq('is_active', true);
    return rows.length;
  }

  Future<bool> canAddVehicle(String userId, bool isPremium) async {
    if (isPremium) return true;
    final count = await countVehicles(userId);
    return count < AppConstants.freeVehicleLimit;
  }

  Future<Vehicle> createVehicle({
    required String userId,
    required VehicleType vehicleType,
    required String maker,
    required String model,
    int? year,
    required List<String> tags,
    String? customContent,
    required List<File> photoFiles,
    DateTime? deliveryDate,
  }) async {
    // 写真アップロード（失敗しても登録は継続）
    final photoUrls = <String>[];
    for (final file in photoFiles) {
      final url = await _uploadPhoto(file, userId);
      if (url != null) photoUrls.add(url);
    }

    // 全カラムで挿入を試みる（マイグレーション未実行でも動くようフォールバック付き）
    try {
      final data = await _client
          .from('vehicles')
          .insert({
            'user_id': userId,
            'vehicle_type': vehicleType.value,
            'maker': maker,
            'model': model,
            if (year != null) 'year': year,
            'tags': tags,
            if (customContent != null && customContent.isNotEmpty)
              'custom_content': customContent,
            'photos': photoUrls,
            if (deliveryDate != null)
              'delivery_date': deliveryDate.toIso8601String().split('T').first,
          })
          .select()
          .single();
      return Vehicle.fromJson(data);
    } catch (e) {
      // v1.1/v1.2 のマイグレーション未実行の場合、新カラムを除いてリトライ
      debugPrint('[VehicleRepo] createVehicle フル挿入失敗: $e\n→ 基本カラムでリトライ');
      final data = await _client
          .from('vehicles')
          .insert({
            'user_id': userId,
            'maker': maker,
            'model': model,
            if (year != null) 'year': year,
            'tags': tags,
            'photos': photoUrls,
          })
          .select()
          .single();
      return Vehicle.fromJson(data);
    }
  }

  Future<Vehicle> updateVehicle({
    required String vehicleId,
    required String userId,
    VehicleType? vehicleType,
    String? maker,
    String? model,
    int? year,
    List<String>? tags,
    String? customContent,
    List<File>? newPhotoFiles,
    List<String>? existingPhotoUrls,
    DateTime? deliveryDate,
  }) async {
    final photoUrls = List<String>.from(existingPhotoUrls ?? []);
    if (newPhotoFiles != null) {
      for (final file in newPhotoFiles) {
        final url = await _uploadPhoto(file, userId);
        if (url != null) photoUrls.add(url);
      }
    }

    final updates = <String, dynamic>{};
    if (vehicleType != null) updates['vehicle_type'] = vehicleType.value;
    if (maker != null) updates['maker'] = maker;
    if (model != null) updates['model'] = model;
    if (year != null) updates['year'] = year;
    if (tags != null) updates['tags'] = tags;
    if (customContent != null) updates['custom_content'] = customContent;
    if (photoUrls.isNotEmpty) updates['photos'] = photoUrls;
    if (deliveryDate != null) {
      updates['delivery_date'] =
          deliveryDate.toIso8601String().split('T').first;
    }

    try {
      final data = await _client
          .from('vehicles')
          .update(updates)
          .eq('vehicle_id', vehicleId)
          .select()
          .single();
      return Vehicle.fromJson(data);
    } catch (e) {
      // 新カラムを除いてリトライ
      debugPrint('[VehicleRepo] updateVehicle フル更新失敗: $e\n→ 基本カラムでリトライ');
      final basicUpdates = <String, dynamic>{};
      if (maker != null) basicUpdates['maker'] = maker;
      if (model != null) basicUpdates['model'] = model;
      if (year != null) basicUpdates['year'] = year;
      if (tags != null) basicUpdates['tags'] = tags;
      if (photoUrls.isNotEmpty) basicUpdates['photos'] = photoUrls;

      final data = await _client
          .from('vehicles')
          .update(basicUpdates)
          .eq('vehicle_id', vehicleId)
          .select()
          .single();
      return Vehicle.fromJson(data);
    }
  }

  /// この車の「オーナーのこだわり」（1台につき1つ、パーツ単位ではなく車単位のコメント）
  Future<void> updateOwnerPassionComment(
      String vehicleId, String? comment) async {
    await _client
        .from('vehicles')
        .update({'owner_passion_comment': comment}).eq('vehicle_id', vehicleId);
  }

  /// 一覧/サムネイル表示時の写真焦点（トリミング中心）を更新する。
  Future<void> updatePhotoFocal(String vehicleId, double x, double y) async {
    await _client.from('vehicles').update({
      'photo_focal_x': x,
      'photo_focal_y': y,
    }).eq('vehicle_id', vehicleId);
  }

  Future<Vehicle?> fetchVehicleByUserId(String userId) =>
      fetchMyVehicle(userId);

  Future<void> deleteVehicle(String vehicleId) async {
    await _client
        .from('vehicles')
        .update({'is_active': false}).eq('vehicle_id', vehicleId);
  }

  Future<List<VehicleCustomizationPart>> fetchCustomizationParts(
      String vehicleId) async {
    final rows = await _client
        .from('vehicle_customization_parts')
        .select()
        .eq('vehicle_id', vehicleId)
        .order('display_order', ascending: true);
    return rows.map((r) => VehicleCustomizationPart.fromJson(r)).toList();
  }

  Future<void> upsertCustomizationPart(VehicleCustomizationPart part) async {
    await _client
        .from('vehicle_customization_parts')
        .upsert(part.toUpsertJson(), onConflict: 'vehicle_id,category');
  }

  /// マッチ済みの相手の車の「気になるカスタム」を送信する。
  /// 送信後、Edge Function経由でpush通知も送る（失敗してもエラーにしない）。
  Future<void> sendCustomInterest({
    required String vehicleId,
    required String ownerUserId,
    required List<CustomizationCategory> categories,
  }) async {
    await _client.rpc('send_custom_interest', params: {
      'p_vehicle_id': vehicleId,
      'p_categories': categories.map((c) => c.value).toList(),
    });
    try {
      await _client.functions
          .invoke('send-custom-interest-notification', body: {
        'to_user_id': ownerUserId,
      });
    } catch (_) {}
  }

  Future<String?> _uploadPhoto(File file, String userId) async {
    try {
      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}_${file.path.hashCode.abs()}.jpg';
      final objectPath = '$userId/$fileName';
      final raw = await file.readAsBytes();
      final bytes = await sanitizeImageBytes(raw);
      await _client.storage.from(AppConstants.vehiclePhotoBucket).uploadBinary(
            objectPath,
            bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );
      return StorageUrlHelper.toStoredPath(
        AppConstants.vehiclePhotoBucket,
        objectPath,
      );
    } catch (e) {
      debugPrint('[VehicleRepo] 写真アップロード失敗（写真なしで登録を継続）: $e');
      return null;
    }
  }
}

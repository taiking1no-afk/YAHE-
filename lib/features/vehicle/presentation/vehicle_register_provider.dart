import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/vehicle_repository.dart';
import '../models/vehicle.dart';
export '../models/vehicle.dart' show VehicleType, VehicleTypeX;

final vehicleRepositoryProvider =
    Provider<VehicleRepository>((ref) => VehicleRepository());

class VehicleRegisterState {
  final VehicleType vehicleType;
  final String? maker;
  final String? model;
  final int? year;
  final String customContent;
  final List<File> photos;
  final DateTime? deliveryDate;
  final bool isLoading;
  final String? error;

  // 編集時は既存データを保持
  final String? editingVehicleId;
  final List<String> existingPhotoUrls;

  const VehicleRegisterState({
    this.vehicleType = VehicleType.car,
    this.maker,
    this.model,
    this.year,
    this.customContent = '',
    this.photos = const [],
    this.deliveryDate,
    this.isLoading = false,
    this.error,
    this.editingVehicleId,
    this.existingPhotoUrls = const [],
  });

  VehicleRegisterState copyWith({
    VehicleType? vehicleType,
    String? maker,
    String? model,
    int? year,
    String? customContent,
    List<File>? photos,
    DateTime? deliveryDate,
    bool? isLoading,
    String? error,
    String? editingVehicleId,
    List<String>? existingPhotoUrls,
  }) =>
      VehicleRegisterState(
        vehicleType: vehicleType ?? this.vehicleType,
        maker: maker ?? this.maker,
        model: model ?? this.model,
        year: year ?? this.year,
        customContent: customContent ?? this.customContent,
        photos: photos ?? this.photos,
        deliveryDate: deliveryDate ?? this.deliveryDate,
        isLoading: isLoading ?? this.isLoading,
        error: error,
        editingVehicleId: editingVehicleId ?? this.editingVehicleId,
        existingPhotoUrls: existingPhotoUrls ?? this.existingPhotoUrls,
      );
}

class VehicleRegisterNotifier extends Notifier<VehicleRegisterState> {
  @override
  VehicleRegisterState build() => const VehicleRegisterState();

  // 編集モードで初期化
  void loadForEdit(Vehicle vehicle) {
    state = VehicleRegisterState(
      vehicleType: vehicle.vehicleType,
      maker: vehicle.maker,
      model: vehicle.model,
      year: vehicle.year,
      customContent: vehicle.customContent ?? '',
      deliveryDate: vehicle.deliveryDate,
      editingVehicleId: vehicle.vehicleId,
      existingPhotoUrls: List.from(vehicle.photos),
    );
  }

  void reset() {
    state = const VehicleRegisterState();
  }

  void setVehicleType(VehicleType type) =>
      state = state.copyWith(vehicleType: type, maker: null, model: null);

  void setMaker(String maker) =>
      state = state.copyWith(maker: maker, model: null);

  void setModel(String model) => state = state.copyWith(model: model);

  void setYear(int? year) => state = state.copyWith(year: year);

  void setCustomContent(String v) => state = state.copyWith(customContent: v);

  void setDeliveryDate(DateTime? date) =>
      state = state.copyWith(deliveryDate: date);

  void addPhoto(File file) {
    if (state.photos.length + state.existingPhotoUrls.length >= 5) return;
    state = state.copyWith(photos: [...state.photos, file]);
  }

  void removeNewPhoto(int index) {
    final photos = List<File>.from(state.photos)..removeAt(index);
    state = state.copyWith(photos: photos);
  }

  void removeExistingPhoto(int index) {
    final urls = List<String>.from(state.existingPhotoUrls)..removeAt(index);
    state = state.copyWith(existingPhotoUrls: urls);
  }

  Future<Vehicle?> submit(String userId) async {
    if (state.maker == null || (state.model?.isEmpty ?? true)) return null;

    state = state.copyWith(isLoading: true);
    try {
      final repo = ref.read(vehicleRepositoryProvider);

      Vehicle vehicle;
      if (state.editingVehicleId != null) {
        vehicle = await repo.updateVehicle(
          vehicleId: state.editingVehicleId!,
          userId: userId,
          vehicleType: state.vehicleType,
          maker: state.maker,
          model: state.model,
          year: state.year,
          tags: const [],
          customContent: state.customContent,
          newPhotoFiles: state.photos,
          existingPhotoUrls: state.existingPhotoUrls,
          deliveryDate: state.deliveryDate,
        );
      } else {
        vehicle = await repo.createVehicle(
          userId: userId,
          vehicleType: state.vehicleType,
          maker: state.maker!,
          model: state.model!,
          year: state.year,
          tags: const [],
          customContent: state.customContent,
          photoFiles: state.photos,
          deliveryDate: state.deliveryDate,
        );
      }
      state = state.copyWith(isLoading: false);
      return vehicle;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return null;
    }
  }
}

final vehicleRegisterProvider =
    NotifierProvider<VehicleRegisterNotifier, VehicleRegisterState>(
  VehicleRegisterNotifier.new,
);

final myVehicleProvider =
    FutureProvider.family<Vehicle?, String>((ref, userId) async {
  final repo = ref.read(vehicleRepositoryProvider);
  return repo.fetchMyVehicle(userId);
});

final allVehiclesProvider =
    FutureProvider.family<List<Vehicle>, String>((ref, userId) async {
  final repo = ref.read(vehicleRepositoryProvider);
  return repo.fetchAllVehicles(userId);
});

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/constants/app_colors.dart';
import '../../../shared/widgets/step_header.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../auth/presentation/auth_provider.dart';
import 'vehicle_register_provider.dart';

class VehicleRegisterStep3 extends ConsumerStatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onComplete;

  const VehicleRegisterStep3({
    super.key,
    required this.onBack,
    required this.onComplete,
  });

  @override
  ConsumerState<VehicleRegisterStep3> createState() =>
      _VehicleRegisterStep3State();
}

class _VehicleRegisterStep3State extends ConsumerState<VehicleRegisterStep3> {
  final _picker = ImagePicker();

  Future<void> _pickImage() async {
    final reg = ref.read(vehicleRegisterProvider);
    final remaining = 5 - (reg.photos.length + reg.existingPhotoUrls.length);
    if (remaining <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('写真は最大5枚までです')),
        );
      }
      return;
    }

    final notifier = ref.read(vehicleRegisterProvider.notifier);

    // まず複数枚選択を試す。端末・プラグインの都合で失敗する場合は
    // 単数選択にフォールバックして、最低限選べなくならないようにする。
    try {
      final xFiles = await _picker.pickMultiImage(imageQuality: 85);
      if (xFiles.isNotEmpty) {
        for (final xFile in xFiles.take(remaining)) {
          notifier.addPhoto(File(xFile.path));
        }
        if (xFiles.length > remaining && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('写真は最大5枚までです')),
          );
        }
      }
      return;
    } catch (e) {
      debugPrint('[Step3] pickMultiImage 失敗 → 単数選択にフォールバック: $e');
    }

    // フォールバック：単数選択
    try {
      final xFile = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (xFile != null) {
        notifier.addPhoto(File(xFile.path));
      }
    } catch (e) {
      debugPrint('[Step3] pickImage 失敗: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('写真を選択できませんでした。写真へのアクセスを許可してください。')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final regState = ref.watch(vehicleRegisterProvider);
    final authState = ref.watch(authNotifierProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('愛車登録'),
        leading: IconButton(
            icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
      ),
      body: Column(
        children: [
          StepHeader(currentStep: 3, totalSteps: 3, label: '愛車写真'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '愛車の写真を追加してください（最大5枚）',
                    style:
                        TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '位置情報（EXIF）は自動で削除されます。ナンバープレートは写らない角度で撮影するか、ご自身で隠してください。',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  _PhotoGrid(
                    existingPhotos: regState.existingPhotoUrls,
                    photos: regState.photos,
                    onAdd: (regState.photos.length +
                                regState.existingPhotoUrls.length) <
                            5
                        ? _pickImage
                        : null,
                    onRemoveNew: (i) => ref
                        .read(vehicleRegisterProvider.notifier)
                        .removeNewPhoto(i),
                    onRemoveExisting: (i) => ref
                        .read(vehicleRegisterProvider.notifier)
                        .removeExistingPhoto(i),
                  ),
                  const SizedBox(height: 32),
                  // SNS登録案内
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceCard,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline,
                            color: AppColors.textMuted, size: 18),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'SNSアカウントはマッチング後にプロフィール設定で追加できます',
                            style: TextStyle(
                                color: AppColors.textMuted, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            color: AppColors.background,
            child: regState.isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.primary))
                : ElevatedButton(
                    onPressed: (regState.photos.isNotEmpty ||
                            regState.existingPhotoUrls.isNotEmpty)
                        ? () async {
                            final user = authState.value;
                            if (user == null) return;
                            final vehicle = await ref
                                .read(vehicleRegisterProvider.notifier)
                                .submit(user.userId);
                            if (vehicle != null) {
                              widget.onComplete();
                            } else if (context.mounted) {
                              // submit()が失敗すると、以前はローディングが
                              // 消えるだけで「登録完了」を押しても何も起きて
                              // いないように見えていた（エラーはstateに
                              // 保存されるだけで、どこからも表示されていなかった）。
                              final err =
                                  ref.read(vehicleRegisterProvider).error;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(err != null
                                      ? '登録に失敗しました: $err'
                                      : '登録に失敗しました。もう一度お試しください。'),
                                ),
                              );
                            }
                          }
                        : null,
                    style: ElevatedButton.styleFrom(
                      disabledBackgroundColor: AppColors.surfaceCard,
                    ),
                    child: const Text('登録完了'),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PhotoGrid extends StatelessWidget {
  final List<String> existingPhotos;
  final List<File> photos;
  final VoidCallback? onAdd;
  final ValueChanged<int> onRemoveNew;
  final ValueChanged<int> onRemoveExisting;

  const _PhotoGrid({
    this.existingPhotos = const [],
    required this.photos,
    required this.onAdd,
    required this.onRemoveNew,
    required this.onRemoveExisting,
  });

  @override
  Widget build(BuildContext context) {
    final existingCount = existingPhotos.length;
    final newCount = photos.length;
    final total = existingCount + newCount + (onAdd != null ? 1 : 0);

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: total,
      itemBuilder: (context, index) {
        // 既存写真（署名URL）
        if (index < existingCount) {
          return _PhotoCell(
            storedReference: existingPhotos[index],
            onRemove: () => onRemoveExisting(index),
          );
        }
        // 新規追加写真（ローカルファイル）
        final newIndex = index - existingCount;
        if (newIndex < newCount) {
          return _PhotoCell(
            file: photos[newIndex],
            onRemove: () => onRemoveNew(newIndex),
          );
        }
        // 追加ボタン
        return _AddButton(onTap: onAdd!);
      },
    );
  }
}

class _PhotoCell extends StatelessWidget {
  final File? file;
  final String? storedReference;
  final VoidCallback onRemove;

  const _PhotoCell({this.file, this.storedReference, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: file != null
              ? Image.file(
                  file!,
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover,
                )
              : SignedStorageImage(
                  storedReference: storedReference ?? '',
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover,
                ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              width: 22,
              height: 22,
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

class _AddButton extends StatelessWidget {
  final VoidCallback onTap;
  const _AddButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border, style: BorderStyle.solid),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_photo_alternate_outlined,
                color: AppColors.textMuted, size: 28),
            SizedBox(height: 4),
            Text('追加',
                style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

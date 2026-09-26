import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import 'signed_storage_image.dart';

/// 既にアップロード済みの写真について、一覧/サムネイル表示時に
/// どの位置を中心に切り抜くか（焦点）をドラッグで指定する全画面ピッカー。
/// 戻り値は正規化座標(0.0〜1.0、null はキャンセル)。
Future<Offset?> pickFocalPoint(
  BuildContext context, {
  required String storedReference,
  required String bucket,
  double initialX = 0.5,
  double initialY = 0.5,
}) {
  return Navigator.push<Offset>(
    context,
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _FocalPointPickerScreen(
        storedReference: storedReference,
        bucket: bucket,
        initialX: initialX,
        initialY: initialY,
      ),
    ),
  );
}

class _FocalPointPickerScreen extends StatefulWidget {
  final String storedReference;
  final String bucket;
  final double initialX;
  final double initialY;
  const _FocalPointPickerScreen({
    required this.storedReference,
    required this.bucket,
    required this.initialX,
    required this.initialY,
  });

  @override
  State<_FocalPointPickerScreen> createState() =>
      _FocalPointPickerScreenState();
}

class _FocalPointPickerScreenState extends State<_FocalPointPickerScreen> {
  late Offset _point = Offset(widget.initialX, widget.initialY);

  void _updateFromLocalPosition(Offset local, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    setState(() {
      _point = Offset(
        (local.dx / size.width).clamp(0.0, 1.0),
        (local.dy / size.height).clamp(0.0, 1.0),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('表示位置を選択', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _point),
            child: const Text('決定', style: TextStyle(color: AppColors.primary)),
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '一覧・サムネイルで中心に表示したい場所をタップ、またはドラッグして選んでください',
              style: TextStyle(color: Colors.white70, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size =
                        Size(constraints.maxWidth, constraints.maxHeight);
                    return GestureDetector(
                      onTapDown: (d) =>
                          _updateFromLocalPosition(d.localPosition, size),
                      onPanUpdate: (d) =>
                          _updateFromLocalPosition(d.localPosition, size),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          SignedStorageImage(
                            storedReference: widget.storedReference,
                            defaultBucket: widget.bucket,
                            fit: BoxFit.cover,
                          ),
                          Positioned(
                            left: _point.dx * size.width - 16,
                            top: _point.dy * size.height - 16,
                            child: IgnorePointer(
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: Colors.white, width: 2),
                                  boxShadow: const [
                                    BoxShadow(
                                        color: Colors.black45, blurRadius: 4),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

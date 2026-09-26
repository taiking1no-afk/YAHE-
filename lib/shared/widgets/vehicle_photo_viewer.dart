import 'package:flutter/material.dart';
import 'report_dialog.dart';
import 'signed_storage_image.dart';

/// 愛車写真をピンチズームで全画面表示するビューア
class VehiclePhotoViewer extends StatefulWidget {
  final List<String> photos;
  final int initialIndex;
  final String? ownerUserId;

  const VehiclePhotoViewer({
    super.key,
    required this.photos,
    this.initialIndex = 0,
    this.ownerUserId,
  });

  static Future<void> show(
    BuildContext context, {
    required List<String> photos,
    int initialIndex = 0,
    String? ownerUserId,
  }) {
    if (photos.isEmpty) return Future.value();
    return Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => VehiclePhotoViewer(
            photos: photos, initialIndex: initialIndex, ownerUserId: ownerUserId),
      ),
    );
  }

  @override
  State<VehiclePhotoViewer> createState() => _VehiclePhotoViewerState();
}

class _VehiclePhotoViewerState extends State<VehiclePhotoViewer> {
  late int _index;
  late final PageController _controller;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: widget.photos.length > 1
            ? Text(
                '${_index + 1} / ${widget.photos.length}',
                style: const TextStyle(color: Colors.white, fontSize: 15),
              )
            : null,
        actions: [
          if (widget.ownerUserId != null)
            IconButton(
              icon: const Icon(Icons.flag_outlined, color: Colors.white),
              tooltip: '通報',
              onPressed: () => showReportDialog(context,
                  targetType: 'photo', targetId: widget.ownerUserId),
            ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.photos.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => Center(
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            child: SignedStorageImage(
              storedReference: widget.photos[i],
              fit: BoxFit.contain,
              placeholder: const Center(
                child: CircularProgressIndicator(color: Colors.white54),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

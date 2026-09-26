import 'package:flutter/material.dart';
import 'signed_storage_image.dart';

/// チャット等の写真をタップした際に、全画面でピンチズーム表示する。
class PhotoViewerScreen extends StatelessWidget {
  final String storedReference;
  final String bucket;
  const PhotoViewerScreen(
      {super.key, required this.storedReference, required this.bucket});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: SignedStorageImage(
            storedReference: storedReference,
            defaultBucket: bucket,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}

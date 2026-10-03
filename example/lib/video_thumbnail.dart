import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_compress_example/main.dart';

class VideoThumbnail extends StatefulWidget {
  const VideoThumbnail({super.key});

  @override
  State<VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<VideoThumbnail> {
  File? _thumbnailFile;
  String? _error;

  Future<void> _getVideoThumbnail() async {
    final path = await pickVideoPath();
    if (path == null) {
      return;
    }
    try {
      final thumbnail = await VideoCompress.getFileThumbnail(path);
      if (!mounted) {
        return;
      }
      setState(() {
        _thumbnailFile = thumbnail;
        _error = null;
      });
    } on StateError catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _thumbnailFile = null;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final thumbnail = _thumbnailFile;
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: const Text('File Thumbnail')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: _getVideoThumbnail,
              child: const Text('Get File Thumbnail'),
            ),
            if (thumbnail != null)
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Image(image: FileImage(thumbnail)),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Text(error),
              ),
          ],
        ),
      ),
    );
  }
}

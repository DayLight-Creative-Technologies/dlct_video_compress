import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_compress_example/video_thumbnail.dart';

void main() {
  runApp(const MyApp());
}

/// The path of a video the user picks: a file dialog on macOS, the gallery
/// elsewhere. Null when the user picks nothing.
Future<String?> pickVideoPath() async {
  if (Platform.isMacOS) {
    const typeGroup = XTypeGroup(label: 'videos', extensions: ['mov', 'mp4']);
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    return file?.path;
  }
  final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
  return picked?.path;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'video_compress example',
      theme: ThemeData(colorSchemeSeed: Colors.blue),
      home: const MyHomePage(title: 'video_compress example'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  String _result = 'Pick a video to compress';

  Future<void> _compressVideo() async {
    final path = await pickVideoPath();
    if (path == null) {
      return;
    }
    // compressVideo throws a StateError while another compress runs.
    if (VideoCompress.isCompressing) {
      setState(() => _result = 'Already compressing; cancel it first');
      return;
    }
    await VideoCompress.setLogLevel(0);
    final info = await VideoCompress.compressVideo(
      path,
      quality: VideoQuality.MediumQuality,
      deleteOrigin: false,
      includeAudio: true,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      if (info == null) {
        _result = 'Compression failed';
      } else if (info.isCancel == true) {
        _result = 'Compression cancelled';
      } else {
        _result = info.path ?? 'Compressed, but no output path';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              _result,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            IconButton(
              icon: const Icon(Icons.cancel, size: 55),
              tooltip: 'Cancel compression',
              onPressed: VideoCompress.cancelCompression,
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const VideoThumbnail()),
                );
              },
              child: const Text('Test thumbnail'),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _compressVideo,
        tooltip: 'Compress a video',
        child: const Icon(Icons.add),
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_compress/src/progress_callback/compress_mixin.dart';
import 'package:video_compress/video_compress.dart';

abstract class IVideoCompress extends CompressMixin {}

class _VideoCompressImpl extends IVideoCompress {
  _VideoCompressImpl._() {
    initProcessCallback();
  }

  static _VideoCompressImpl? _instance;

  static _VideoCompressImpl get instance {
    return _instance ??= _VideoCompressImpl._();
  }

  static void _dispose() {
    _instance = null;
  }
}

// ignore: non_constant_identifier_names
IVideoCompress get VideoCompress => _VideoCompressImpl.instance;

extension Compress on IVideoCompress {
  void dispose() {
    _VideoCompressImpl._dispose();
  }

  Future<T?> _invoke<T>(String name, [Map<String, dynamic>? params]) async {
    T? result;
    try {
      result = params != null
          ? await channel.invokeMethod(name, params)
          : await channel.invokeMethod(name);
    } on PlatformException catch (e) {
      debugPrint('''Error from VideoCompress: 
      Method: $name
      $e''');
    }
    return result;
  }

  /// getByteThumbnail return [Future<Uint8List>],
  /// quality can be controlled by [quality] from 1 to 100,
  /// select the position unit in the video by [position] is milliseconds
  Future<Uint8List?> getByteThumbnail(
    String path, {
    int quality = 100,
    int position = -1,
  }) async {
    assert(quality > 1 || quality < 100);

    return await _invoke<Uint8List>('getByteThumbnail', {
      'path': path,
      'quality': quality,
      'position': position,
    });
  }

  /// getFileThumbnail return [Future<File>]
  /// quality can be controlled by [quality] from 1 to 100,
  /// select the position unit in the video by [position] is milliseconds
  Future<File> getFileThumbnail(
    String path, {
    int quality = 100,
    int position = -1,
  }) async {
    assert(quality > 1 || quality < 100);

    // Not to set the result as strong-mode so that it would have exception to
    // lead to the failure of compression
    final filePath = await (_invoke<String>('getFileThumbnail', {
      'path': path,
      'quality': quality,
      'position': position,
    }));

    // The platform answers an error when it cannot read a frame (it used to
    // answer nothing on iOS, so this waited forever).
    if (filePath == null) {
      throw StateError(
          'VideoCompress: getFileThumbnail could not read a frame of $path');
    }

    return File(Uri.decodeFull(filePath));
  }

  /// get media information from [path]
  ///
  /// get media information from [path] return [Future<MediaInfo>]
  ///
  /// Metadata the file does not have (a duration, a width, a height) is null,
  /// never 0. Throws a [StateError] when the file cannot be read as media.
  ///
  /// ## example
  /// ```dart
  /// final info = await _flutterVideoCompress.getMediaInfo(file.path);
  /// debugPrint(info.toJson());
  /// ```
  Future<MediaInfo> getMediaInfo(String path) async {
    final jsonStr = await (_invoke<String>('getMediaInfo', {'path': path}));

    // The platform answers an error when it cannot read the file (this used
    // to throw a null-check TypeError here).
    if (jsonStr == null) {
      throw StateError('VideoCompress: getMediaInfo could not read $path');
    }

    return MediaInfo.fromJson(json.decode(jsonStr));
  }

  /// compress video from [path]
  /// compress video from [path] return [Future<MediaInfo>]
  ///
  /// you can choose its quality by [quality],
  /// determine whether to delete his source file by [deleteOrigin]
  /// optional parameters [startTime] [duration] [includeAudio] [frameRate]
  ///
  /// [startTime] and [duration] are whole seconds: the compress exports the
  /// part of the video from [startTime] (default 0) for [duration] (default:
  /// to the end), cut at the end of the video, with or without audio, on
  /// every platform. When they name no part of the video (a negative start, a
  /// start at or past the end, a duration that is not positive) the compress
  /// fails and answers null.
  ///
  /// A [cancelCompression] that arrives before this compress has answered
  /// makes it answer a [MediaInfo] with `isCancel` true and no path, even when
  /// the export had just finished; its output is deleted.
  ///
  /// ## example
  /// ```dart
  /// final info = await _flutterVideoCompress.compressVideo(
  ///   file.path,
  ///   deleteOrigin: true,
  /// );
  /// debugPrint(info.toJson());
  /// ```
  Future<MediaInfo?> compressVideo(
    String path, {
    VideoQuality quality = VideoQuality.DefaultQuality,
    bool deleteOrigin = false,
    int? startTime,
    int? duration,
    bool? includeAudio,
    int frameRate = 30,
  }) async {
    if (isCompressing) {
      throw StateError('''VideoCompress Error: 
      Method: compressVideo
      Already have a compression process, you need to wait for the process to finish or stop it''');
    }

    if (compressProgress$.notSubscribed) {
      debugPrint('''VideoCompress: You can try to subscribe to the 
      compressProgress\$ stream to know the compressing state.''');
    }

    // ignore: invalid_use_of_protected_member
    setProcessingStatus(true);
    final String? jsonStr;
    try {
      jsonStr = await _invoke<String>('compressVideo', {
        'path': path,
        'quality': quality.index,
        'deleteOrigin': deleteOrigin,
        'startTime': startTime,
        'duration': duration,
        'includeAudio': includeAudio,
        'frameRate': frameRate,
      });
    } finally {
      // Any throw (not only a PlatformException, which _invoke turns into
      // null) used to leave isCompressing set, so every later compress threw.
      // ignore: invalid_use_of_protected_member
      setProcessingStatus(false);
    }

    // A failed compress answers null. A cancelled one answers a MediaInfo
    // with isCancel true and no path: nothing was compressed.
    if (jsonStr != null) {
      final jsonMap = json.decode(jsonStr);
      return MediaInfo.fromJson(jsonMap);
    } else {
      return null;
    }
  }

  /// stop compressing the file that is currently being compressed.
  /// If there is no compression process, nothing will happen.
  Future<void> cancelCompression() async {
    await _invoke<void>('cancelCompression');
  }

  /// delete the cache folder, please do not put other things
  /// in the folder of this plugin, it will be cleared
  Future<bool?> deleteAllCache() async {
    return await _invoke<bool>('deleteAllCache');
  }

  Future<void> setLogLevel(int logLevel) async {
    return await _invoke<void>('setLogLevel', {
      'logLevel': logLevel,
    });
  }
}

import 'dart:io';

class MediaInfo {
  String? path;
  String? title;
  String? author;
  /// The displayed width in pixels: the stored frame's height when
  /// [orientation] is a quarter turn (90 or 270).
  int? width;

  /// The displayed height in pixels: the stored frame's width when
  /// [orientation] is a quarter turn (90 or 270).
  int? height;

  /// The clockwise turn, in degrees (0, 90, 180 or 270), that displays the
  /// stored frames, the same on every platform. [Android] API level 17
  int? orientation;

  /// bytes
  int? filesize; // filesize
  /// milliseconds
  double? duration;
  bool? isCancel;
  File? file;

  MediaInfo({
    required this.path,
    this.title,
    this.author,
    this.width,
    this.height,
    this.orientation,
    this.filesize,
    this.duration,
    this.isCancel,
    this.file,
  });

  MediaInfo.fromJson(Map<String, dynamic> json) {
    path = json['path'];
    title = json['title'];
    author = json['author'];
    width = json['width'];
    height = json['height'];
    orientation = json['orientation'];
    filesize = json['filesize'];
    duration = double.tryParse('${json['duration']}');
    isCancel = json['isCancel'];
    file = path != null ? File(path!) : null;
  }

  Map<String, dynamic> toJson() {
    final data = <String, dynamic>{};
    data['path'] = path;
    data['title'] = title;
    data['author'] = author;
    data['width'] = width;
    data['height'] = height;
    if (orientation != null) {
      data['orientation'] = orientation;
    }
    data['filesize'] = filesize;
    data['duration'] = duration;
    if (isCancel != null) {
      data['isCancel'] = isCancel;
    }
    data['file'] = path != null ? File(path!).toString() : null;
    return data;
  }
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_compress/video_compress.dart';

/// The Dart side of the method-channel contract each platform answers:
/// a completed compress answers its media info, a cancelled one
/// `{"isCancel": true}` with no path, a failed one an error; a thumbnail that
/// cannot be read answers an error. Native code is not exercised here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('video_compress');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void answer(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('compressVideo', () {
    test('a completed compress answers its output media info', () async {
      answer((call) async =>
          '{"path":"/tmp/video_compress/out.mp4","duration":1500,"isCancel":false}');

      final info = await VideoCompress.compressVideo('/tmp/in.mp4');

      expect(info, isNotNull);
      expect(info!.path, '/tmp/video_compress/out.mp4');
      expect(info.file?.path, '/tmp/video_compress/out.mp4');
      expect(info.isCancel, isFalse);
      expect(VideoCompress.isCompressing, isFalse);
    });

    test('a cancelled compress answers isCancel with no path', () async {
      answer((call) async => '{"isCancel":true}');

      final info = await VideoCompress.compressVideo('/tmp/in.mp4');

      expect(info, isNotNull);
      expect(info!.isCancel, isTrue);
      expect(info.path, isNull);
      expect(info.file, isNull);
      expect(VideoCompress.isCompressing, isFalse);
    });

    test('a failed compress answers null and allows the next compress',
        () async {
      answer((call) async => throw PlatformException(
          code: 'video_compress', message: 'compressVideo error'));

      expect(await VideoCompress.compressVideo('/tmp/in.mp4'), isNull);
      expect(VideoCompress.isCompressing, isFalse);

      answer((call) async => '{"isCancel":true}');
      expect(await VideoCompress.compressVideo('/tmp/in.mp4'), isNotNull);
    });

    test('a throw that is not a PlatformException still clears isCompressing',
        () async {
      // No handler: invokeMethod throws MissingPluginException.
      await expectLater(VideoCompress.compressVideo('/tmp/in.mp4'),
          throwsA(isA<MissingPluginException>()));
      expect(VideoCompress.isCompressing, isFalse);

      answer((call) async => '{"isCancel":true}');
      expect(await VideoCompress.compressVideo('/tmp/in.mp4'), isNotNull);
    });
  });

  group('getMediaInfo', () {
    test('metadata the file lacks decodes as null, never 0', () async {
      answer((call) async =>
          '{"path":"/tmp/in.mp4","title":"","author":"","filesize":1234}');

      final info = await VideoCompress.getMediaInfo('/tmp/in.mp4');

      expect(info.path, '/tmp/in.mp4');
      expect(info.filesize, 1234);
      expect(info.duration, isNull);
      expect(info.width, isNull);
      expect(info.height, isNull);
      expect(info.orientation, isNull);
    });

    test('fromJson accepts a map with every field absent', () {
      final info = MediaInfo.fromJson(<String, dynamic>{});

      expect(info.path, isNull);
      expect(info.title, isNull);
      expect(info.author, isNull);
      expect(info.width, isNull);
      expect(info.height, isNull);
      expect(info.orientation, isNull);
      expect(info.filesize, isNull);
      expect(info.duration, isNull);
      expect(info.isCancel, isNull);
      expect(info.file, isNull);
    });

    test('a file that cannot be read throws a StateError naming it', () async {
      answer((call) async => throw PlatformException(
          code: 'video_compress', message: 'getMediaInfo error'));

      await expectLater(
          VideoCompress.getMediaInfo('/tmp/in.mp4'),
          throwsA(isA<StateError>().having((e) => e.message, 'message',
              'VideoCompress: getMediaInfo could not read /tmp/in.mp4')));
    });
  });

  group('thumbnails', () {
    test('getByteThumbnail answers null when the frame cannot be read',
        () async {
      answer((call) async => throw PlatformException(
          code: 'video_compress', message: 'getByteThumbnail error'));

      expect(await VideoCompress.getByteThumbnail('/tmp/in.mp4'), isNull);
    });

    test('getFileThumbnail throws when the frame cannot be read', () async {
      answer((call) async => throw PlatformException(
          code: 'video_compress', message: 'getFileThumbnail error'));

      await expectLater(VideoCompress.getFileThumbnail('/tmp/in.mp4'),
          throwsA(isA<StateError>()));
    });

    test('getFileThumbnail answers the written file, position in ms',
        () async {
      MethodCall? received;
      answer((call) async {
        received = call;
        return '/tmp/video_compress/in%20clip.jpg';
      });

      final file = await VideoCompress.getFileThumbnail('/tmp/in clip.mp4',
          quality: 85, position: 1000);

      expect(file.path, '/tmp/video_compress/in clip.jpg');
      expect(received?.method, 'getFileThumbnail');
      expect(received?.arguments,
          {'path': '/tmp/in clip.mp4', 'quality': 85, 'position': 1000});
    });
  });
}

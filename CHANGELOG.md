## 3.1.5+dlct.6 (DLCT Fork)

`getMediaInfo` reports a video's displayed size and its rotation the same
way on Android, iOS and macOS (SSK gaps #906, #907), and the iOS plugin's
logic runs in CI (SSK gap #908).

- Android: `Utility.mediaInfoJson` swapped the retriever's width and height
  for rotations 0 and 180 instead of 90 and 270, so every video's size was
  reported transposed. The retriever reports the stored size; the JSON's
  `width` and `height` are now the displayed size (swapped for a quarter
  turn only). `isLandscapeImage`, its only use, is gone. `orientation` is
  unchanged.
- iOS/macOS: `AvController.getVideoOrientation` read the angle from the
  preferred transform's translation, so an untransformed track reported 90,
  a portrait iPhone video 270, a half turn 0 and a three-quarter turn 180.
  It now takes the transform's rotation (`atan2(b, a)`, to the nearest
  quarter turn): 0, 90, 180 or 270 clockwise, the angle Android reports for
  the same file. `width` and `height` are the natural size swapped for a
  quarter turn (`AvController.getDisplayedSize`), as on Android; for the
  rotations a camera writes this is the size reported before.
- macOS: tracks, common metadata and its string values, a track's frame
  rate, natural size and preferred transform, and the asset's duration are
  read with AVFoundation's async `load` API on macOS 13+, where the
  synchronous API is deprecated, and with the synchronous API on 10.15-12,
  as iOS already does on iOS 16+ and earlier. A size or transform that cannot
  be loaded leaves width, height and orientation absent, as on iOS.
- iOS/macOS: `AvController.usesAsyncLoading` (default true) selects the
  async path where the OS has it; only the native tests set it false, to run
  the older path on a newer OS too.
- Dart: `MediaInfo.width`, `height` and `orientation` document these
  meanings. No code change.
- Tests: `MediaInfoJsonTest` checks the exact width, height and orientation
  for rotations 0, 90, 180 and 270. The macOS harness moved to
  `native_tests/media_info/` and is shared with iOS: `main.swift` runs the
  real `getMediaInfo`, `getByteThumbnail` and `getFileThumbnail` channel calls
  on the fixtures, on both loading paths, and checks the exact orientation,
  width and height of an untransformed video and of three rotated ones
  (`video_rot90|180|270.mp4`, written by `make_rotated_fixtures.swift` with
  the transforms a camera writes), and that each thumbnail is a JPEG of the
  displayed size, at the first frame and at the end of the clip. It fails if
  no check ran. `run_macos.sh` builds `macos/Classes` at macOS 10.15;
  `run_ios.sh` builds the Swift sources in `ios/Classes` for the simulator at
  iOS 13.0 against a Flutter stand-in and runs them in a fresh simulator of
  the newest and of the oldest iOS runtime installed.
- CI: new job `Native unit tests (iOS)` runs `run_ios.sh` on macos-latest;
  `Native unit tests (macOS)` runs `run_macos.sh`.

## 3.1.5+dlct.5 (DLCT Fork)

`getMediaInfo` reports only what a file has, and answers every call exactly
once (SSK gap #905).

- Android: `getMediaInfoJson` passed the retriever's duration, width and
  height straight to `Long.parseLong`, so a file without any of them threw
  `NumberFormatException` (and three "Java type mismatch" warnings) and leaked
  its `MediaMetadataRetriever`. Now each is absent from the JSON when the file
  does not report it (or reports it unparseably), never 0, and the retriever
  is released in a `finally`. The JSON is built by the pure
  `Utility.mediaInfoJson` from the retriever's strings; its output is otherwise
  unchanged. The `getMediaInfo` channel call answers the info, or one error
  (`getMediaInfo error`) when the file cannot be read as media; the read used
  to throw out of the handler. `deleteAllCache` answered every call twice
  (`Utility.deleteAllCache` answered, then the handler answered again); it
  answers once.
- iOS/macOS: a file that could not be read and a file without a video track
  both answered `{}`, with no path. Now an unreadable file answers one
  `getMediaInfo error`, and a file without a video track (an audio file)
  answers its path, title, author, duration and filesize, with no width,
  height or orientation. A duration, size or transform that could not be loaded
  is absent instead of 0 (iOS 16+ used to fall back to `.zero`), and an
  indefinite duration is absent instead of a NaN that crashed the JSON
  encoding. `filesize` is the file's size in bytes, as on Android; it was the
  video track's sample bytes. A compress whose output cannot be read answers
  `compressVideo error` and deletes the output, and `deleteOrigin` deletes the
  original only after the output has been read (it deleted it first). A
  compress whose source duration cannot be read answers `compressVideo error`
  instead of exporting a 0 s range; a thumbnail is clamped to the video's
  length only when the length is known.
- Dart: `getMediaInfo` throws a `StateError` naming the path when the
  platform cannot read the file; it threw a null-check `TypeError`.
  `MediaInfo.fromJson` already decoded absent fields as null and is unchanged.
- Tests: `android/src/test/.../MediaInfoTest.kt` (the public handler on a file
  with no metadata, an unreadable call, `deleteAllCache`) and
  `MediaInfoJsonTest.kt` (the JSON for full, partial, absent and unparseable
  metadata; the retriever released after a read and after a failed open).
  `test/video_compress_test.dart` covers absent fields and the unreadable
  error. `macos/Tests/media_info/run.sh` compiles `macos/Classes` against a
  FlutterMacOS stand-in and checks `getMediaInfo` on fixture files: missing,
  not media, empty, audio only, video with and without metadata.
- CI: `Native unit tests (Android)` fails unless `PendingCompressTest`,
  `MediaInfoTest` and `MediaInfoJsonTest` each produced results with at least
  one test. New job `Native unit tests (macOS)` runs the macOS checks.

## 3.1.5+dlct.4 (DLCT Fork)

No change to the plugin's runtime behaviour.

- Android: `PendingCompress` (the record that answers each compress exactly
  once) is `internal` instead of `private`, so JVM unit tests can run it; its
  logic is unchanged. `android/src/test/.../PendingCompressTest.kt` covers a
  completed compress, a cancel before the transcode starts and a cancel during
  it (both run the plugin's own `cancelCompression` handler; the second
  deletes a real partial output file), a failed compress, and a second answer.
  Each test answers twice, so each fails if the answer-once guard is removed.
  `android/build.gradle` adds JUnit 4.13.2 and org.json (the `android.jar`
  stub's `JSONObject.toString()` returns null) for tests only, and
  `unitTests.returnDefaultValues`.
- CI: `Native unit tests (Android)` runs `:video_compress:testDebugUnitTest`
  with the example as the Gradle host, and fails if
  `PendingCompressTest` produced no results or ran no tests.
- iOS/macOS podspecs: deployment targets are iOS 13.0 (was 8.0) and macOS
  10.15 (was 10.11), the minimums of the Flutter 3.44.0 floor: its
  `packages/flutter_tools/bin/podhelper.rb` generates the `Flutter` pod with
  `s.ios.deployment_target = '13.0'` and the `FlutterMacOS` pod with
  `s.osx.deployment_target = '10.15'`, and strips any lower pod target so it
  inherits the project's. The Swift uses nothing newer without `#available`.

## 3.1.5+dlct.3 (DLCT Fork)

No change to the plugin's runtime code (`lib/`, `android/src/main`,
`ios/Classes`, `macos/Classes`).

- CI (SSK gap #900): `.github/workflows/build.yml` runs `Check linting`
  (`flutter analyze --fatal-infos` on the plugin and the example), `Unit tests`
  (`flutter test` on both), and debug builds of the example on the declared
  floor and on stable: `Build Android (min|stable)` (`flutter build apk`),
  `Build iOS (min|stable)` (`flutter build ios --no-codesign --simulator`) and
  `Build macOS (min|stable)` (`flutter build macos`). A push to `master`
  starts a run, although the repository is a GitHub fork.
- Floor: `pubspec.yaml` now declares Flutter 3.44 / Dart 3.12 (it declared
  Flutter 2.0 / Dart 3.0, which has been false since dlct.1). dlct.1's built-in
  Kotlin migration removed `kotlin-android` from `android/build.gradle` and
  added a top-level `kotlin { compilerOptions {} }` block; that builds only on
  Flutter 3.44+, whose Gradle plugin applies KGP to plugin modules itself.
  The `min` build jobs pin Flutter 3.44.0.
- Example: platform folders regenerated with Flutter 3.47.5's `flutter create`.
  The iOS and macOS Podfiles named a `RunnerTests` target that neither
  `Runner.xcodeproj` had, so `pod install` failed; both projects now have the
  target, and both Podfiles are tracked. Android moves from Gradle 7.6.3 /
  AGP 7.3 / Kotlin 1.9.10 (which failed on JDK 21+, "class file major version
  65") to Gradle 9.1.0 / AGP 9.0.1 / Kotlin 2.3.21 with
  `android.builtInKotlin=false`: AGP 9.0.1 is the newest AGP with full Kotlin
  support on Flutter 3.44 (`maxKnownAgpVersionWithFullKotlinSupport`), so the
  example builds on the floor and on stable. Kept: photo library, camera and
  microphone usage descriptions (iOS) and the user-selected-file entitlement
  (macOS). Dropped: unused `video_player`, `file_selector_macos` and
  `cupertino_icons`, and the iOS arbitrary-loads exception (nothing in the
  example loads from the network). `ios/Flutter/Flutter.podspec` is generated
  and no longer tracked.
- Example Dart code: `file_selector` 1.1 and `image_picker` 1.2; cancelling the
  picker, a failed compress, a cancelled compress and an unreadable thumbnail
  each show a message (each crashed on a null-assert before), and a second
  compress while one runs is refused instead of throwing. A widget test covers
  the home page.

## 3.1.5+dlct.2 (DLCT Fork)

- iOS/macOS (SSK gap #896): `cancelCompression` stops only the export running
  now. The stop flag (`stopCommand`) is gone: a cancel that arrived after an
  export had finished left it set, so the NEXT compress ran to the end and
  then answered `isCancel: true` with the INPUT's path. The outcome is read
  from each export's own `status`, on the main thread (the progress timer is
  invalidated there too). macOS never set `exporter`, so its cancel stopped
  nothing; it does now.
- iOS/macOS (#896): a cancelled compress answers `{"isCancel": true}` with no
  `path` (it answered the input's media info) and deletes its partial output.
  A failed export answers a `FlutterError` and deletes its partial output (it
  answered the missing or partial output's media info as a success). A video
  with no video track, or one no export session accepts, answers a
  `FlutterError` instead of crashing on a force unwrap. iOS reads the output's
  media info from `URL.path` (already decoded); it percent-decoded it again
  with a force unwrap, which crashed on a file name containing `%`.
- Android (#896): a cancelled compress answers `{"isCancel": true}` (it
  answered null, the same as a failure); a failed one answers an error. Each
  compress answers exactly once, and a cancel that stops a transcode answers
  at once: a transcode cancelled before its worker started never reaches a
  listener callback, so it never answered. Cancelled and failed compresses
  delete their partial output; output names carry a UUID so a cancelled
  transcode still winding down never deletes the next compress's output. A
  completed transcode whose media info cannot be read answers an error
  instead of throwing on the main thread.
- iOS/macOS: `Utility.deleteFile` checks `url.path` (it checked
  `absoluteString`, so it never deleted anything). `getFileThumbnail` no
  longer calls it on the SOURCE video's path, which would now delete the
  user's video. macOS output names carry a UUID (as iOS's do), so compressing
  an earlier output can no longer delete it as "the previous output".
- iOS/macOS (SSK gap #897): `getByteThumbnail` / `getFileThumbnail` answer a
  `FlutterError` when no frame can be read; they answered nothing, so the
  Dart caller waited forever.
- Android: a thumbnail whose frame cannot be read answers one error. It
  answered an error AND an unencodable success, then threw on the null
  bitmap; a failed thumbnail write answers an error instead of the path of a
  file that was never written; a path with no extension no longer throws.
- All platforms: thumbnail `position` is read in milliseconds, as the Dart API
  documents. iOS/macOS read it as seconds (`position: 1000` asked for the
  frame 1000 s in) and Android as microseconds. A negative position (the
  default, -1) is the first frame on iOS/macOS and any frame on Android; a
  position past the end is clamped to the video's duration on iOS/macOS.
- Dart: `getFileThumbnail` throws a `StateError` naming the video when the
  platform answers an error (it threw a null-check error). `compressVideo`
  clears `isCompressing` on any throw, not only a `PlatformException`, so one
  unexpected error no longer makes every later compress throw. First tests
  of the method-channel contract (`test/video_compress_test.dart`).

## 3.1.5+dlct.1 (DLCT Fork)

- Migrated to Flutter's built-in Kotlin support per the official plugin-author
  guide (https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors):
  removed the `kotlin-android` plugin application and the `kotlinOptions`
  block, and added a top-level `kotlin { compilerOptions { jvmTarget } }`
  block. Flutter warns that a future release will refuse to build apps whose
  plugins apply the Kotlin Gradle Plugin directly; this closes that warning
  for consuming apps on AGP 9 with `android.builtInKotlin=false`. Forward
  migration, not a workaround — no retire condition.

## 3.1.5 (DLCT Fork)

- Fix null check operator crash in `MediaInfo.fromJson` when native layer returns null path (Sentry 96T).
- Guard `path` null check in both `fromJson` and `toJson` — `file` field is now null when `path` is null.

## 3.1.4+1 (DLCT Fork)

- Modernized all iOS AVFoundation APIs to use async `load(_:)` methods, eliminating 15 iOS 16+ deprecation warnings.
- Backward compatible with iOS <16 via `#available` checks.
- Fork maintained by DayLight Creative Technologies (Steven Day).

## 3.1.4

- Removes references to v1 Flutter Android embedding classes.

## 3.1.3

- Update build.gradle (@dharambudh1)
- Bump up transcoder to 0.10.5 (@Ayman-Barghout)
- Add AGP 8 support (@Zazo032)
- Add missing import in 3.1.2 (@jamesdixon)
- Bump to 3.1.2 (@jonataslaw)
- Fix issue where video name containing spaces wasn't properly decoded (@unknown-undefined)

## 3.1.2

- Fix "Failed to stop the muxer" and "java.lang.IllegalStateException" (@VoronovAlexander)
- Fix files with spaces (@unknown-undefined)

## 3.1.1

- Fix issue on iOS with files containing whitespaces (@kaiquegazola)
- Fix cancel compress on IOS (@posawatji)
- Update Android compression library (@crtl)
- Update flutter 3 (@pranavo72bex)
- Fix multiple compression on android (@neelansh-creatorstack )
- Fix multiple compression on iOS (zhuyangyang-lingoace)

## 3.1.0

- Bug fix on getMediaInfo (@trustmefelix)
- Improve getFileThumbnail() (@FelixMoMo/@trustmefelix)
- invalidate updateProgress timer after the completion of video export (@jinthislife)
- Added Support for resolution presets (@yanivshaked)

## 3.0.0

- Added MacOS support (thank's @efraespada)
- Null-safety support (thank's @rlazom feat @leynier)

## 2.1.1

- Fix Subscription import
- Fix Error on android 10 with no includeAudio option

## 2.1.0

- Added cancel compression to android
- Fix compress progress
- Added audio remove/include to android
- Upgrade to android v2
- Fix subscription progress receive same listener

## 2.0.0

- refactor code
  Breaking changes, call VideoCompress.method directly, without having to instantiate it.

## 1.0.0

- release new version

## 0.1.3

- added progress listen

## 0.1.2

- Removed unecessary intent when process is done

## 0.1.1

- Change default value to HD

## 0.1.0

- initial release

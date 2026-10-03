// [DLCT] Runs the plugin's real channel calls on each fixture and checks every
// answer, on macOS (run_macos.sh: macos/Classes) and on an iOS simulator
// (run_ios.sh: ios/Classes):
// - getMediaInfo: exactly one answer per call; an error for a file that
//   cannot be read as media; the fields a file has, and none it lacks (never
//   0); the filesize is the file's size in bytes; the orientation is the
//   clockwise quarter turn of a transform that is exactly one, else 0 (a
//   mirror included), and the width and height the stored size turned by
//   it, as Android reports them (0, 90, 180, 270).
// - getByteThumbnail and getFileThumbnail: exactly one answer per call; a
//   JPEG of the frame as AVFoundation displays it (its size, and for the
//   quadrant fixtures the colour of each quadrant), also at the end of the
//   video (SSK asks for the frame at 1000 ms of clips that may be 1 s long);
//   an error for a file without a video frame.
// - compressVideo: a real export of each quadrant fixture (unturned, turned,
//   mirrored), with SSK's arguments and through each of the plugin's other
//   export paths, answers once with the path of a readable video of the
//   input's length (± 50 ms) that AVFoundation displays as it displays the
//   input: the same aspect and the same colour in each quadrant.
// - compressVideo with startTime and duration (video_timed.mp4: red, green,
//   blue, a second each): every combination of a start, a duration, audio
//   on or off and a frame rate set or not answers once with a video of the
//   requested length (± 50 ms), cut at the end of the input, whose first and
//   last frames are the colours at the requested start and end, with an
//   audio track of that length exactly when audio is included; a start
//   before 0 or at or past the end, or a duration that is not positive,
//   answers one compressVideo error.
// - cancelCompression: with no compress running it answers once and leaves
//   nothing for the next compress; a cancel just after the compress starts,
//   one while its export reports progress, and one that arrives after the
//   export has completed but before its answer is delivered each answer the
//   compress exactly once, `{"isCancel": true}` with no path, and leave no
//   output file; the first two stop the export; the next compress completes
//   normally.
// Every check runs on each of the plugin's loading paths the OS can run:
// AVFoundation's async `load` API (iOS 16+, macOS 13+) and the older
// synchronous one, selected with `AvController.usesAsyncLoading`; on iOS and
// macOS 26+ the compress checks also run with the video composition built by
// AVMutableVideoComposition's async factory instead of
// AVVideoComposition.Configuration (`usesVideoCompositionConfiguration`),
// and on iOS 18+ and macOS 15+ with `exportAsynchronously` instead of
// `export(to:as:)` (`usesAsyncExport`); the synchronous loading path also
// exports with `exportAsynchronously`.
// Exits 1 on any failed check, or when no check ran.
#if os(iOS)
import Flutter
typealias Plugin = SwiftVideoCompressPlugin
let platform = "iOS"
func osHasAsyncLoading() -> Bool {
    if #available(iOS 16.0, *) { return true }
    return false
}
#else
import FlutterMacOS
typealias Plugin = VideoCompressPlugin
let platform = "macOS"
func osHasAsyncLoading() -> Bool {
    if #available(macOS 13.0, *) { return true }
    return false
}
#endif
import ImageIO
import AVFoundation

/// Whether the OS has `AVVideoComposition.Configuration` (iOS 26, macOS
/// 26), which the plugin uses for a compress at a set frame rate; where it
/// does, the harness also runs the AVMutableVideoComposition path it
/// replaces. Only a compiler with that SDK (Swift 6.2) builds the plugin's
/// use of it.
func osHasVideoCompositionConfiguration() -> Bool {
    #if compiler(>=6.2)
    if #available(iOS 26.0, macOS 26.0, *) { return true }
    #endif
    return false
}

/// Whether the OS has `AVAssetExportSession.export(to:as:)` (iOS 18, macOS
/// 15), which the plugin's compress uses; where it does, the harness also
/// runs the `exportAsynchronously` path it replaces. Only a compiler with
/// that SDK (Swift 6.0) builds the plugin's use of it.
func osHasAsyncExport() -> Bool {
    #if compiler(>=6.0)
    if #available(iOS 18.0, macOS 15.0, *) { return true }
    #endif
    return false
}

struct NoMessenger: FlutterBinaryMessenger {}

let fixtures = CommandLine.arguments[1]
let channel = FlutterMethodChannel(name: "video_compress", binaryMessenger: NoMessenger())
let plugin = Plugin(channel: channel)
var loadingPath = ""
var checks = 0
var failures: [String] = []

func check(_ ok: Bool, _ what: @autoclosure () -> String) {
    checks += 1
    if !ok { failures.append("[\(loadingPath)] \(what())") }
}

/// Every answer the plugin gives to one call of [method] on fixture [name].
func answers(_ method: String, _ name: String, _ extra: [String: Any] = [:]) -> [Any?] {
    var answers: [Any?] = []
    let arguments = extra.merging(["path": "\(fixtures)/\(name)"]) { $1 }
    plugin.handle(FlutterMethodCall(methodName: method, arguments: arguments)) {
        answers.append($0)
    }
    return answers
}

func fileSize(_ name: String) -> Int {
    let attributes = try! FileManager.default.attributesOfItem(atPath: "\(fixtures)/\(name)")
    return (attributes[.size] as! NSNumber).intValue
}

/// The JSON the call answered, or nil (and a failed check) when it did not
/// answer exactly one JSON string.
func info(_ name: String) -> [String: Any]? {
    let all = answers("getMediaInfo", name)
    guard all.count == 1, let string = all[0] as? String,
          let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)),
          let json = object as? [String: Any] else {
        check(false, "\(name): expected one JSON answer, got \(all)")
        return nil
    }
    return json
}

func checkOneError(_ method: String, _ name: String, _ extra: [String: Any] = [:]) {
    let all = answers(method, name, extra)
    let error = all.first as? FlutterError
    check(all.count == 1 && error?.message == "\(method) error",
          "\(method) \(name): expected one \(method) error, got \(all)")
}

func number(_ json: [String: Any], _ key: String) -> Double? {
    return (json[key] as? NSNumber)?.doubleValue
}

/// The width and height of [data] when it is a JPEG image.
func jpegSize(_ data: Data) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetType(source) as String? == "public.jpeg",
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return (image.width, image.height)
}

/// The colour at the centre of each quadrant of [image] (top left, top right,
/// bottom left, bottom right): "red", "green", "blue", "white", or the hex
/// value of anything else.
func quadrants(_ image: CGImage) -> [String] {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return [] }
    // Row 0 of the bitmap is the top of the image.
    return [(1, 1), (3, 1), (1, 3), (3, 3)].map { (qx, qy) -> String in
        let offset = (qy * height / 4 * width + qx * width / 4) * 4
        let (r, g, b) = (pixels[offset], pixels[offset + 1], pixels[offset + 2])
        switch (r > 160, g > 160, b > 160) {
        case (true, true, true): return "white"
        case (true, false, false): return "red"
        case (false, true, false): return "green"
        case (false, false, true): return "blue"
        default: return String(format: "#%02x%02x%02x", r, g, b)
        }
    }
}

/// How AVFoundation displays [url]'s video halfway in, as a player shows it
/// (the preferred transform applied): its size and the colour of each
/// quadrant. Read independently of the plugin. Nil when no frame is read.
func displayed(_ url: URL) -> (width: Int, height: Int, quadrants: [String])? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    guard let image = try? generator.copyCGImage(at: CMTime(value: 1, timescale: 2), actualTime: nil) else {
        return nil
    }
    return (image.width, image.height, quadrants(image))
}

struct Video {
    let name: String
    let title: String
    /// The getMediaInfo answer: orientation, width, height.
    let orientation: Int
    let width: Int
    let height: Int
    /// How AVFoundation displays it, which the thumbnails show: its size
    /// and, for the quadrant fixtures, the colour of each quadrant.
    let displayedWidth: Int
    let displayedHeight: Int
    let displayedQuadrants: [String]?
}

/// A fixture whose displayed size is the reported size.
func video(_ name: String, title: String = "", _ orientation: Int, _ width: Int, _ height: Int,
           _ quadrants: [String]? = nil) -> Video {
    return Video(name: name, title: title, orientation: orientation, width: width, height: height,
                 displayedWidth: width, displayedHeight: height, displayedQuadrants: quadrants)
}

// Every video fixture is stored 64 x 48. The transformed ones are
// video_quadrants.mp4 (red, green / blue, white) under the transform a
// camera writes for a quarter, half and three-quarter turn, a horizontal and
// a vertical mirror, and a mirror across either diagonal; and untransformed
// with the video as track 2 (video_audio_first.mp4)
// (make_rotated_fixtures.swift). The orientation rule (AvController
// .getVideoOrientation, the same on Android): a transform that is exactly a
// quarter turn reports that turn; any other, mirrors included, reports 0 and
// the stored size. AVFoundation still displays a mirror mirrored, so a
// diagonal mirror's thumbnail is 48 x 64 while its reported size is 64 x 48.
let videos = [
    video("video.mp4", title: "Clip", 0, 64, 48),
    video("video_no_metadata.mp4", 0, 64, 48),
    video("video_quadrants.mp4", 0, 64, 48, ["red", "green", "blue", "white"]),
    video("video_rot90.mp4", 90, 48, 64, ["blue", "red", "white", "green"]),
    video("video_rot180.mp4", 180, 64, 48, ["white", "blue", "green", "red"]),
    video("video_rot270.mp4", 270, 48, 64, ["green", "white", "red", "blue"]),
    video("video_mirror_h.mp4", 0, 64, 48, ["green", "red", "white", "blue"]),
    video("video_mirror_v.mp4", 0, 64, 48, ["blue", "white", "red", "green"]),
    video("video_audio_first.mp4", 0, 64, 48, ["red", "green", "blue", "white"]),
    Video(name: "video_transpose.mp4", title: "", orientation: 0, width: 64, height: 48,
          displayedWidth: 48, displayedHeight: 64, displayedQuadrants: ["red", "blue", "green", "white"]),
    Video(name: "video_antitranspose.mp4", title: "", orientation: 0, width: 64, height: 48,
          displayedWidth: 48, displayedHeight: 64, displayedQuadrants: ["white", "green", "blue", "red"]),
]
let unreadable = ["missing.mp4", "not_media.mp4", "empty.mp4"]

func checkMediaInfo() {
    unreadable.forEach { checkOneError("getMediaInfo", $0) }

    if let json = info("audio_only.m4a") {
        check(Set(json.keys) == ["path", "title", "author", "duration", "filesize"],
              "audio_only.m4a: keys \(json.keys.sorted())")
        check(json["path"] as? String == "\(fixtures)/audio_only.m4a", "audio_only.m4a: path \(json)")
        check(json["title"] as? String == "", "audio_only.m4a: title \(json)")
        let duration = number(json, "duration") ?? -1
        check(duration > 900 && duration < 1100, "audio_only.m4a: duration \(duration)")
        check(number(json, "filesize") == Double(fileSize("audio_only.m4a")),
              "audio_only.m4a: filesize \(json)")
    }

    for video in videos {
        let name = video.name
        guard let json = info(name) else { continue }
        check(Set(json.keys) == ["path", "title", "author", "duration", "filesize",
                                 "width", "height", "orientation"],
              "\(name): keys \(json.keys.sorted())")
        check(json["path"] as? String == "\(fixtures)/\(name)", "\(name): path \(json)")
        check(json["title"] as? String == video.title, "\(name): title \(json)")
        check(json["author"] as? String == "", "\(name): author \(json)")
        check(number(json, "duration") == 1000, "\(name): duration \(json)")
        check(number(json, "orientation") == Double(video.orientation),
              "\(name): orientation \(json)")
        check(number(json, "width") == Double(video.width), "\(name): width \(json)")
        check(number(json, "height") == Double(video.height), "\(name): height \(json)")
        check(number(json, "filesize") == Double(fileSize(name)), "\(name): filesize \(json)")
    }
}

/// The colour of each quadrant of the JPEG [data].
func jpegQuadrants(_ data: Data) -> [String]? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return quadrants(image)
}

func checkThumbnails() {
    let arguments: [String: Any] = ["quality": 50, "position": 0]
    for name in unreadable + ["audio_only.m4a"] {
        checkOneError("getByteThumbnail", name, arguments)
        checkOneError("getFileThumbnail", name, arguments)
    }

    for video in videos {
        let name = video.name
        let (width, height) = (video.displayedWidth, video.displayedHeight)
        // The first frame, and the last: 1000 ms is the end of these 1 s clips.
        for position in [0, 1000] {
            let arguments: [String: Any] = ["quality": 50, "position": position]
            let what = "\(name) at \(position) ms"

            let bytes = answers("getByteThumbnail", name, arguments)
            let byteData = bytes.first as? Data
            let byteSize = byteData.flatMap(jpegSize)
            check(bytes.count == 1 && byteSize?.0 == width && byteSize?.1 == height,
                  "getByteThumbnail \(what): expected one \(width)x\(height) JPEG, got \(bytes.count) answer(s), size \(String(describing: byteSize))")

            let files = answers("getFileThumbnail", name, arguments)
            let path = files.first as? String
            let fileData = path.flatMap { FileManager.default.contents(atPath: $0) }
            let fileSize = fileData.flatMap(jpegSize)
            check(files.count == 1 && fileSize?.0 == width && fileSize?.1 == height,
                  "getFileThumbnail \(what): expected one path to a \(width)x\(height) JPEG, got \(files), size \(String(describing: fileSize))")
            if let path = path { try? FileManager.default.removeItem(atPath: path) }

            // The thumbnail shows the frame as AVFoundation displays it.
            if let expected = video.displayedQuadrants {
                let byteQuadrants = byteData.flatMap(jpegQuadrants)
                check(byteQuadrants == expected,
                      "getByteThumbnail \(what): quadrants \(String(describing: byteQuadrants)), expected \(expected)")
                let fileQuadrants = fileData.flatMap(jpegQuadrants)
                check(fileQuadrants == expected,
                      "getFileThumbnail \(what): quadrants \(String(describing: fileQuadrants)), expected \(expected)")
            }
        }
    }
}

/// Every answer the plugin gives to one compressVideo call of fixture
/// [name] with [arguments], waiting up to 60 s: the export answers on the
/// main queue, so the main run loop runs while it waits.
func compressAnswers(_ name: String, _ arguments: [String: Any]) -> [Any?] {
    var answers: [Any?] = []
    let call = arguments.merging(["path": "\(fixtures)/\(name)", "deleteOrigin": false]) { $1 }
    plugin.handle(FlutterMethodCall(methodName: "compressVideo", arguments: call)) {
        answers.append($0)
    }
    let deadline = Date().addingTimeInterval(60)
    while answers.isEmpty && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    // A second answer would arrive on the main queue too.
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    return answers
}

/// The compressVideo argument sets checked: SSK's call (1920x1080, with
/// audio, the Dart API's default 30 fps), and the native call's other
/// paths: the video track alone, with and without a frame rate, and the
/// whole asset without a frame rate. Without a frame rate a video track
/// alone is exported through a composition that must carry the source's
/// preferred transform; with one, through a video composition that renders
/// the transform into the frames.
let compressions: [(String, [String: Any])] = [
    ("SSK's call", ["quality": 7, "includeAudio": true, "frameRate": 30]),
    ("video only at 30 fps", ["quality": 0, "includeAudio": false, "frameRate": 30]),
    ("video only", ["quality": 0, "includeAudio": false]),
    ("with audio", ["quality": 0, "includeAudio": true]),
]

/// compressVideo answers once, with the path of a readable video of the
/// input's length that is displayed as the input is: the same aspect and
/// the same colour in each quadrant.
func checkCompress() {
    for video in videos where video.displayedQuadrants != nil {
        let name = video.name
        guard let input = displayed(URL(fileURLWithPath: "\(fixtures)/\(name)")) else {
            check(false, "\(name): cannot read a displayed frame of the input")
            continue
        }
        check(input.quadrants == video.displayedQuadrants!,
              "\(name): input displayed as \(input.quadrants), expected \(video.displayedQuadrants!)")
        for (label, arguments) in compressions {
            let what = "compressVideo \(name) (\(label))"
            let all = compressAnswers(name, arguments)
            guard all.count == 1, let string = all[0] as? String,
                  let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)),
                  let json = object as? [String: Any], let path = json["path"] as? String else {
                check(false, "\(what): expected one JSON answer with a path, got \(all)")
                continue
            }
            check(json["isCancel"] as? Bool == false, "\(what): isCancel \(json)")
            let url = URL(fileURLWithPath: path)
            check(FileManager.default.fileExists(atPath: path), "\(what): no file at \(path)")
            let asset = AVURLAsset(url: url)
            check(!asset.tracks(withMediaType: .video).isEmpty, "\(what): no video track in the output")
            let seconds = asset.duration.seconds
            check(abs(seconds - 1) <= 0.05, "\(what): output lasts \(seconds) s, expected 1 s ± 0.05")
            if let output = displayed(url) {
                check((output.width > output.height) == (input.width > input.height),
                      "\(what): output displayed \(output.width)x\(output.height), input \(input.width)x\(input.height)")
                check(output.quadrants == input.quadrants,
                      "\(what): output displayed as \(output.quadrants), input as \(input.quadrants)")
            } else {
                check(false, "\(what): cannot read a displayed frame of the output")
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// The colour at the centre of [url]'s video at [time], as AVFoundation
/// displays it: "red", "green", "blue", "white" or a hex value; nil when no
/// frame is read.
func colour(_ url: URL, at time: CMTime) -> String? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
    // All four quadrant centres of a solid frame.
    let all = Set(quadrants(image))
    return all.count == 1 ? all.first : all.sorted().joined(separator: "/")
}

/// The length in seconds of [asset]'s first track of [type]; nil when it has
/// none.
func trackSeconds(_ asset: AVAsset, _ type: AVMediaType) -> Double? {
    return asset.tracks(withMediaType: type).first?.timeRange.duration.seconds
}

/// The trims checked on video_timed.mp4 (3 s: red, green, blue, a second
/// each): startTime, duration (seconds, as the Dart API sends them), the
/// output's length, and the colour of its first and last frame. The last
/// one asks for more than the video has: the output is cut at its end.
let trims: [(Int?, Int?, Double, String, String)] = [
    (nil, nil, 3, "red", "blue"),
    (1, 1, 1, "green", "green"),
    (0, 1, 1, "red", "red"),
    (2, nil, 1, "blue", "blue"),
    (nil, 2, 2, "red", "green"),
    (1, 5, 2, "green", "blue"),
]
/// startTime, duration pairs that name no part of the video.
let badTrims: [(Int?, Int?)] = [(3, nil), (4, 1), (-1, nil), (0, 0), (nil, -1)]

/// compressVideo honours startTime and duration with audio and without,
/// with a frame rate and without.
func checkTrim() {
    let name = "video_timed.mp4"
    for includeAudio in [true, false] {
        for frameRate in [30, nil] as [Int?] {
            var base: [String: Any] = ["quality": 0, "includeAudio": includeAudio]
            if let frameRate = frameRate { base["frameRate"] = frameRate }
            let how = "audio \(includeAudio), frameRate \(frameRate.map(String.init) ?? "none")"
            for (start, length, seconds, first, last) in trims {
                var arguments = base
                if let start = start { arguments["startTime"] = NSNumber(value: start) }
                if let length = length { arguments["duration"] = NSNumber(value: length) }
                let what = "compressVideo \(name) startTime \(start.map(String.init) ?? "none") duration \(length.map(String.init) ?? "none") (\(how))"
                let all = compressAnswers(name, arguments)
                guard all.count == 1, let string = all[0] as? String,
                      let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)),
                      let json = object as? [String: Any], let path = json["path"] as? String else {
                    check(false, "\(what): expected one JSON answer with a path, got \(all)")
                    continue
                }
                let url = URL(fileURLWithPath: path)
                let asset = AVURLAsset(url: url)
                let answered = (number(json, "duration") ?? -1) / 1000
                check(abs(answered - seconds) <= 0.05,
                      "\(what): answered duration \(answered) s, expected \(seconds) s ± 0.05")
                let video = trackSeconds(asset, .video) ?? -1
                check(abs(video - seconds) <= 0.05,
                      "\(what): video track lasts \(video) s, expected \(seconds) s ± 0.05")
                let audio = trackSeconds(asset, .audio)
                if includeAudio {
                    check(audio.map { abs($0 - seconds) <= 0.05 } ?? false,
                          "\(what): audio track lasts \(String(describing: audio)) s, expected \(seconds) s ± 0.05")
                } else {
                    check(audio == nil, "\(what): an audio track (\(String(describing: audio)) s) in a video-only output")
                }
                let firstColour = colour(url, at: .zero)
                check(firstColour == first, "\(what): first frame \(String(describing: firstColour)), expected \(first)")
                let end = CMTimeMakeWithSeconds(seconds - 0.05, preferredTimescale: 600)
                let lastColour = colour(url, at: end)
                check(lastColour == last, "\(what): frame at \(end.seconds) s \(String(describing: lastColour)), expected \(last)")
                try? FileManager.default.removeItem(at: url)
            }
            for (start, length) in badTrims {
                var arguments = base
                if let start = start { arguments["startTime"] = NSNumber(value: start) }
                if let length = length { arguments["duration"] = NSNumber(value: length) }
                let all = compressAnswers(name, arguments)
                let error = all.first as? FlutterError
                check(all.count == 1 && error?.message == "compressVideo error",
                      "compressVideo \(name) startTime \(start.map(String.init) ?? "none") duration \(length.map(String.init) ?? "none") (\(how)): expected one compressVideo error, got \(all)")
            }
        }
    }
}

/// How each export ended ("completed", "cancelled", "failed"), recorded by
/// AvController.exportEnded on whatever thread the export ended on.
let endsLock = NSLock()
var exportEnds: [String] = []
let exportEndedSignal = DispatchSemaphore(value: 0)
func recordExportEnd(_ end: String) {
    endsLock.lock()
    exportEnds.append(end)
    endsLock.unlock()
    exportEndedSignal.signal()
}

/// The export ends recorded since the last call, waiting up to 60 s for one
/// when none has been recorded; the main run loop runs while it waits.
func takeExportEnds() -> [String] {
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        endsLock.lock()
        let ends = exportEnds
        endsLock.unlock()
        if !ends.isEmpty { break }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    // A second end would be recorded by then.
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
    endsLock.lock()
    let ends = exportEnds
    exportEnds = []
    endsLock.unlock()
    while exportEndedSignal.wait(timeout: .now()) == .success {}
    return ends
}

/// The compressed videos in the plugin's output folder.
func outputs() -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: Utility.basePath())) ?? []
    return Set(names.filter { $0.hasSuffix(".mp4") })
}

/// Starts a compress of [name] with SSK's arguments; its answers are
/// appended to the returned box as they arrive.
final class Answers { var all: [Any?] = [] }
func startCompress(_ name: String) -> Answers {
    let box = Answers()
    let call: [String: Any] = ["path": "\(fixtures)/\(name)", "deleteOrigin": false,
                               "quality": 7, "includeAudio": true, "frameRate": 30]
    plugin.handle(FlutterMethodCall(methodName: "compressVideo", arguments: call)) {
        box.all.append($0)
    }
    return box
}

/// The answers of [method] with no arguments.
func call(_ method: String) -> [Any?] {
    var all: [Any?] = []
    plugin.handle(FlutterMethodCall(methodName: method, arguments: nil)) { all.append($0) }
    return all
}

/// Whether [answer] is exactly `{"isCancel": true}`.
func isCancelAnswer(_ answer: Any?) -> Bool {
    guard let string = answer as? String,
          let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)),
          let json = object as? [String: Any] else { return false }
    return json.count == 1 && json["isCancel"] as? Bool == true
}

/// A compress of video_quadrants.mp4 after [scenario] completes normally:
/// one answer with a path and isCancel false.
func checkNextCompressCompletes(_ scenario: String) {
    let all = compressAnswers("video_quadrants.mp4", ["quality": 7, "includeAudio": true, "frameRate": 30])
    let json = (all.first as? String).flatMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
    let path = json?["path"] as? String
    check(all.count == 1 && json?["isCancel"] as? Bool == false && path != nil,
          "compress after \(scenario): expected one answer with a path, got \(all)")
    if let path = path { try? FileManager.default.removeItem(atPath: path) }
    _ = takeExportEnds()
}

/// cancelCompression answers the running compress exactly once,
/// `{"isCancel": true}` with no path, deletes its output and stops its
/// export, wherever it lands; a late end of the export is ignored, and the
/// next compress is unaffected.
func checkCancel() {
    _ = takeExportEndsNow()
    let before = outputs()

    // Nothing running.
    let idle = call("cancelCompression")
    check(idle.count == 1 && idle.first as? String == "", "cancel with nothing running: answered \(idle)")
    checkNextCompressCompletes("a cancel with nothing running")

    // Just after the compress starts, before the main run loop turns.
    var compress = startCompress("video_long.mp4")
    var cancelled = call("cancelCompression")
    check(cancelled.count == 1, "cancel just after the start: the cancel answered \(cancelled)")
    var ends = takeExportEnds()
    check(compress.all.count == 1 && isCancelAnswer(compress.all.first ?? nil),
          "cancel just after the start: the compress answered \(compress.all), expected one {\"isCancel\": true}")
    check(ends == ["cancelled"], "cancel just after the start: the export ended \(ends), expected [cancelled]")
    check(outputs() == before, "cancel just after the start: left \(outputs().subtracting(before))")
    checkNextCompressCompletes("a cancel just after the start")

    // While the export reports progress.
    var progress: [Double] = []
    channel.onInvoke = { method, arguments in
        if method == "updateProgress", let value = Double("\(arguments ?? "")") { progress.append(value) }
    }
    compress = startCompress("video_long.mp4")
    let deadline = Date().addingTimeInterval(60)
    while !progress.contains(where: { $0 > 0 }) && compress.all.isEmpty && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    check(compress.all.isEmpty && progress.contains(where: { $0 > 0 && $0 < 100 }),
          "cancel during the export: no progress reported before it answered \(compress.all) (progress \(progress))")
    let partial = outputs().subtracting(before)
    check(partial.count == 1, "cancel during the export: partial outputs \(partial) before the cancel, expected one")
    cancelled = call("cancelCompression")
    check(cancelled.count == 1, "cancel during the export: the cancel answered \(cancelled)")
    check(compress.all.count == 1 && isCancelAnswer(compress.all.first ?? nil),
          "cancel during the export: the compress answered \(compress.all) at the cancel, expected one {\"isCancel\": true}")
    // Deleted by the time the cancel answers, not only once the export ends.
    check(outputs().isDisjoint(with: partial),
          "cancel during the export: \(partial) still there when the cancel answered")
    let progressAtCancel = progress.count
    ends = takeExportEnds()
    check(compress.all.count == 1, "cancel during the export: the compress answered \(compress.all)")
    check(ends == ["cancelled"], "cancel during the export: the export ended \(ends), expected [cancelled]")
    check(progress.count == progressAtCancel,
          "cancel during the export: \(progress.count - progressAtCancel) progress report(s) after the answer")
    check(outputs() == before, "cancel during the export: left \(outputs().subtracting(before))")
    channel.onInvoke = nil
    checkNextCompressCompletes("a cancel during the export")

    // After the export completed, before its answer is delivered: the main
    // thread waits for the export to end, so the answer is still queued
    // behind the cancel.
    compress = startCompress("video_timed.mp4")
    let ended = exportEndedSignal.wait(timeout: .now() + 60) == .success
    check(ended, "cancel racing the completion: the export did not end in 60 s")
    check(compress.all.isEmpty, "cancel racing the completion: answered \(compress.all) before the cancel")
    cancelled = call("cancelCompression")
    check(cancelled.count == 1, "cancel racing the completion: the cancel answered \(cancelled)")
    ends = takeExportEnds()
    check(ends == ["completed"], "cancel racing the completion: the export ended \(ends), expected [completed]")
    check(compress.all.count == 1 && isCancelAnswer(compress.all.first ?? nil),
          "cancel racing the completion: the compress answered \(compress.all), expected one {\"isCancel\": true}")
    check(outputs() == before, "cancel racing the completion: left \(outputs().subtracting(before))")
    checkNextCompressCompletes("a cancel racing the completion")

    // A second cancel finds nothing running.
    let again = call("cancelCompression")
    check(again.count == 1 && again.first as? String == "", "a second cancel: answered \(again)")
    checkNextCompressCompletes("a second cancel")
}

/// Clears the recorded export ends without waiting.
func takeExportEndsNow() -> [String] {
    endsLock.lock()
    let ends = exportEnds
    exportEnds = []
    endsLock.unlock()
    while exportEndedSignal.wait(timeout: .now()) == .success {}
    return ends
}

let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
var pathsRun: [String] = []
// (name, async loading, video composition configuration, async export,
// compress only). The second and third paths run only the compress checks:
// they differ from the first only in how a compress at a set frame rate
// builds its video composition, and in which API exports.
let paths: [(String, Bool, Bool, Bool, Bool)] = [
    ("async load", true, true, true, false),
    ("async load, AVMutableVideoComposition", true, false, true, true),
    ("async load, exportAsynchronously", true, true, false, true),
    ("synchronous load", false, true, false, false),
]
AvController.exportEnded = recordExportEnd
for (name, async, configuration, asyncExport, compressOnly) in paths {
    // An async path runs only where the OS has its API; the plugin would
    // take the older one there anyway.
    if async && !osHasAsyncLoading() { continue }
    if async && !configuration && !osHasVideoCompositionConfiguration() { continue }
    if async && !asyncExport && !osHasAsyncExport() { continue }
    AvController.usesAsyncLoading = async
    AvController.usesVideoCompositionConfiguration = configuration
    AvController.usesAsyncExport = asyncExport
    loadingPath = name
    pathsRun.append(name)
    if !compressOnly {
        checkMediaInfo()
        checkThumbnails()
    }
    checkCompress()
    checkTrim()
    checkCancel()
}

if failures.isEmpty && checks > 0 {
    print("video_compress (\(platform) \(osVersion); \(pathsRun.joined(separator: ", "))): all \(checks) checks passed")
} else {
    failures.forEach { print("FAIL \($0)") }
    print("video_compress (\(platform) \(osVersion); \(pathsRun.joined(separator: ", "))): \(failures.count) of \(checks) checks failed")
    exit(1)
}

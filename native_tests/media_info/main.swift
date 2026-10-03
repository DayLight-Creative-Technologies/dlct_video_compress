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
// Every check runs on each of the plugin's loading paths the OS can run:
// AVFoundation's async `load` API (iOS 16+, macOS 13+) and the older
// synchronous one, selected with `AvController.usesAsyncLoading`; on iOS and
// macOS 26+ the compress checks also run with the video composition built by
// AVMutableVideoComposition's async factory instead of
// AVVideoComposition.Configuration (`usesVideoCompositionConfiguration`).
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

struct NoMessenger: FlutterBinaryMessenger {}

let fixtures = CommandLine.arguments[1]
let plugin = Plugin(
    channel: FlutterMethodChannel(name: "video_compress", binaryMessenger: NoMessenger()))
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
// a vertical mirror, and a mirror across either diagonal
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

let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
var pathsRun: [String] = []
// (name, async loading, video composition configuration, compress only).
// The second path runs only the compress checks: it differs from the first
// only in how a compress at a set frame rate builds its video composition.
let paths: [(String, Bool, Bool, Bool)] = [
    ("async load", true, true, false),
    ("async load, AVMutableVideoComposition", true, false, true),
    ("synchronous load", false, true, false),
]
for (name, async, configuration, compressOnly) in paths {
    // An async path runs only where the OS has its API; the plugin would
    // take the older one there anyway.
    if async && !osHasAsyncLoading() { continue }
    if async && !configuration && !osHasVideoCompositionConfiguration() { continue }
    AvController.usesAsyncLoading = async
    AvController.usesVideoCompositionConfiguration = configuration
    loadingPath = name
    pathsRun.append(name)
    if !compressOnly {
        checkMediaInfo()
        checkThumbnails()
    }
    checkCompress()
}

if failures.isEmpty && checks > 0 {
    print("video_compress (\(platform) \(osVersion); \(pathsRun.joined(separator: ", "))): all \(checks) checks passed")
} else {
    failures.forEach { print("FAIL \($0)") }
    print("video_compress (\(platform) \(osVersion); \(pathsRun.joined(separator: ", "))): \(failures.count) of \(checks) checks failed")
    exit(1)
}

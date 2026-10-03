// [DLCT] Runs the plugin's real channel calls on each fixture and checks every
// answer, on macOS (run_macos.sh: macos/Classes) and on an iOS simulator
// (run_ios.sh: ios/Classes):
// - getMediaInfo: exactly one answer per call; an error for a file that
//   cannot be read as media; the fields a file has, and none it lacks (never
//   0); the filesize is the file's size in bytes; the width and height are
//   the displayed size and the orientation the clockwise turn that displays
//   it, as Android reports them (0, 90, 180, 270).
// - getByteThumbnail and getFileThumbnail: exactly one answer per call; a
//   JPEG of the displayed size, also at the end of the video (SSK asks for
//   the frame at 1000 ms of clips that may be 1 s long); an error for a file
//   without a video frame.
// Every check runs on both of the plugin's loading paths the OS can run:
// AVFoundation's async `load` API (iOS 16+, macOS 13+) and the older
// synchronous one, selected with `AvController.usesAsyncLoading`. Exits 1 on
// any failed check, or when no check ran.
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

struct Video {
    let name: String
    let title: String
    let orientation: Int
    let width: Int
    let height: Int
}

// Every video fixture is stored 64 x 48; the rotated ones carry the preferred
// transform a camera writes for a quarter, half and three-quarter turn
// (make_rotated_fixtures.swift).
let videos = [
    Video(name: "video.mp4", title: "Clip", orientation: 0, width: 64, height: 48),
    Video(name: "video_no_metadata.mp4", title: "", orientation: 0, width: 64, height: 48),
    Video(name: "video_rot90.mp4", title: "", orientation: 90, width: 48, height: 64),
    Video(name: "video_rot180.mp4", title: "", orientation: 180, width: 64, height: 48),
    Video(name: "video_rot270.mp4", title: "", orientation: 270, width: 48, height: 64),
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

func checkThumbnails() {
    let arguments: [String: Any] = ["quality": 50, "position": 0]
    for name in unreadable + ["audio_only.m4a"] {
        checkOneError("getByteThumbnail", name, arguments)
        checkOneError("getFileThumbnail", name, arguments)
    }

    for video in videos {
        let name = video.name
        // The first frame, and the last: 1000 ms is the end of these 1 s clips.
        for position in [0, 1000] {
            let arguments: [String: Any] = ["quality": 50, "position": position]
            let what = "\(name) at \(position) ms"

            let bytes = answers("getByteThumbnail", name, arguments)
            let byteSize = (bytes.first as? Data).flatMap(jpegSize)
            check(bytes.count == 1 && byteSize?.0 == video.width && byteSize?.1 == video.height,
                  "getByteThumbnail \(what): expected one \(video.width)x\(video.height) JPEG, got \(bytes.count) answer(s), size \(String(describing: byteSize))")

            let files = answers("getFileThumbnail", name, arguments)
            let path = files.first as? String
            let fileSize = path.flatMap { FileManager.default.contents(atPath: $0) }.flatMap(jpegSize)
            check(files.count == 1 && fileSize?.0 == video.width && fileSize?.1 == video.height,
                  "getFileThumbnail \(what): expected one path to a \(video.width)x\(video.height) JPEG, got \(files), size \(String(describing: fileSize))")
            if let path = path { try? FileManager.default.removeItem(atPath: path) }
        }
    }
}

let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
var pathsRun: [String] = []
for (name, async) in [("async load", true), ("synchronous load", false)] {
    // The async path runs only where the OS has the API; the plugin would
    // take the synchronous one there anyway.
    if async && !osHasAsyncLoading() { continue }
    AvController.usesAsyncLoading = async
    loadingPath = name
    pathsRun.append(name)
    checkMediaInfo()
    checkThumbnails()
}

if failures.isEmpty && checks > 0 {
    print("video_compress (\(platform) \(osVersion); \(pathsRun.joined(separator: ", "))): all \(checks) checks passed")
} else {
    failures.forEach { print("FAIL \($0)") }
    print("video_compress (\(platform) \(osVersion); \(pathsRun.joined(separator: ", "))): \(failures.count) of \(checks) checks failed")
    exit(1)
}

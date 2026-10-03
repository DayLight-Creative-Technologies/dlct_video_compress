// [DLCT] Runs the macOS plugin's real `getMediaInfo` channel call on each
// fixture and checks every answer: exactly one per call; an error for a file
// that cannot be read as media; the fields a file has, and none it lacks
// (never 0); the filesize is the file's size in bytes. Exits 1 on any
// mismatch. Built and run by run.sh.
import FlutterMacOS

struct NoMessenger: FlutterBinaryMessenger {}

let fixtures = CommandLine.arguments[1]
let plugin = VideoCompressPlugin(
    channel: FlutterMethodChannel(name: "video_compress", binaryMessenger: NoMessenger()))
var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    if !ok { failures.append(what) }
}

/// Every answer the plugin gives to one getMediaInfo call.
func answers(_ name: String) -> [Any?] {
    var answers: [Any?] = []
    let call = FlutterMethodCall(methodName: "getMediaInfo",
                                 arguments: ["path": "\(fixtures)/\(name)"])
    plugin.handle(call) { answers.append($0) }
    return answers
}

func fileSize(_ name: String) -> Int {
    let attributes = try! FileManager.default.attributesOfItem(atPath: "\(fixtures)/\(name)")
    return (attributes[.size] as! NSNumber).intValue
}

/// The JSON the call answered, or nil (and a failure) when it did not answer
/// exactly one JSON string.
func info(_ name: String) -> [String: Any]? {
    let all = answers(name)
    guard all.count == 1, let string = all[0] as? String,
          let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)),
          let json = object as? [String: Any] else {
        failures.append("\(name): expected one JSON answer, got \(all)")
        return nil
    }
    return json
}

func checkUnreadable(_ name: String) {
    let all = answers(name)
    let error = all.first as? FlutterError
    check(all.count == 1 && error?.message == "getMediaInfo error",
          "\(name): expected one getMediaInfo error, got \(all)")
}

func number(_ json: [String: Any], _ key: String) -> Double? {
    return (json[key] as? NSNumber)?.doubleValue
}

checkUnreadable("missing.mp4")
checkUnreadable("not_media.mp4")
checkUnreadable("empty.mp4")

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

for (name, title) in [("video.mp4", "Clip"), ("video_no_metadata.mp4", "")] {
    guard let json = info(name) else { continue }
    check(Set(json.keys) == ["path", "title", "author", "duration", "filesize",
                             "width", "height", "orientation"],
          "\(name): keys \(json.keys.sorted())")
    check(json["path"] as? String == "\(fixtures)/\(name)", "\(name): path \(json)")
    check(json["title"] as? String == title, "\(name): title \(json)")
    check(json["author"] as? String == "", "\(name): author \(json)")
    check(number(json, "duration") == 1000, "\(name): duration \(json)")
    check(number(json, "width") == 64, "\(name): width \(json)")
    check(number(json, "height") == 48, "\(name): height \(json)")
    check(json["orientation"] is NSNumber, "\(name): orientation \(json)")
    check(number(json, "filesize") == Double(fileSize(name)), "\(name): filesize \(json)")
}

if failures.isEmpty {
    print("getMediaInfo (macOS): all checks passed")
} else {
    failures.forEach { print("FAIL \($0)") }
    exit(1)
}

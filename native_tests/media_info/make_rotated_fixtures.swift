// [DLCT] Writes the rotated fixtures: video_no_metadata.mp4's samples,
// unchanged, under each of the preferred transforms the Camera app writes
// for a quarter, half and three-quarter turn (rotation plus the translation
// that moves the turned frame back into view).
// Usage: swift native_tests/media_info/make_rotated_fixtures.swift native_tests/media_info/fixtures
import AVFoundation

let dir = CommandLine.arguments[1]
let source = AVURLAsset(url: URL(fileURLWithPath: "\(dir)/video_no_metadata.mp4"))
let video = source.tracks(withMediaType: .video)[0]
let size = video.naturalSize
let transforms: [Int: CGAffineTransform] = [
    90: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0),
    180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height),
    270: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width),
]

for (angle, transform) in transforms.sorted(by: { $0.key < $1.key }) {
    let composition = AVMutableComposition()
    let range = CMTimeRange(start: .zero, duration: source.duration)
    for track in source.tracks {
        let copy = composition.addMutableTrack(withMediaType: track.mediaType,
                                               preferredTrackID: kCMPersistentTrackID_Invalid)!
        try! copy.insertTimeRange(range, of: track, at: .zero)
        if track.mediaType == .video { copy.preferredTransform = transform }
    }
    let output = URL(fileURLWithPath: "\(dir)/video_rot\(angle).mp4")
    try? FileManager.default.removeItem(at: output)
    let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
    export.outputURL = output
    export.outputFileType = .mp4
    let done = DispatchSemaphore(value: 0)
    export.exportAsynchronously { done.signal() }
    done.wait()
    guard export.status == .completed else {
        print("video_rot\(angle).mp4: \(export.error.map { "\($0)" } ?? "\(export.status)")")
        exit(1)
    }
    print("video_rot\(angle).mp4: \(transform)")
}

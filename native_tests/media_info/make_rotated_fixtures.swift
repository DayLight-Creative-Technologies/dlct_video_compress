// [DLCT] Writes the transformed fixtures. First video_quadrants.mp4: 1 s of
// 64 x 48 H.264 frames whose four quadrants are solid red (top left), green
// (top right), blue (bottom left) and white (bottom right), with
// video_no_metadata.mp4's audio, so that where each colour ends up shows how
// a frame is displayed. Then the same samples, unchanged, under each preferred
// transform below (the linear part plus the translation that moves the
// transformed frame back into view):
// - video_rot90|180|270.mp4: the transforms the Camera app writes for a
//   quarter, half and three-quarter clockwise turn;
// - video_mirror_h.mp4, video_mirror_v.mp4: a horizontal and a vertical
//   mirror;
// - video_transpose.mp4, video_antitranspose.mp4: a mirror across either
//   diagonal (a mirrored quarter turn).
// Usage: swift native_tests/media_info/make_rotated_fixtures.swift native_tests/media_info/fixtures
import AVFoundation
import CoreVideo

let dir = CommandLine.arguments[1]
let width = 64
let height = 48

func fail(_ message: String) -> Never {
    print(message)
    exit(1)
}

/// Writes the quadrant frames, video only, to [url].
func writeQuadrants(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard writer.startWriting() else { fail("video_quadrants.mp4: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)

    // BGRA of each quadrant: red, green / blue, white.
    let colours: [[UInt8]] = [[0, 0, 255, 255], [0, 255, 0, 255], [255, 0, 0, 255], [255, 255, 255, 255]]
    for frame in 0..<30 {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var buffer: CVPixelBuffer? = nil
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<height {
            for x in 0..<width {
                let colour = colours[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)]
                for channel in 0..<4 { base[y * rowBytes + x * 4 + channel] = colour[channel] }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        guard adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
            fail("video_quadrants.mp4: frame \(frame): \(String(describing: writer.error))")
        }
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { fail("video_quadrants.mp4: \(String(describing: writer.error))") }
}

/// Exports [video]'s video track and [audio]'s audio track, unchanged, to
/// [name] with the video track's preferred transform set to [transform].
func export(_ name: String, video: AVAsset, audio: AVAsset, transform: CGAffineTransform) {
    let composition = AVMutableComposition()
    let range = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
    let videoCopy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try! videoCopy.insertTimeRange(range, of: video.tracks(withMediaType: .video)[0], at: .zero)
    videoCopy.preferredTransform = transform
    let audioCopy = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try! audioCopy.insertTimeRange(range, of: audio.tracks(withMediaType: .audio)[0], at: .zero)

    let output = URL(fileURLWithPath: "\(dir)/\(name)")
    try? FileManager.default.removeItem(at: output)
    let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
    session.outputURL = output
    session.outputFileType = .mp4
    let done = DispatchSemaphore(value: 0)
    session.exportAsynchronously { done.signal() }
    done.wait()
    guard session.status == .completed else {
        fail("\(name): \(session.error.map { "\($0)" } ?? "\(session.status)")")
    }
    print("\(name): \(transform)")
}

let w = CGFloat(width)
let h = CGFloat(height)
let transforms: [(String, CGAffineTransform)] = [
    ("video_quadrants.mp4", .identity),
    ("video_rot90.mp4", CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)),
    ("video_rot180.mp4", CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)),
    ("video_rot270.mp4", CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)),
    ("video_mirror_h.mp4", CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)),
    ("video_mirror_v.mp4", CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)),
    ("video_transpose.mp4", CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)),
    ("video_antitranspose.mp4", CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)),
]

let raw = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("video_quadrants_raw.mp4")
writeQuadrants(raw)
let quadrants = AVURLAsset(url: raw)
let audio = AVURLAsset(url: URL(fileURLWithPath: "\(dir)/video_no_metadata.mp4"))
for (name, transform) in transforms {
    export(name, video: quadrants, audio: audio, transform: transform)
}
try? FileManager.default.removeItem(at: raw)

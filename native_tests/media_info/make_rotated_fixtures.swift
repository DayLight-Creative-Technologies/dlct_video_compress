// [DLCT] Writes the generated fixtures.
//
// First video_quadrants.mp4: 1 s of 64 x 48 H.264 frames whose four quadrants
// are solid red (top left), green (top right), blue (bottom left) and white
// (bottom right), with video_no_metadata.mp4's audio, so that where each
// colour ends up shows how a frame is displayed. Then the same samples,
// unchanged, under each preferred transform below (the linear part plus the
// translation that moves the transformed frame back into view):
// - video_rot90|180|270.mp4: the transforms the Camera app writes for a
//   quarter, half and three-quarter clockwise turn;
// - video_mirror_h.mp4, video_mirror_v.mp4: a horizontal and a vertical
//   mirror;
// - video_transpose.mp4, video_antitranspose.mp4: a mirror across either
//   diagonal (a mirrored quarter turn).
// And video_audio_first.mp4: the quadrant samples untransformed, with the
// audio as track 1 and the video as track 2 (as some recorders write them),
// so that nothing can rely on the video track's ID being 1.
//
// Then the fixtures whose content changes over time:
// - video_timed.mp4: 3 s of 64 x 48 frames at 30 fps, solid red for the
//   first second, green for the second and blue for the third, with a key
//   frame every 45 frames (at 0 s and 1.5 s, so a trim at 1 s or 2 s starts
//   between key frames), and 3 s of audio. Where a trimmed compress starts and ends shows in the
//   colour of its first and last frame.
// - video_long.mp4: 10 s of 1280 x 720 frames at 30 fps, each a solid colour
//   with a moving white bar, and 10 s of audio: an export long enough to be
//   cancelled while it runs.
//
// Usage: swift native_tests/media_info/make_rotated_fixtures.swift native_tests/media_info/fixtures [name ...]
// With names, only those fixtures are written.
import AVFoundation
import CoreVideo

let dir = CommandLine.arguments[1]
let width = 64
let height = 48

func fail(_ message: String) -> Never {
    print(message)
    exit(1)
}

/// Writes [frames] frames of [width] x [height] H.264 video at 30 fps, video
/// only, to [url], with a key frame at most every [keyFrameInterval] frames.
/// [paint] fills row [y] of frame [frame] with BGRA pixels.
func writeFrames(_ url: URL, width: Int, height: Int, frames: Int, keyFrameInterval: Int,
                 paint: (_ frame: Int, _ y: Int, _ row: UnsafeMutablePointer<UInt8>) -> Void) {
    try? FileManager.default.removeItem(at: url)
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: keyFrameInterval],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard writer.startWriting() else { fail("\(url.lastPathComponent): \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)

    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var buffer: CVPixelBuffer? = nil
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<height {
            paint(frame, y, base + y * rowBytes)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        guard adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
            fail("\(url.lastPathComponent): frame \(frame): \(String(describing: writer.error))")
        }
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 30))
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { fail("\(url.lastPathComponent): \(String(describing: writer.error))") }
}

/// Writes [seconds] of one continuous AAC stream (a 440 Hz tone, mono,
/// 44.1 kHz) to [url]. (Splicing a shorter clip's audio end to end instead
/// leaves an edit per splice, which Android's extractor ignores, decoding
/// every splice's padding too: the audio would be longer there than here.)
func writeAudio(_ url: URL, seconds: Int) {
    try? FileManager.default.removeItem(at: url)
    let rate = 44100
    let writer = try! AVAssetWriter(outputURL: url, fileType: .m4a)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64000,
    ])
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    guard writer.startWriting() else { fail("\(url.lastPathComponent): \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)

    var pcm = AudioStreamBasicDescription(
        mSampleRate: Float64(rate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
        mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription? = nil
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &pcm, layoutSize: 0, layout: nil,
                                   magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                   formatDescriptionOut: &format)
    let total = rate * seconds
    var written = 0
    while written < total {
        let count = min(rate / 10, total - written)
        let samples = (0..<count).map { n -> Int16 in
            Int16(8000 * sin(2 * Double.pi * 440 * Double(written + n) / Double(rate)))
        }
        var block: CMBlockBuffer? = nil
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: count * 2, flags: kCMBlockBufferAssureMemoryNowFlag,
                                           blockBufferOut: &block)
        samples.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!,
                                              offsetIntoDestination: 0, dataLength: count * 2)
        }
        var buffer: CMSampleBuffer? = nil
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &buffer)
        while !input.isReadyForMoreMediaData { usleep(1000) }
        guard input.append(buffer!) else { fail("\(url.lastPathComponent): \(String(describing: writer.error))") }
        written += count
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { fail("\(url.lastPathComponent): \(String(describing: writer.error))") }
}

/// Fills [count] BGRA pixels from [row] with [colour].
func fill(_ row: UnsafeMutablePointer<UInt8>, _ count: Int, _ colour: [UInt8]) {
    for x in 0..<count {
        for channel in 0..<4 { row[x * 4 + channel] = colour[channel] }
    }
}

// BGRA.
let red: [UInt8] = [0, 0, 255, 255]
let green: [UInt8] = [0, 255, 0, 255]
let blue: [UInt8] = [255, 0, 0, 255]
let white: [UInt8] = [255, 255, 255, 255]

/// Writes the quadrant frames, video only, to [url]: 1 s of red, green /
/// blue, white.
func writeQuadrants(_ url: URL) {
    writeFrames(url, width: width, height: height, frames: 30, keyFrameInterval: 30) { _, y, row in
        let top = y < height / 2
        fill(row, width / 2, top ? red : blue)
        fill(row + width / 2 * 4, width - width / 2, top ? green : white)
    }
}

/// Exports the first [seconds] of [video]'s video track and of [audio]'s
/// audio track, unchanged, to [name] with the
/// video track's preferred transform set to [transform].
func export(_ name: String, video: AVAsset, audio: AVAsset, transform: CGAffineTransform = .identity,
            seconds: Int = 1, audioFirst: Bool = false) {
    let composition = AVMutableComposition()
    let range = CMTimeRange(start: .zero, duration: CMTime(value: CMTimeValue(seconds), timescale: 1))
    // The file's track IDs follow the order the tracks are added in.
    func addVideo() {
        let videoCopy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try! videoCopy.insertTimeRange(range, of: video.tracks(withMediaType: .video)[0], at: .zero)
        videoCopy.preferredTransform = transform
    }
    func addAudio() {
        let audioCopy = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try! audioCopy.insertTimeRange(range, of: audio.tracks(withMediaType: .audio)[0], at: .zero)
    }
    if audioFirst {
        addAudio()
        addVideo()
    } else {
        addVideo()
        addAudio()
    }

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
    print("\(name): \(transform), \(seconds) s\(audioFirst ? ", audio track 1, video track 2" : "")")
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

let only = Set(CommandLine.arguments.dropFirst(2))
func wanted(_ name: String) -> Bool { only.isEmpty || only.contains(name) }
let temp = URL(fileURLWithPath: NSTemporaryDirectory())
let audio = AVURLAsset(url: URL(fileURLWithPath: "\(dir)/video_no_metadata.mp4"))

if transforms.contains(where: { wanted($0.0) }) || wanted("video_audio_first.mp4") {
    let raw = temp.appendingPathComponent("video_quadrants_raw.mp4")
    writeQuadrants(raw)
    let quadrants = AVURLAsset(url: raw)
    for (name, transform) in transforms where wanted(name) {
        export(name, video: quadrants, audio: audio, transform: transform)
    }
    if wanted("video_audio_first.mp4") {
        export("video_audio_first.mp4", video: quadrants, audio: audio, audioFirst: true)
    }
    try? FileManager.default.removeItem(at: raw)
}

if wanted("video_timed.mp4") {
    let raw = temp.appendingPathComponent("video_timed_raw.mp4")
    let colours = [red, green, blue]
    writeFrames(raw, width: width, height: height, frames: 90, keyFrameInterval: 45) { frame, _, row in
        fill(row, width, colours[frame / 30])
    }
    let tone = temp.appendingPathComponent("tone_3s.m4a")
    writeAudio(tone, seconds: 3)
    export("video_timed.mp4", video: AVURLAsset(url: raw), audio: AVURLAsset(url: tone), seconds: 3)
    try? FileManager.default.removeItem(at: raw)
    try? FileManager.default.removeItem(at: tone)
}

if wanted("video_long.mp4") {
    let raw = temp.appendingPathComponent("video_long_raw.mp4")
    let (longWidth, longHeight) = (1280, 720)
    let colours = [red, green, blue]
    writeFrames(raw, width: longWidth, height: longHeight, frames: 300, keyFrameInterval: 30) { frame, _, row in
        fill(row, longWidth, colours[(frame / 30) % 3])
        fill(row + (frame * 8) % (longWidth - 32) * 4, 32, white)
    }
    let tone = temp.appendingPathComponent("tone_10s.m4a")
    writeAudio(tone, seconds: 10)
    export("video_long.mp4", video: AVURLAsset(url: raw), audio: AVURLAsset(url: tone), seconds: 10)
    try? FileManager.default.removeItem(at: raw)
    try? FileManager.default.removeItem(at: tone)
}

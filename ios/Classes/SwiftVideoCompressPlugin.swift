import Flutter
import AVFoundation

// MARK: - Track Property Loading Helpers

private func loadTrackFrameRate(_ track: AVAssetTrack) -> Float {
    if #available(iOS 16.0, *), AvController.usesAsyncLoading {
        var result: Float = 30.0
        let group = DispatchGroup()
        group.enter()
        Task {
            result = (try? await track.load(.nominalFrameRate)) ?? 30.0
            group.leave()
        }
        group.wait()
        return result
    } else {
        return track.nominalFrameRate
    }
}

/// The track's natural size; nil when it cannot be loaded (it used to be
/// .zero, reported as a 0 x 0 video).
private func loadTrackNaturalSize(_ track: AVAssetTrack) -> CGSize? {
    if #available(iOS 16.0, *), AvController.usesAsyncLoading {
        var result: CGSize? = nil
        let group = DispatchGroup()
        group.enter()
        Task {
            result = try? await track.load(.naturalSize)
            group.leave()
        }
        group.wait()
        return result
    } else {
        return track.naturalSize
    }
}

/// The track's preferred transform; nil when it cannot be loaded.
private func loadTrackPreferredTransform(_ track: AVAssetTrack) -> CGAffineTransform? {
    if #available(iOS 16.0, *), AvController.usesAsyncLoading {
        var result: CGAffineTransform? = nil
        let group = DispatchGroup()
        group.enter()
        Task {
            result = try? await track.load(.preferredTransform)
            group.leave()
        }
        group.wait()
        return result
    } else {
        return track.preferredTransform
    }
}

/// The asset's duration; nil when it cannot be loaded or is not a number
/// (indefinite or invalid). It used to be .zero when it could not be loaded,
/// reported as a 0 ms video, and an invalid duration's NaN crashed the JSON
/// encoding of the media info.
private func loadAssetDuration(_ asset: AVAsset) -> CMTime? {
    var result: CMTime? = nil
    if #available(iOS 16.0, *), AvController.usesAsyncLoading {
        let group = DispatchGroup()
        group.enter()
        Task {
            result = try? await asset.load(.duration)
            group.leave()
        }
        group.wait()
    } else {
        result = asset.duration
    }
    guard let duration = result, duration.isNumeric else { return nil }
    return duration
}

/// The frame [generator] makes at [time]; nil when it cannot be read.
/// `copyCGImage(at:actualTime:)` is deprecated since iOS 18; `image(at:)`
/// is its async replacement from iOS 16 on.
private func loadImage(_ generator: AVAssetImageGenerator, at time: CMTime) -> CGImage? {
    if #available(iOS 16.0, *), AvController.usesAsyncLoading {
        var result: CGImage? = nil
        let group = DispatchGroup()
        group.enter()
        Task {
            result = try? await generator.image(at: time).image
            group.leave()
        }
        group.wait()
        return result
    } else {
        return try? generator.copyCGImage(at: time, actualTime: nil)
    }
}

/// A video composition that renders [asset]'s video as it is displayed
/// (each track's preferred transform applied, at the displayed size), one
/// frame every [frameDuration]; nil when the asset's properties cannot be
/// loaded. iOS 26+ builds it from an `AVVideoComposition.Configuration`
/// (`AVMutableVideoComposition` is deprecated there), iOS 16-25 with the
/// async `videoComposition(withPropertiesOf:)`, and older iOS with
/// `init(propertiesOf:)`, deprecated since iOS 18 (SSK gap #911).
private func loadVideoComposition(_ asset: AVAsset, frameDuration: CMTime) -> AVVideoComposition? {
    if #available(iOS 16.0, *), AvController.usesAsyncLoading {
        var result: AVVideoComposition? = nil
        let group = DispatchGroup()
        group.enter()
        Task {
            // The iOS 26 API is compiled only by a compiler that has its SDK
            // (Xcode 26, Swift 6.2); an older Xcode builds the iOS 16 path.
            #if compiler(>=6.2)
            if #available(iOS 26.0, *), AvController.usesVideoCompositionConfiguration {
                if var configuration = try? await AVVideoComposition.Configuration(for: asset) {
                    configuration.frameDuration = frameDuration
                    result = AVVideoComposition(configuration: configuration)
                }
                group.leave()
                return
            }
            #endif
            if let composition = try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset) {
                composition.frameDuration = frameDuration
                result = composition
            }
            group.leave()
        }
        group.wait()
        return result
    } else {
        let composition = AVMutableVideoComposition(propertiesOf: asset)
        composition.frameDuration = frameDuration
        return composition
    }
}

// MARK: - Plugin

public class SwiftVideoCompressPlugin: NSObject, FlutterPlugin {
    private let channelName = "video_compress"
    /// The compress running now, if any: what `cancelCompression` stops.
    /// Read and written on the main thread only.
    private var pending: PendingCompress? = nil
    private let channel: FlutterMethodChannel
    private let avController = AvController()

    init(channel: FlutterMethodChannel) {
        self.channel = channel
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "video_compress", binaryMessenger: registrar.messenger())
        let instance = SwiftVideoCompressPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? Dictionary<String, Any>
        switch call.method {
        case "getByteThumbnail":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let position = args!["position"] as! NSNumber
            getByteThumbnail(path, quality, position, result)
        case "getFileThumbnail":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let position = args!["position"] as! NSNumber
            getFileThumbnail(path, quality, position, result)
        case "getMediaInfo":
            let path = args!["path"] as! String
            getMediaInfo(path, result)
        case "compressVideo":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let deleteOrigin = args!["deleteOrigin"] as! Bool
            let startTime = args!["startTime"] as? Double
            let duration = args!["duration"] as? Double
            let includeAudio = args!["includeAudio"] as? Bool
            let frameRate = args!["frameRate"] as? Int
            compressVideo(path, quality, deleteOrigin, startTime, duration, includeAudio,
                          frameRate, result)
        case "cancelCompression":
            cancelCompression(result)
        case "deleteAllCache":
            Utility.deleteFile(Utility.basePath(), clear: true)
            result(true)
        case "setLogLevel":
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// A JPEG of the frame at [position] milliseconds (the unit the Dart API
    /// documents; it used to be read as seconds, so `position: 1000` asked
    /// for the frame 1000 s in). A negative position is the first frame. Nil
    /// when the video has no video track or the frame cannot be read.
    private func getBitMap(_ path: String,_ quality: NSNumber,_ position: NSNumber)-> Data?  {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return nil }

        let assetImgGenerate = AVAssetImageGenerator(asset: asset)
        assetImgGenerate.appliesPreferredTrackTransform = true

        let timeScale = CMTimeScale(loadTrackFrameRate(track))
        let positionSeconds = max(0, Float64(truncating: position) / 1000)
        let requested = CMTimeMakeWithSeconds(positionSeconds, preferredTimescale: timeScale)
        // Clamped to the video's length when it is known.
        let time = loadAssetDuration(asset).map { CMTimeMinimum(requested, $0) } ?? requested
        guard let img = loadImage(assetImgGenerate, at: time) else {
            return nil
        }
        let thumbnail = UIImage(cgImage: img)
        let compressionQuality = CGFloat(0.01 * Double(truncating: quality))
        return thumbnail.jpegData(compressionQuality: compressionQuality)
    }

    /// Every path answers: a frame that cannot be read answers a FlutterError
    /// (it used to answer nothing, so the Dart caller waited forever).
    private func getByteThumbnail(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult) {
        guard let bitmap = getBitMap(path,quality,position) else {
            return result(FlutterError(code: channelName, message: "getByteThumbnail error",
                                       details: "Could not read a frame of \(path)"))
        }
        result(bitmap)
    }

    /// Every path answers: a frame that cannot be read answers a FlutterError
    /// (it used to answer nothing, so the Dart caller waited forever).
    private func getFileThumbnail(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult) {
        let fileName = Utility.getFileName(path)
        let url = Utility.getPathUrl("\(Utility.basePath())/\(fileName).jpg")
        guard let bitmap = getBitMap(path,quality,position) else {
            return result(FlutterError(code: channelName, message: "getFileThumbnail error",
                                       details: "Could not read a frame of \(path)"))
        }
        guard (try? bitmap.write(to: url)) != nil else {
            return result(FlutterError(code: channelName,message: "getFileThumbnail error",details: "getFileThumbnail error"))
        }
        result(Utility.excludeFileProtocol(url.absoluteString))
    }

    /// The media info of the file at [path]; nil when it cannot be read as
    /// media at all. Anything the file does not have (a video track, a
    /// duration) leaves its fields absent, never 0. (A file without a video
    /// track, or one that could not be read, used to answer `{}`, without
    /// even its path; a size, transform or duration that could not be loaded
    /// was reported as 0.) The filesize is the file's size in bytes, as on
    /// Android; it used to be the video track's sample bytes only. The width
    /// and height are the displayed size, and the orientation the clockwise
    /// turn that displays it, as on Android.
    public func getMediaInfoJson(_ path: String)->[String : Any]? {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let videoTracks = avController.loadVideoTracks(asset) else { return nil }

        var json: [String : Any] = [
            "path": Utility.excludeFileProtocol(path),
            "title": avController.getMetaDataByTag(asset, key: "title"),
            "author": avController.getMetaDataByTag(asset, key: "author"),
        ]
        if let duration = loadAssetDuration(asset) {
            json["duration"] = duration.seconds * 1000
        }
        if let filesize = Utility.fileSize(url) {
            json["filesize"] = filesize
        }
        if let track = videoTracks.first,
           let naturalSize = loadTrackNaturalSize(track),
           let transform = loadTrackPreferredTransform(track) {
            let orientation = avController.getVideoOrientation(transform)
            let size = avController.getDisplayedSize(naturalSize, orientation)
            json["width"] = size.width
            json["height"] = size.height
            json["orientation"] = orientation
        }
        return json
    }

    /// Answered exactly once: the info, or an error when the file cannot be
    /// read as media at all.
    private func getMediaInfo(_ path: String,_ result: FlutterResult) {
        guard let json = getMediaInfoJson(path) else {
            return result(FlutterError(code: channelName, message: "getMediaInfo error",
                                       details: "Cannot read \(path)"))
        }
        result(Utility.keyValueToJson(json))
    }


    private func getExportPreset(_ quality: NSNumber)->String {
        switch(quality) {
        case 1:
            return AVAssetExportPresetLowQuality
        case 2:
            return AVAssetExportPresetMediumQuality
        case 3:
            return AVAssetExportPresetHighestQuality
        case 4:
            return AVAssetExportPreset640x480
        case 5:
            return AVAssetExportPreset960x540
        case 6:
            return AVAssetExportPreset1280x720
        case 7:
            return AVAssetExportPreset1920x1080
        default:
            return AVAssetExportPresetMediumQuality
        }
    }

    /// The asset to export: the source itself with its audio, or a
    /// composition of its video track alone, displayed as the source is (its
    /// preferred transform, loaded with `load(.preferredTransform)` on iOS
    /// 16+, SSK gap #911). The composition holds [timeRange] of the track at
    /// the same time it has in the source, so the one export range,
    /// [timeRange], selects the same part of either asset (it used to be
    /// inserted at 0 while the export range still started at the start time,
    /// so a video-only compress from a start time > 0 exported the wrong part
    /// or failed, SSK gap #913), and the source track's ID. Nil when the
    /// transform cannot be loaded (without it the output would be displayed
    /// unturned) or the range cannot be inserted.
    private func getComposition(_ isIncludeAudio: Bool,_ timeRange: CMTimeRange, _ sourceVideoTrack: AVAssetTrack)->AVAsset? {
        if isIncludeAudio {
            return sourceVideoTrack.asset!
        }
        guard let transform = loadTrackPreferredTransform(sourceVideoTrack) else { return nil }
        let composition = AVMutableComposition()
        // The source track's ID: the video composition of a compress at a set
        // frame rate is built from the source and names its track.
        guard let compressionVideoTrack = composition.addMutableTrack(
            withMediaType: AVMediaType.video, preferredTrackID: sourceVideoTrack.trackID) else { return nil }
        compressionVideoTrack.preferredTransform = transform
        guard (try? compressionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: timeRange.start)) != nil else {
            return nil
        }
        return composition
    }

    /// Exports [path] at [quality], [timeRange] of it only (`startTime`,
    /// `duration`: AvController.exportRange), with its audio unless
    /// [includeAudio] is false, at [frameRate] frames a second when one is
    /// given. Answered exactly once (PendingCompress): the output's media
    /// info with `isCancel` false; `{"isCancel": true}` with no path when
    /// `cancelCompression` stopped it; or a `compressVideo error`. The export
    /// range applies to every asset exported, so `startTime` and `duration`
    /// are honoured with audio too (they were ignored whenever audio was
    /// included, the default, SSK gap #913).
    private func compressVideo(_ path: String,_ quality: NSNumber,_ deleteOrigin: Bool,_ startTime: Double?,
                               _ duration: Double?,_ includeAudio: Bool?,_ frameRate: Int?,
                               _ result: @escaping FlutterResult) {
        let sourceVideoUrl = Utility.getPathUrl(path)
        let sourceVideoType = "mp4"

        let sourceVideoAsset = avController.getVideoAsset(sourceVideoUrl)
        guard let sourceVideoTrack = avController.getTrack(sourceVideoAsset) else {
            return result(FlutterError(code: channelName, message: "compressVideo error",
                                       details: "No video track in \(path)"))
        }

        let uuid = NSUUID()
        let compressionUrl =
        Utility.getPathUrl("\(Utility.basePath())/\(Utility.getFileName(path))\(uuid.uuidString).\(sourceVideoType)")

        // Without a length there is no time range to export (an unloadable
        // duration used to be .zero: a 0 s export).
        guard let assetDuration = loadAssetDuration(sourceVideoAsset) else {
            return result(FlutterError(code: channelName, message: "compressVideo error",
                                       details: "Cannot read the duration of \(path)"))
        }
        guard let timeRange = avController.exportRange(startTime: startTime, duration: duration,
                                                       length: assetDuration) else {
            return result(FlutterError(
                code: channelName, message: "compressVideo error",
                details: "startTime \(String(describing: startTime)) and duration \(String(describing: duration)) name no part of the \(assetDuration.seconds) s of \(path)"))
        }

        let isIncludeAudio = includeAudio ?? true

        guard let session = getComposition(isIncludeAudio, timeRange, sourceVideoTrack) else {
            return result(FlutterError(code: channelName, message: "compressVideo error",
                                       details: "Cannot read the video track of \(path)"))
        }

        guard let exporter = AVAssetExportSession(asset: session, presetName: getExportPreset(quality)) else {
            return result(FlutterError(code: channelName, message: "compressVideo error",
                                       details: "Cannot export \(path) with preset \(getExportPreset(quality))"))
        }

        exporter.shouldOptimizeForNetworkUse = true
        exporter.timeRange = timeRange

        if let frameRate = frameRate {
            // Built from the source, whose properties give the displayed
            // render size; its instructions name the source's video track,
            // whose ID a video-only composition keeps (getComposition).
            guard let videoComposition = loadVideoComposition(
                sourceVideoAsset, frameDuration: CMTimeMake(value: 1, timescale: Int32(frameRate))) else {
                return result(FlutterError(code: channelName, message: "compressVideo error",
                                           details: "Cannot read the video properties of \(path)"))
            }
            exporter.videoComposition = videoComposition
        }

        Utility.deleteFile(compressionUrl.path)

        let channel = self.channel
        let compress = PendingCompress(outputURL: compressionUrl, result: result) { percent in
            channel.invokeMethod("updateProgress", arguments: "\(String(describing: percent))")
        }
        pending = compress
        let finish: (ExportEnd) -> Void = { end in
            self.finishCompress(compress, end, path, deleteOrigin)
        }
        // The iOS 18 API is compiled only by a compiler that has its SDK
        // (Xcode 16, Swift 6.0); an older Xcode builds the older path only.
        #if compiler(>=6.0)
        if #available(iOS 18.0, *), AvController.usesAsyncExport {
            exportWithAsyncAPI(exporter, compress, finish)
            return
        }
        #endif
        exportWithCompletionHandler(exporter, compress, finish)
    }

    #if compiler(>=6.0)
    /// iOS 18+: `export(to:as:)`, its progress from `states(updateInterval:)`.
    /// A cancel cancels the task the export runs in.
    @available(iOS 18.0, *)
    private func exportWithAsyncAPI(_ exporter: AVAssetExportSession, _ compress: PendingCompress,
                                    _ finish: @escaping (ExportEnd) -> Void) {
        let progress = Task {
            for await state in exporter.states(updateInterval: 0.1) {
                if case .exporting(let progress) = state {
                    let percent = Float(progress.fractionCompleted) * 100
                    DispatchQueue.main.async { compress.reportProgress(percent) }
                }
            }
        }
        let url = compress.outputURL
        let export = Task {
            let end: ExportEnd
            do {
                try await exporter.export(to: url, as: .mp4)
                end = .completed
            } catch {
                end = Task.isCancelled || error is CancellationError
                    ? .cancelled : .failed(error.localizedDescription)
            }
            progress.cancel()
            AvController.exportEnded?(end.name)
            DispatchQueue.main.async { finish(end) }
        }
        compress.stopExport = { export.cancel() }
    }
    #endif

    /// Below iOS 18: `exportAsynchronously(completionHandler:)`, its outcome
    /// from this export's own `status` (never a flag a later compress could
    /// inherit: a cancel that arrived after the export finished used to leave
    /// a stop flag set, so the next compress answered "cancelled" with the
    /// INPUT's path, SSK gap #896).
    private func exportWithCompletionHandler(_ exporter: AVAssetExportSession, _ compress: PendingCompress,
                                             _ finish: @escaping (ExportEnd) -> Void) {
        exporter.outputURL = compress.outputURL
        exporter.outputFileType = AVFileType.mp4
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            compress.reportProgress(exporter.progress * 100)
        }
        exporter.exportAsynchronously(completionHandler: {
            let end: ExportEnd
            switch exporter.status {
            case .completed: end = .completed
            case .cancelled: end = .cancelled
            default: end = .failed(exporter.error?.localizedDescription)
            }
            AvController.exportEnded?(end.name)
            DispatchQueue.main.async {
                timer.invalidate()
                finish(end)
            }
        })
        compress.stopExport = { exporter.cancelExport() }
    }

    /// Answers [compress] with how its export ended, on the main thread,
    /// unless a cancel has answered it already: then whatever the export
    /// wrote is deleted and nothing else happens (a late completion after a
    /// cancel is ignored).
    private func finishCompress(_ compress: PendingCompress, _ end: ExportEnd, _ path: String,
                                _ deleteOrigin: Bool) {
        if pending === compress {
            pending = nil
        }
        let output = compress.outputURL
        switch end {
        case .completed:
            // An output that cannot be read is a failed compress, as on
            // Android, and the original is kept: it is deleted only once the
            // output is known to be readable (it used to be deleted first).
            guard var json = getMediaInfoJson(output.path) else {
                try? FileManager.default.removeItem(at: output)
                compress.answer(FlutterError(code: channelName, message: "compressVideo error",
                                             details: "Cannot read the compressed video"))
                return
            }
            json["isCancel"] = false
            guard compress.answer(Utility.keyValueToJson(json)) else {
                try? FileManager.default.removeItem(at: output)
                return
            }
            if deleteOrigin {
                let fileManager = FileManager.default
                do {
                    if fileManager.fileExists(atPath: path) {
                        try fileManager.removeItem(atPath: path)
                    }
                }
                catch let error as NSError {
                    print(error)
                }
            }
        case .cancelled:
            // No path: nothing was compressed, and the partial output is
            // deleted.
            try? FileManager.default.removeItem(at: output)
            compress.answer(Utility.keyValueToJson(["isCancel": true]))
        case .failed(let message):
            try? FileManager.default.removeItem(at: output)
            compress.answer(FlutterError(code: channelName, message: "compressVideo error",
                                         details: message))
        }
    }

    /// Stops the compress running now and answers it `{"isCancel": true}`
    /// at once, as on Android. The cancelled export removes its partial
    /// output itself, and whatever its own end, arriving later, finds is
    /// deleted (finishCompress), so the cancel leaves no output. A compress
    /// that already answered, or none at all, leaves nothing behind for a
    /// later compress.
    private func cancelCompression(_ result: FlutterResult) {
        if let compress = pending {
            pending = nil
            compress.stopExport?()
            compress.answer(Utility.keyValueToJson(["isCancel": true]))
        }
        result("")
    }

}

/// How a compress's export ended.
private enum ExportEnd {
    case completed
    case cancelled
    case failed(String?)

    var name: String {
        switch self {
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }
}

/// One compress: its output and its result, answered exactly once (a cancel
/// and the export's own end can both try to answer it), how to stop its
/// export, and where its progress goes until it is answered. Used on the
/// main thread only: the export's own threads reach it through the main
/// queue, which is what makes it safe to send there.
private final class PendingCompress: @unchecked Sendable {
    let outputURL: URL
    private let result: FlutterResult
    private let onProgress: (Float) -> Void
    private(set) var answered = false
    var stopExport: (() -> Void)? = nil

    init(outputURL: URL, result: @escaping FlutterResult, onProgress: @escaping (Float) -> Void) {
        self.outputURL = outputURL
        self.result = result
        self.onProgress = onProgress
    }

    /// Reports [percent] done, unless the compress has been answered.
    func reportProgress(_ percent: Float) {
        if !answered { onProgress(percent) }
    }

    /// Answers [value] unless the compress has been answered; whether it
    /// answered.
    @discardableResult
    func answer(_ value: Any?) -> Bool {
        if answered { return false }
        answered = true
        result(value)
        return true
    }
}

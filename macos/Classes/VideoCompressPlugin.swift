import FlutterMacOS
import AVFoundation
import Cocoa

// MARK: - Track Property Loading Helpers
//
// Each reads through AVFoundation's async `load` API on macOS 13+, where the
// synchronous properties are deprecated, and through those properties on
// macOS 10.15-12, as the iOS plugin does on iOS 16+ and earlier.

private func loadTrackFrameRate(_ track: AVAssetTrack) -> Float {
    if #available(macOS 13.0, *), AvController.usesAsyncLoading {
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

/// The track's natural size; nil when it cannot be loaded.
private func loadTrackNaturalSize(_ track: AVAssetTrack) -> CGSize? {
    if #available(macOS 13.0, *), AvController.usesAsyncLoading {
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
    if #available(macOS 13.0, *), AvController.usesAsyncLoading {
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
/// (indefinite or invalid). An invalid duration's NaN used to crash the JSON
/// encoding of the media info.
private func loadAssetDuration(_ asset: AVAsset) -> CMTime? {
    var result: CMTime? = nil
    if #available(macOS 13.0, *), AvController.usesAsyncLoading {
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
/// `copyCGImage(at:actualTime:)` is deprecated since macOS 15; `image(at:)`
/// is its async replacement from macOS 13 on.
private func loadImage(_ generator: AVAssetImageGenerator, at time: CMTime) -> CGImage? {
    if #available(macOS 13.0, *), AvController.usesAsyncLoading {
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
/// loaded. macOS 26+ builds it from an `AVVideoComposition.Configuration`
/// (`AVMutableVideoComposition` is deprecated there), macOS 13-15 with the
/// async `videoComposition(withPropertiesOf:)`, and older macOS with
/// `init(propertiesOf:)`, deprecated since macOS 15 (SSK gap #911).
private func loadVideoComposition(_ asset: AVAsset, frameDuration: CMTime) -> AVVideoComposition? {
    if #available(macOS 13.0, *), AvController.usesAsyncLoading {
        var result: AVVideoComposition? = nil
        let group = DispatchGroup()
        group.enter()
        Task {
            // The macOS 26 API is compiled only by a compiler that has its SDK
            // (Xcode 26, Swift 6.2); an older Xcode builds the macOS 13 path.
            #if compiler(>=6.2)
            if #available(macOS 26.0, *), AvController.usesVideoCompositionConfiguration {
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

public class VideoCompressPlugin: NSObject, FlutterPlugin {
    private let channelName = "video_compress"
    /// The export running now, if any: what `cancelCompression` stops.
    /// Read and written on the main thread only.
    private var exporter: AVAssetExportSession? = nil
    private let channel: FlutterMethodChannel
    private let avController = AvController()
    
    init(channel: FlutterMethodChannel) {
        self.channel = channel
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "video_compress", binaryMessenger: registrar.messenger)
        let instance = VideoCompressPlugin(channel: channel)
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
    /// documents; it used to be read as seconds). A negative position is the
    /// first frame. Nil when the video has no video track or the frame cannot
    /// be read.
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

        let bitmapRep = NSBitmapImageRep(cgImage: img)
        let compressionFactor = NSNumber(value: 0.01 * Double(truncating: quality))
        return bitmapRep.representation(using: NSBitmapImageRep.FileType.jpeg,
                                        properties: [.compressionFactor: compressionFactor])
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
    /// even its path.) The filesize is the file's size in bytes, as on
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
    
    
    @objc private func updateProgress(timer:Timer) {
        let asset = timer.userInfo as! AVAssetExportSession
        if asset.status != .cancelled {
            channel.invokeMethod("updateProgress", arguments: "\(String(describing: asset.progress * 100))")
        }
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
    /// preferred transform, loaded with `load(.preferredTransform)` on macOS
    /// 13+, SSK gap #911). Nil when that transform cannot be loaded: without
    /// it the output would be displayed unrotated.
    private func getComposition(_ isIncludeAudio: Bool,_ timeRange: CMTimeRange, _ sourceVideoTrack: AVAssetTrack)->AVAsset? {
        let composition = AVMutableComposition()
        if !isIncludeAudio {
            guard let transform = loadTrackPreferredTransform(sourceVideoTrack) else { return nil }
            let compressionVideoTrack = composition.addMutableTrack(withMediaType: AVMediaType.video, preferredTrackID: kCMPersistentTrackID_Invalid)
            compressionVideoTrack!.preferredTransform = transform
            try? compressionVideoTrack!.insertTimeRange(timeRange, of: sourceVideoTrack, at: CMTime.zero)
        } else {
            return sourceVideoTrack.asset!
        }

        return composition
    }
    
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
        
        let compressionUrl =
            Utility.getPathUrl("\(Utility.basePath())/\(Utility.getFileName(path))\(NSUUID().uuidString).\(sourceVideoType)")
        
        // Without a length there is no time range to export (an invalid
        // duration used to make a NaN time range).
        guard let assetDuration = loadAssetDuration(sourceVideoAsset) else {
            return result(FlutterError(code: channelName, message: "compressVideo error",
                                       details: "Cannot read the duration of \(path)"))
        }
        let timescale = assetDuration.timescale
        let minStartTime = Double(startTime ?? 0)

        let videoDuration = assetDuration.seconds
        let minDuration = Double(duration ?? videoDuration)
        let maxDurationTime = minStartTime + minDuration < videoDuration ? minDuration : videoDuration
        
        let cmStartTime = CMTimeMakeWithSeconds(minStartTime, preferredTimescale: timescale)
        let cmDurationTime = CMTimeMakeWithSeconds(maxDurationTime, preferredTimescale: timescale)
        let timeRange: CMTimeRange = CMTimeRangeMake(start: cmStartTime, duration: cmDurationTime)
        
        let isIncludeAudio = includeAudio != nil ? includeAudio! : true
        
        guard let session = getComposition(isIncludeAudio, timeRange, sourceVideoTrack) else {
            return result(FlutterError(code: channelName, message: "compressVideo error",
                                       details: "Cannot read the orientation of \(path)"))
        }
        
        guard let exporter = AVAssetExportSession(asset: session, presetName: getExportPreset(quality)) else {
            return result(FlutterError(code: channelName, message: "compressVideo error",
                                       details: "Cannot export \(path) with preset \(getExportPreset(quality))"))
        }
        
        exporter.outputURL = compressionUrl
        exporter.outputFileType = AVFileType.mp4
        exporter.shouldOptimizeForNetworkUse = true
        
        if let frameRate = frameRate {
            guard let videoComposition = loadVideoComposition(
                sourceVideoAsset, frameDuration: CMTimeMake(value: 1, timescale: Int32(frameRate))) else {
                return result(FlutterError(code: channelName, message: "compressVideo error",
                                           details: "Cannot read the video properties of \(path)"))
            }
            exporter.videoComposition = videoComposition
        }
        
        if !isIncludeAudio {
            exporter.timeRange = timeRange
        }
        
        Utility.deleteFile(compressionUrl.path)
        
        let timer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(self.updateProgress),
                                         userInfo: exporter, repeats: true)
        
        // The outcome is read from this export's own status, on the main
        // thread: a cancel is this export's, never a flag a later compress
        // could inherit. (The stop flag this replaces outlived a cancel that
        // arrived after the export finished, and `exporter` was never set, so
        // a cancel stopped nothing.)
        exporter.exportAsynchronously(completionHandler: {
            DispatchQueue.main.async {
                timer.invalidate()
                if self.exporter === exporter {
                    self.exporter = nil
                }
                switch exporter.status {
                case .completed:
                    // An output that cannot be read is a failed compress, as
                    // on Android, and the original is kept: it is deleted
                    // only once the output is known to be readable (it used
                    // to be deleted first).
                    guard var json = self.getMediaInfoJson(compressionUrl.path) else {
                        try? FileManager.default.removeItem(at: compressionUrl)
                        result(FlutterError(code: self.channelName, message: "compressVideo error",
                                            details: "Cannot read the compressed video"))
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
                    json["isCancel"] = false
                    result(Utility.keyValueToJson(json))
                case .cancelled:
                    // No path: nothing was compressed, and the partial output
                    // is deleted.
                    try? FileManager.default.removeItem(at: compressionUrl)
                    result(Utility.keyValueToJson(["isCancel": true]))
                default:
                    try? FileManager.default.removeItem(at: compressionUrl)
                    result(FlutterError(code: self.channelName,
                                        message: "compressVideo error",
                                        details: exporter.error?.localizedDescription))
                }
            }
        })
        self.exporter = exporter
    }

    /// Stops the export running now; one that already finished, or none at
    /// all, leaves nothing behind for a later compress.
    private func cancelCompression(_ result: FlutterResult) {
        exporter?.cancelExport()
        result("")
    }
    
}

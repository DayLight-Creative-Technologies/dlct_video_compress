import FlutterMacOS
import AVFoundation
import Cocoa

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

        let timeScale = CMTimeScale(track.nominalFrameRate)
        let positionSeconds = max(0, Float64(truncating: position) / 1000)
        let requested = CMTimeMakeWithSeconds(positionSeconds, preferredTimescale: timeScale)
        let time = CMTimeMinimum(requested, asset.duration)
        guard let img = try? assetImgGenerate.copyCGImage(at:time, actualTime: nil) else {
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

    public func getMediaInfoJson(_ path: String)->[String : Any?] {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return [:] }
        
        let playerItem = AVPlayerItem(url: url)
        let metadataAsset = playerItem.asset
        
        let orientation = avController.getVideoOrientation(path)
        
        let title = avController.getMetaDataByTag(metadataAsset,key: "title")
        let author = avController.getMetaDataByTag(metadataAsset,key: "author")
        
        let duration = asset.duration.seconds * 1000
        let filesize = track.totalSampleDataLength
        
        let size = track.naturalSize.applying(track.preferredTransform)
        
        let width = abs(size.width)
        let height = abs(size.height)
        
        let dictionary = [
            "path":Utility.excludeFileProtocol(path),
            "title":title,
            "author":author,
            "width":width,
            "height":height,
            "duration":duration,
            "filesize":filesize,
            "orientation":orientation
            ] as [String : Any?]
        return dictionary
    }
    
    private func getMediaInfo(_ path: String,_ result: FlutterResult) {
        let json = getMediaInfoJson(path)
        let string = Utility.keyValueToJson(json)
        result(string)
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
    
    private func getComposition(_ isIncludeAudio: Bool,_ timeRange: CMTimeRange, _ sourceVideoTrack: AVAssetTrack)->AVAsset {
        let composition = AVMutableComposition()
        if !isIncludeAudio {
            let compressionVideoTrack = composition.addMutableTrack(withMediaType: AVMediaType.video, preferredTrackID: kCMPersistentTrackID_Invalid)
            compressionVideoTrack!.preferredTransform = sourceVideoTrack.preferredTransform
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
        
        let timescale = sourceVideoAsset.duration.timescale
        let minStartTime = Double(startTime ?? 0)
        
        let videoDuration = sourceVideoAsset.duration.seconds
        let minDuration = Double(duration ?? videoDuration)
        let maxDurationTime = minStartTime + minDuration < videoDuration ? minDuration : videoDuration
        
        let cmStartTime = CMTimeMakeWithSeconds(minStartTime, preferredTimescale: timescale)
        let cmDurationTime = CMTimeMakeWithSeconds(maxDurationTime, preferredTimescale: timescale)
        let timeRange: CMTimeRange = CMTimeRangeMake(start: cmStartTime, duration: cmDurationTime)
        
        let isIncludeAudio = includeAudio != nil ? includeAudio! : true
        
        let session = getComposition(isIncludeAudio, timeRange, sourceVideoTrack)
        
        guard let exporter = AVAssetExportSession(asset: session, presetName: getExportPreset(quality)) else {
            return result(FlutterError(code: channelName, message: "compressVideo error",
                                       details: "Cannot export \(path) with preset \(getExportPreset(quality))"))
        }
        
        exporter.outputURL = compressionUrl
        exporter.outputFileType = AVFileType.mp4
        exporter.shouldOptimizeForNetworkUse = true
        
        if frameRate != nil {
            let videoComposition = AVMutableVideoComposition(propertiesOf: sourceVideoAsset)
            videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(frameRate!))
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
                    var json = self.getMediaInfoJson(compressionUrl.path)
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

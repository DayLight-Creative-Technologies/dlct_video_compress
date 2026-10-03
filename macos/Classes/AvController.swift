
import AVFoundation
// import MobileCoreServices

class AvController: NSObject {
    /// Whether AVFoundation's async `load` API is used where the OS has it
    /// (macOS 13.0+). Only the native tests set it false, to run the older
    /// path on a newer OS as well.
    static var usesAsyncLoading = true

    public func getVideoAsset(_ url:URL)->AVURLAsset {
        return AVURLAsset(url: url)
    }
    
    /// The asset's video tracks, empty when it has none (an audio file); nil
    /// when the file cannot be read as media at all (it does not exist, or is
    /// not a format AVFoundation opens: loading its tracks fails).
    public func loadVideoTracks(_ asset: AVURLAsset)->[AVAssetTrack]? {
        var tracks : [AVAssetTrack]? = nil
        let group = DispatchGroup()
        group.enter()
        if #available(macOS 13.0, *), AvController.usesAsyncLoading {
            Task {
                tracks = try? await asset.loadTracks(withMediaType: .video)
                group.leave()
            }
        } else {
            asset.loadValuesAsynchronously(forKeys: ["tracks"], completionHandler: {
                var error: NSError? = nil;
                let status = asset.statusOfValue(forKey: "tracks", error: &error)
                if (status == .loaded) {
                    tracks = asset.tracks(withMediaType: AVMediaType.video)
                }
                group.leave()
            })
        }
        group.wait()
        return tracks
    }

    public func getTrack(_ asset: AVURLAsset)->AVAssetTrack? {
        return loadVideoTracks(asset)?.first
    }

    /// The clockwise turn, in degrees (0, 90, 180 or 270), that a track's
    /// preferred transform [txf] applies: the angle of its rotation, to the
    /// nearest quarter turn. Android reports the same angle for the same
    /// file. The transform's translation only moves the turned frame back
    /// into view. (The angle used to be read from the translation, so an
    /// untransformed track reported 90 and a portrait iPhone video 270, SSK
    /// gap #907.)
    public func getVideoOrientation(_ txf: CGAffineTransform)-> Int {
        let quarterTurns = Int((atan2(txf.b, txf.a) / (.pi / 2)).rounded())
        return (quarterTurns % 4 + 4) % 4 * 90
    }

    /// The displayed size of a track of [naturalSize] turned by
    /// [orientation] degrees: a quarter turn swaps width and height, as on
    /// Android.
    public func getDisplayedSize(_ naturalSize: CGSize,_ orientation: Int)-> CGSize {
        if orientation == 90 || orientation == 270 {
            return CGSize(width: naturalSize.height, height: naturalSize.width)
        }
        return naturalSize
    }

    public func getMetaDataByTag(_ asset:AVAsset,key:String)->String {
        if #available(macOS 13.0, *), AvController.usesAsyncLoading {
            let group = DispatchGroup()
            group.enter()
            var result = ""
            Task {
                do {
                    let metadata = try await asset.load(.commonMetadata)
                    for item in metadata {
                        if item.commonKey?.rawValue == key {
                            let value = try await item.load(.stringValue)
                            result = value ?? ""
                            break
                        }
                    }
                } catch {
                    // Use default
                }
                group.leave()
            }
            group.wait()
            return result
        } else {
            for item in asset.commonMetadata {
                if item.commonKey?.rawValue == key {
                    return item.stringValue ?? "";
                }
            }
            return ""
        }
    }
}

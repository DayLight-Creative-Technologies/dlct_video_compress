
import AVFoundation
// import MobileCoreServices

class AvController: NSObject {
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
        asset.loadValuesAsynchronously(forKeys: ["tracks"], completionHandler: {
            var error: NSError? = nil;
            let status = asset.statusOfValue(forKey: "tracks", error: &error)
            if (status == .loaded) {
                tracks = asset.tracks(withMediaType: AVMediaType.video)
            }
            group.leave()
        })
        group.wait()
        return tracks
    }

    public func getTrack(_ asset: AVURLAsset)->AVAssetTrack? {
        return loadVideoTracks(asset)?.first
    }

    /// The rotation of a video track with [size] and transform [txf]. (This
    /// used to reload the track from its path.)
    public func getVideoOrientation(_ size: CGSize,_ txf: CGAffineTransform)-> Int {
        if size.width == txf.tx && size.height == txf.ty {
            return 0
        } else if txf.tx == 0 && txf.ty == 0 {
            return 90
        } else if txf.tx == 0 && txf.ty == size.width {
            return 180
        } else {
            return 270
        }
    }
    
    public func getMetaDataByTag(_ asset:AVAsset,key:String)->String {
        for item in asset.commonMetadata {
            if item.commonKey?.rawValue == key {
                return item.stringValue ?? "";
            }
        }
        return ""
    }
}

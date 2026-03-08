
import AVFoundation
import MobileCoreServices

class AvController: NSObject {
    public func getVideoAsset(_ url:URL)->AVURLAsset {
        return AVURLAsset(url: url)
    }

    public func getTrack(_ asset: AVURLAsset)->AVAssetTrack? {
        var track : AVAssetTrack? = nil
        let group = DispatchGroup()
        group.enter()
        if #available(iOS 16.0, *) {
            Task {
                do {
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    track = tracks.first
                } catch {
                    // Failed to load tracks
                }
                group.leave()
            }
        } else {
            asset.loadValuesAsynchronously(forKeys: ["tracks"], completionHandler: {
                var error: NSError? = nil;
                let status = asset.statusOfValue(forKey: "tracks", error: &error)
                if (status == .loaded) {
                    track = asset.tracks(withMediaType: AVMediaType.video).first
                }
                group.leave()
            })
        }
        group.wait()
        return track
    }

    public func getVideoOrientation(_ path:String)-> Int? {
        let url = Utility.getPathUrl(path)
        let asset = getVideoAsset(url)
        guard let track = getTrack(asset) else {
            return nil
        }
        var size: CGSize
        var txf: CGAffineTransform
        if #available(iOS 16.0, *) {
            let group = DispatchGroup()
            group.enter()
            var loadedSize: CGSize = .zero
            var loadedTransform: CGAffineTransform = .identity
            Task {
                do {
                    loadedSize = try await track.load(.naturalSize)
                    loadedTransform = try await track.load(.preferredTransform)
                } catch {
                    // Use defaults
                }
                group.leave()
            }
            group.wait()
            size = loadedSize
            txf = loadedTransform
        } else {
            size = track.naturalSize
            txf = track.preferredTransform
        }
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
        if #available(iOS 16.0, *) {
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

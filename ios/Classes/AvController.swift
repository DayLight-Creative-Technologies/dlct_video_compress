
import AVFoundation
import MobileCoreServices

class AvController: NSObject {
    /// Whether AVFoundation's async `load` API is used where the OS has it
    /// (iOS 16.0+). Only the native tests set it false, to run the older
    /// path on a newer OS as well.
    static var usesAsyncLoading = true

    /// Whether a compress at a set frame rate builds its video composition
    /// from `AVVideoComposition.Configuration` where the OS has it (iOS
    /// 26.0+) rather than with `AVMutableVideoComposition`'s async factory.
    /// Only the native tests set it false, to run the iOS 16-25 path on a
    /// newer OS as well.
    static var usesVideoCompositionConfiguration = true

    /// Whether a compress exports with `AVAssetExportSession.export(to:as:)`
    /// where the OS has it (iOS 18.0+) rather than with
    /// `exportAsynchronously(completionHandler:)`, deprecated there. Only the
    /// native tests set it false, to run the older path on a newer OS as well.
    static var usesAsyncExport = true

    /// Called with how each compress's export itself ended: "completed",
    /// "cancelled" or "failed", on the thread the export ended on, before the
    /// compress is answered. Only the native tests set it, to see whether a
    /// cancel stopped the export and to hold an answer back.
    static var exportEnded: ((String) -> Void)? = nil

    /// The part of a video of [length] that a compress exports, the same rule
    /// on every platform: from [startTime] seconds (default 0) for [duration]
    /// seconds (default: to the end), cut at the end of the video. Nil when
    /// the arguments name no part of the video: a negative start, a start at
    /// or past the end, or a duration that is not positive.
    public func exportRange(startTime: Double?, duration: Double?, length: CMTime) -> CMTimeRange? {
        let start = startTime ?? 0
        let end = length.seconds
        guard start >= 0, start < end else { return nil }
        if let duration = duration, !(duration > 0) { return nil }
        let timescale = max(length.timescale, 600)
        let cmStart = CMTimeMakeWithSeconds(start, preferredTimescale: timescale)
        let cmEnd = duration.map {
            CMTimeMinimum(CMTimeMakeWithSeconds(start + $0, preferredTimescale: timescale), length)
        } ?? length
        return CMTimeRange(start: cmStart, end: cmEnd)
    }

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
        if #available(iOS 16.0, *), AvController.usesAsyncLoading {
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

    /// The clockwise turn, in degrees, that a track's preferred transform
    /// [txf] applies. The rule, the same on every platform (SSK gap #912):
    /// 90, 180 or 270 when the transform's matrix is exactly that quarter
    /// turn, and 0 for every other matrix: the identity, a mirror
    /// (horizontal, vertical, or across a diagonal), a scale, or any other
    /// angle. The translation is ignored: it only moves the turned frame back
    /// into view. This is the rotation Android's MediaMetadataRetriever
    /// reports for the same file: MPEG4Extractor recognizes exactly these
    /// four track-header matrices and reports 0 for any other (verified on
    /// Android 16 with the mirrored fixtures). A mirror is not a turn, so a
    /// mirrored video reports 0 and its stored size, although AVFoundation
    /// displays (and thumbnails) it mirrored. (Until 3.1.5+dlct.7 the angle
    /// was the rotation rounded to the nearest quarter turn, so a horizontal
    /// mirror reported 180 and a diagonal mirror 90 or 270; before
    /// 3.1.5+dlct.6 it was read from the translation, SSK gap #907.)
    public func getVideoOrientation(_ txf: CGAffineTransform)-> Int {
        switch (txf.a, txf.b, txf.c, txf.d) {
        case (0, 1, -1, 0): return 90
        case (-1, 0, 0, -1): return 180
        case (0, -1, 1, 0): return 270
        default: return 0
        }
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
        if #available(iOS 16.0, *), AvController.usesAsyncLoading {
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

import Foundation
import AVFoundation
import CoreAudioTypes

/// The container + codec a recording is written in.
///
/// The tap always hands us interleaved Float32; `AVAudioFile` converts to each
/// format's on-disk encoding on `write(from:)`, so switching formats is just a
/// different settings dictionary and file extension — no change to the capture path.
///
/// Note: macOS Core Audio has no MP3 *encoder* (only a decoder), so `.mp3` is
/// deliberately absent. `.aac` is the native small-file equivalent; true MP3 would
/// require bundling a third-party encoder (LAME) or an ffmpeg post-encode step.
public enum RecordingFormat: String, CaseIterable, Sendable {
    /// Float32 linear PCM in an Apple CAF container. Lossless, largest files (~90 MB/min),
    /// no 4 GB size limit. The closest thing to the raw tap samples; use when you need
    /// lossless. (Was the original default before `.aac` took over — see the enum note.)
    case caf
    /// 24-bit integer linear PCM in a WAV container. Lossless, universally compatible.
    case wav
    /// 24-bit integer linear PCM (big-endian) in an AIFF container. Mac-native.
    case aiff
    /// Lossy AAC in an MPEG-4 (.m4a) container. Small files, native encoder.
    case aac
    /// Apple Lossless (ALAC) in an MPEG-4 (.m4a) container. Lossless, ~50% of PCM size.
    case alac
    /// FLAC — open lossless codec, encoded natively by Core Audio.
    case flac

    /// File extension (no dot). AAC and ALAC both live in `.m4a`.
    public var fileExtension: String {
        switch self {
        case .caf:  return "caf"
        case .wav:  return "wav"
        case .aiff: return "aiff"
        case .aac, .alac: return "m4a"
        case .flac: return "flac"
        }
    }

    /// Best-guess format for a file extension, mirroring how AVAudioFile infers a
    /// container. `.m4a` is ambiguous (AAC or ALAC) and resolves to `.aac`; pick ALAC
    /// explicitly. Returns nil for unrecognized extensions.
    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "caf":                 self = .caf
        case "wav", "wave":         self = .wav
        case "aif", "aiff", "aifc": self = .aiff
        case "m4a", "aac", "mp4":   self = .aac
        case "flac":                self = .flac
        default:                    return nil
        }
    }

    /// Human-readable label for UI pickers.
    public var displayName: String {
        switch self {
        case .caf:  return "CAF (Float32)"
        case .wav:  return "WAV (24-bit)"
        case .aiff: return "AIFF (24-bit)"
        case .aac:  return "AAC (.m4a) — small, default"
        case .alac: return "Apple Lossless (.m4a)"
        case .flac: return "FLAC"
        }
    }

    /// Whether this format is lossless (bit-exact reconstruction of the tap samples).
    public var isLossless: Bool { self != .aac }

    /// `AVAudioFile` settings describing the on-disk encoding at the tap's sample rate
    /// and channel count. The buffers we write are always Float32; AVAudioFile handles
    /// the float→int / PCM→compressed conversion internally.
    public func settings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        switch self {
        case .caf:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        case .wav:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        case .aiff:
            // AIFF integer PCM is big-endian by definition.
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
        case .aac:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                // 128 kbps: transparent for spoken voice, ~1 MB/min — roughly 90× smaller
                // than Float32 CAF. The default; short conversations shouldn't be lossless.
                AVEncoderBitRateKey: 128_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        case .alac:
            return [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        case .flac:
            return [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        }
    }
}

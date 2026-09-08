import Foundation
import AVFoundation

/// Turns a finished recording's WAV into an AAC `.m4a` next to it.
///
/// A lecture is written as 16 kHz mono 16-bit PCM, which is 115 MB per hour: a 2h53 course
/// on disk is 377 MB, and the vault held 4.7 GB of them. At 24 kb/s the same hour is 11 MB,
/// and a 1h28 course encodes in about four seconds.
///
/// AAC rather than MP3 because macOS has no MP3 *encoder* — AudioToolbox decodes the format
/// and refuses to write it, so shipping MP3 would mean embedding LAME for a worse result
/// than what the system already does natively.
enum AudioCompressor {
    /// Speech at 16 kHz mono. Higher rates spend bytes on detail this content does not have.
    static let bitRate = 24_000

    /// Roughly four seconds of audio per pass at 16 kHz, so a 90-minute recording is
    /// encoded in ~1300 buffers instead of being held in memory whole.
    private static let framesPerPass: AVAudioFrameCount = 1 << 16

    /// AAC packs samples in 1024-frame packets and pads the last one, trimming the excess
    /// back out through the container's edit list. Measured on a real lecture the round trip
    /// is frame-exact, but one packet of slack keeps a harmless rounding difference from
    /// being read as a truncated file. It is still far too tight to let a real truncation
    /// through: the check exists to prove the encode finished, not to prove bit-exactness.
    private static let acceptableFrameDrift: AVAudioFramePosition = 1024

    enum Failure: LocalizedError {
        case incompatibleFormat
        case truncated(expected: AVAudioFramePosition, written: AVAudioFramePosition)

        var errorDescription: String? {
            switch self {
            case .incompatibleFormat:
                return "Le format de l'enregistrement n'est pas encodable en AAC."
            case let .truncated(expected, written):
                return "Fichier compressé incomplet (\(written) échantillons sur \(expected))."
            }
        }
    }

    /// Encodes `wavURL` and, only once the result is verified, deletes the WAV. Returns the
    /// new file's URL.
    ///
    /// Nothing is removed on a failure: an unencodable or truncated result leaves the
    /// original recording exactly where it was. Losing a lecture to save disk space would be
    /// a terrible trade.
    @discardableResult
    static func compressToM4A(wavURL: URL) throws -> URL {
        let source = try AVAudioFile(forReading: wavURL)
        let sourceLength = source.length
        let destination = OutputFileManager.m4aURL(
            in: wavURL.deletingLastPathComponent(),
            baseName: wavURL.deletingPathExtension().lastPathComponent
        )

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: source.fileFormat.sampleRate,
            AVNumberOfChannelsKey: source.fileFormat.channelCount,
            AVEncoderBitRateKey: bitRate
        ]

        // Scoped so the destination file is closed — and its container finalised — before
        // it is reopened for checking. An .m4a still missing its moov atom is unreadable.
        try autoreleasepool {
            let output = try AVAudioFile(forWriting: destination, settings: settings)
            guard source.processingFormat == output.processingFormat,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: source.processingFormat,
                      frameCapacity: framesPerPass
                  )
            else {
                throw Failure.incompatibleFormat
            }

            // Driven by the frame counter rather than by a short read: `read(into:)`
            // *throws* once the position has reached the end instead of returning an empty
            // buffer, so a loop that waits for `frameLength == 0` ends on an exception.
            while source.framePosition < sourceLength {
                try source.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
        }

        let written = try AVAudioFile(forReading: destination).length
        guard abs(written - sourceLength) <= acceptableFrameDrift else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.truncated(expected: sourceLength, written: written)
        }

        try FileManager.default.removeItem(at: wavURL)
        return destination
    }
}

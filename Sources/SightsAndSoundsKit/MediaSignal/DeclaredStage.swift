import AVFoundation
import CoreMedia
import Foundation

/// What the container and its tracks say about themselves, read with
/// AVFoundation and Core Media and nothing else.
///
/// Every value here is a statement about the current encode. A file that
/// has been re-encoded says "progressive, bt709, 1920x1080" because its
/// transcoder wrote that, whatever the picture inside once was; the stages
/// that decode are the ones that speak about origin.
public struct DeclaredStage: SignalStage {
    public let name = "declared"
    public let version = 1
    public let kinds: Set<MediaKind> = [.video, .audio]

    public init() {}

    public func examine(_ file: SignalStageInput) async throws -> SignalFindings {
        var findings = SignalFindings()

        let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?
            .int64Value
        findings.declare("container.fileSizeBytes", size.map(String.init))
        if let brands = Self.fileTypeBrands(of: file.url) {
            findings.declare("container.majorBrand", brands.major)
            findings.declare("container.compatibleBrands", brands.compatible.joined(separator: " "))
        }

        let asset = AVURLAsset(url: file.url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.load(.tracks)
        } catch {
            throw SignalStageError("AVFoundation cannot open this file: \(error.localizedDescription)")
        }
        guard !tracks.isEmpty else {
            throw SignalStageError("AVFoundation found no tracks in this file")
        }

        let duration = (try? await asset.load(.duration))?.seconds
        if let duration, duration.isFinite, duration > 0 {
            findings.declare("container.durationSeconds", String(format: "%.3f", duration))
            if let size { findings.measure("container.overallBitrate", Double(size) * 8 / duration) }
        }
        if let created = try? await asset.load(.creationDate),
           let date = try? await created.load(.dateValue) {
            findings.declare("container.creationDate", ISO8601DateFormatter().string(from: date))
        }
        if let metadata = try? await asset.load(.metadata) {
            let software = AVMetadataItem.metadataItems(
                from: metadata, filteredByIdentifier: .commonIdentifierSoftware).first
            findings.declare("container.writingApplication", try? await software?.load(.stringValue))
        }

        let video = tracks.filter { $0.mediaType == .video }
        let audio = tracks.filter { $0.mediaType == .audio }
        findings.declare("container.videoTrackCount", String(video.count))
        findings.declare("container.audioTrackCount", String(audio.count))
        findings.declare(
            "container.otherTrackCount", String(tracks.count - video.count - audio.count))

        if let track = video.first { await describeVideo(track, into: &findings) }
        if let track = audio.first { await describeAudio(track, into: &findings) }
        var languages: [String] = []
        for track in audio {
            if let code = try? await track.load(.languageCode) { languages.append(code) }
        }
        findings.declare("audio.languages", languages.joined(separator: " "))
        return findings
    }

    // MARK: - Video

    private func describeVideo(_ track: AVAssetTrack, into findings: inout SignalFindings) async {
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        // More than one sample description means the track was assembled
        // from pieces encoded differently.
        findings.declare("video.sampleDescriptionCount", String(descriptions.count))
        if let segments = try? await track.load(.segments) {
            findings.declare("video.editSegmentCount", String(segments.filter { !$0.isEmpty }.count))
        }
        if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
            findings.declare("video.nominalFrameRate", String(format: "%.3f", rate))
        }
        if let dataRate = try? await track.load(.estimatedDataRate), dataRate > 0 {
            findings.declare("video.estimatedBitrate", String(format: "%.0f", dataRate))
        }

        if let natural = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let shown = CGRect(origin: .zero, size: natural).applying(transform)
            findings.declare("video.displayWidth", String(format: "%.0f", abs(shown.width)))
            findings.declare("video.displayHeight", String(format: "%.0f", abs(shown.height)))
            let degrees = atan2(Double(transform.b), Double(transform.a)) * 180 / .pi
            findings.declare("video.rotationDegrees", String(format: "%.0f", (degrees + 360).truncatingRemainder(dividingBy: 360)))
        }

        guard let description = descriptions.first else { return }
        findings.declare("video.codecTag", Self.fourCC(description.mediaSubType.rawValue))
        let dimensions = description.dimensions
        findings.declare("video.encodedWidth", String(dimensions.width))
        findings.declare("video.encodedHeight", String(dimensions.height))

        let extensions = (CMFormatDescriptionGetExtensions(description) as? [String: Any]) ?? [:]
        func text(_ key: CFString) -> String? { extensions[key as String] as? String }
        func number(_ key: CFString) -> NSNumber? { extensions[key as String] as? NSNumber }

        if let aspect = extensions[kCMFormatDescriptionExtension_PixelAspectRatio as String] as? [String: Any],
           let horizontal = aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber,
           let vertical = aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber {
            findings.declare("video.pixelAspectRatio", "\(horizontal):\(vertical)")
        }
        if let aperture = extensions[kCMFormatDescriptionExtension_CleanAperture as String] as? [String: Any],
           let width = aperture[kCMFormatDescriptionKey_CleanApertureWidth as String] as? NSNumber,
           let height = aperture[kCMFormatDescriptionKey_CleanApertureHeight as String] as? NSNumber {
            findings.declare("video.cleanAperture", "\(width)x\(height)")
        }

        if let fields = number(kCMFormatDescriptionExtension_FieldCount) {
            findings.declare("video.fieldCount", fields.stringValue)
            findings.declare("video.scanType", fields.intValue == 2 ? "interlaced" : "progressive")
        }
        findings.declare("video.fieldDetail", text(kCMFormatDescriptionExtension_FieldDetail))

        let primaries = text(kCMFormatDescriptionExtension_ColorPrimaries)
        let transfer = text(kCMFormatDescriptionExtension_TransferFunction)
        let matrix = text(kCMFormatDescriptionExtension_YCbCrMatrix)
        findings.declare("video.colorPrimaries", primaries)
        findings.declare("video.transferFunction", transfer)
        findings.declare("video.colorMatrix", matrix)
        // Said outright, because "the file does not say" is a finding and
        // an absent row cannot be told from a stage that never ran.
        findings.declare(
            "video.colorTagged",
            primaries != nil && transfer != nil && matrix != nil ? "yes"
                : primaries == nil && transfer == nil && matrix == nil ? "no" : "partly")
        if let fullRange = number(kCMFormatDescriptionExtension_FullRangeVideo) {
            findings.declare("video.range", fullRange.boolValue ? "full" : "video")
        }
        if extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] != nil {
            findings.declare("video.hdrMasteringDisplay", "present")
        }
        if extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] != nil {
            findings.declare("video.hdrContentLightLevel", "present")
        }

        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
            as? [String: Any]
        let configuration = (atoms?["avcC"] as? Data).flatMap(CodecConfiguration.avc)
            ?? (atoms?["hvcC"] as? Data).flatMap(CodecConfiguration.hevc)
        if let configuration {
            findings.declare("video.profile", configuration.profile)
            findings.declare("video.level", configuration.level)
            findings.declare("video.tier", configuration.tier)
            findings.declare("video.bitDepth", configuration.bitDepth.map(String.init))
            findings.declare("video.chromaSubsampling", configuration.chromaSubsampling)
        } else if let depth = number(kCMFormatDescriptionExtension_BitsPerComponent) {
            findings.declare("video.bitDepth", depth.stringValue)
        }
        if atoms?["dvcC"] != nil || atoms?["dvvC"] != nil {
            findings.declare("video.dolbyVision", "present")
        }
    }

    // MARK: - Audio

    private func describeAudio(_ track: AVAssetTrack, into findings: inout SignalFindings) async {
        if let dataRate = try? await track.load(.estimatedDataRate), dataRate > 0 {
            findings.declare("audio.estimatedBitrate", String(format: "%.0f", dataRate))
        }
        guard let description = (try? await track.load(.formatDescriptions))?.first else { return }
        findings.declare("audio.codecTag", Self.fourCC(description.mediaSubType.rawValue))
        guard let format = description.audioStreamBasicDescription else { return }
        findings.declare("audio.sampleRate", String(format: "%.0f", format.mSampleRate))
        findings.declare("audio.channels", String(format.mChannelsPerFrame))
        if format.mBitsPerChannel > 0 {
            findings.declare("audio.bitDepth", String(format.mBitsPerChannel))
        }
        if let layout = description.audioChannelLayout {
            findings.declare("audio.channelLayoutTag", String(layout.tag))
        }
    }

    // MARK: - Helpers

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        return printable
            ? String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            : String(format: "0x%08X", code)
    }

    /// The `ftyp` box that opens an ISO base media file: a major brand and
    /// the brands the writer claims compatibility with. AVFoundation does
    /// not surface it, and it is the first few dozen bytes of the file.
    static func fileTypeBrands(of url: URL) -> (major: String, compatible: [String])? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256) else { return nil }
        return fileTypeBrands(inHead: head)
    }

    static func fileTypeBrands(inHead head: Data) -> (major: String, compatible: [String])? {
        let bytes = [UInt8](head)
        guard bytes.count >= 16, Array(bytes[4..<8]) == Array("ftyp".utf8) else { return nil }
        let boxSize = bytes[0..<4].reduce(0) { $0 << 8 | Int($1) }
        let end = min(max(boxSize, 16), bytes.count)
        func brand(at offset: Int) -> String {
            String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
        }
        var compatible: [String] = []
        var offset = 16
        while offset + 4 <= end {
            compatible.append(brand(at: offset))
            offset += 4
        }
        return (brand(at: 8), compatible)
    }
}

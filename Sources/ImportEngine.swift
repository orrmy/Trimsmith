import Foundation

/// A review line with its import outcome, kept separate from UI colors and localized wording.
struct ImportReport {
    /// Distinguishes copied/converted streams, omitted content, and neutral explanatory notes.
    enum Outcome { case copied, converted, omitted, explanation }
    let text: String
    let outcome: Outcome
}

/// An inspected source plus the proposed copy/conversion policy, omissions, and optional
/// deinterlacing choice.
struct ImportPlan: Identifiable {
    let id = UUID()
    let original: URL
    let videoIndex: Int
    let audioTracks: [AudioTrack]
    let videoCodec: String
    let duration: Double
    let isHDR: Bool
    let fieldOrder: String
    var deinterlace = false
    var convertVideo: Bool
    var convertAudio: Bool { audioTracks.contains { $0.needsConversion } }
    var omissions: [String]
    var reason: String?
    var isInterlaced: Bool { ["tt", "bb", "tb", "bt"].contains(fieldOrder) }
    var encodesVideo: Bool { convertVideo || deinterlace }
    var needsConfirmation: Bool { encodesVideo || convertAudio || isInterlaced || !omissions.isEmpty || reason != nil }
    /// Provides the review text without presentation metadata for plain-text consumers.
    var summary: [String] { reports.map(\.text) }

    /// Classifies each review line from the import decision, avoiding fragile matching on message text.
    var reports: [ImportReport] {
        var lines = [ImportReport(text: encodesVideo
            ? "Video track \(videoIndex) (\(videoCodec)): convert to H.264. Video quality will change; this import is not lossless."
            : "Video track \(videoIndex) (\(videoCodec)): copy without re-encoding or quality loss.",
            outcome: encodesVideo ? .converted : .copied)]
        if isInterlaced {
            lines.append(ImportReport(text: deinterlace
                ? "Interlaced video: deinterlace to progressive H.264, producing one frame per field to retain motion. This re-encodes the video and changes quality."
                : "This video reports interlaced fields. Apple's player may show artifacts even if VLC plays it correctly. Interlacing is a possible compatibility factor, not proof of damage. The interlacing will be preserved unless you choose to deinterlace.",
                outcome: .explanation))
        }
        if audioTracks.isEmpty { lines.append(ImportReport(text: "No audio track.", outcome: .explanation)) }
        for track in audioTracks {
            let details = [track.codec, track.language, track.title].compactMap { $0 }.joined(separator: ", ")
            lines.append(ImportReport(text: track.needsConversion
                ? "Audio track \(track.index) (\(details)): convert to AAC at 192 kb/s. Audio quality will change."
                : "Audio track \(track.index) (\(details)): copy without re-encoding.",
                outcome: track.needsConversion ? .converted : .copied))
        }
        lines += omissions.map { ImportReport(text: $0, outcome: .omitted) }
        if let reason { lines.append(ImportReport(text: reason, outcome: .explanation)) }
        lines.append(ImportReport(text: "Other container-specific metadata may not survive the conversion. Your original file will not be changed.", outcome: .explanation))
        return lines
    }
    /// Creates a reviewed H.264 fallback after Apple rejects copied video; HDR conversion remains
    /// unsupported.
    func convertingVideo(reason: String) throws -> ImportPlan {
        guard !isHDR else { throw MediaError(message: "Apple could not play this HDR video after remuxing. HDR video conversion is not supported yet; convert it externally first. Your original is unchanged.") }
        var plan = self
        plan.convertVideo = true; plan.reason = reason
        return plan
    }
}

/// Owns one unique temporary MOV directory; releasing the owner deletes only that working copy.
final class WorkingCopy: @unchecked Sendable {
    let directory: URL
    let url: URL
    /// Creates an isolated working directory and reserves a MOV filename without touching the
    /// original.
    init(name: String, root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("FrameCut-Working", isDirectory: true)) throws {
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(name + ".mov")
    }
    /// Removes the session’s temporary directory, including partially prepared media.
    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// Inspects arbitrary input containers and prepares a local Apple-compatible MOV working copy.
struct ImportEngine {
    /// Chooses the first non-cover video, retains all audio, and identifies conversions and
    /// omitted content.
    static func inspect(_ url: URL, tools: Toolchain) async throws -> ImportPlan {
        guard url.isFileURL else { throw MediaError(message: "Open a video file from Finder or a mounted volume.") }
        let data = try await Command().run(tools.ffprobe, ["-v", "error", "-show_streams", "-show_format", "-show_chapters", "-of", "json", url.path])
        try Task.checkCancellation()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else {
            throw MediaError(message: "Could not identify this file's video and audio tracks.")
        }
        let video = streams.first {
            $0["codec_type"] as? String == "video" && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0
        }
        guard let video, let videoIndex = video["index"] as? Int else { throw MediaError(message: "This file has no video track.") }
        let audioTracks = AudioTrack.all(in: streams)
        let videoCodec = video["codec_name"] as? String ?? "unknown"
        let pixelFormat = video["pix_fmt"] as? String ?? ""
        let transfer = video["color_transfer"] as? String ?? ""
        let isHDR = ["smpte2084", "arib-std-b67"].contains(transfer)
        // Codec names alone do not imply Apple playback support. Restrict copied
        // chroma/bit-depth combinations conservatively, then check the actual asset.
        let copyVideo = (videoCodec == "h264" && ["yuv420p", "yuvj420p"].contains(pixelFormat)) ||
            (videoCodec == "hevc" && ["yuv420p", "yuv420p10le"].contains(pixelFormat)) || videoCodec == "prores"
        guard copyVideo || !isHDR else {
            throw MediaError(message: "This HDR video needs conversion, which Trimsmith does not support yet. Convert it externally first. Your original is unchanged.")
        }
        var omissions = streams.compactMap { stream -> String? in
            guard let index = stream["index"] as? Int, index != videoIndex && stream["codec_type"] as? String != "audio" else { return nil }
            let type = stream["codec_type"] as? String ?? "unknown"
            let codec = stream["codec_name"] as? String ?? "unknown"
            let tags = stream["tags"] as? [String: String] ?? [:]
            let description = [tags["language"], tags["title"]].compactMap { $0 }.joined(separator: ", ")
            return "\(type.capitalized) track \(index) (\(codec)\(description.isEmpty ? "" : ", " + description)): omitted."
        }
        let chapters = json["chapters"] as? [[String: Any]] ?? []
        if !chapters.isEmpty { omissions.append("\(chapters.count) chapter marker(s): omitted.") }
        let format = json["format"] as? [String: Any] ?? [:]
        let length = Double(format["duration"] as? String ?? video["duration"] as? String ?? "0") ?? 0
        return ImportPlan(original: url, videoIndex: videoIndex, audioTracks: audioTracks, videoCodec: videoCodec,
                          duration: length.isFinite ? max(0, length) : 0,
                          isHDR: isHDR, fieldOrder: video["field_order"] as? String ?? "unknown", convertVideo: !copyVideo, omissions: omissions)
    }

    /// Creates the planned MOV copy, copying compatible streams and encoding only the reviewed
    /// conversions.
    static func prepare(_ plan: ImportPlan, tools: Toolchain,
                        progress: @escaping @Sendable (Double?) -> Void) async throws -> WorkingCopy {
        try Task.checkCancellation()
        guard !plan.deinterlace || (plan.isInterlaced && !plan.isHDR) else {
            throw MediaError(message: "Deinterlacing is available for interlaced SDR video only. Your original is unchanged.")
        }
        let copy = try WorkingCopy(name: plan.original.deletingPathExtension().lastPathComponent)
        let available = try? copy.directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        if let available, available < 16 * 1024 * 1024 {
            throw MediaError(message: "There is not enough free local disk space to prepare a working copy. Free some space and try again.")
        }
        var args = ["-hide_banner", "-v", "warning", "-nostdin", "-y", "-fflags", "+genpts", "-i", plan.original.path,
                    "-map", "0:\(plan.videoIndex)"]
        for track in plan.audioTracks { args += ["-map", "0:\(track.index)"] }
        args += ["-map_metadata", "0", "-map_chapters", "-1"]
        if plan.encodesVideo {
            // send_field preserves interlaced motion as one progressive frame
            // per field. Even dimensions are required by the 4:2:0 encoder.
            let topFirst = ["tt", "bt"].contains(plan.fieldOrder)
            // The encoder also reads field flags from each decoded frame, not
            // just output metadata. Normalize those flags when preserving fields.
            let fieldFlags = plan.isInterlaced && !plan.deinterlace ? "setfield=mode=\(topFirst ? "tff" : "bff")," : ""
            let filter = (plan.deinterlace ? "bwdif=mode=send_field:parity=auto:deint=all," : fieldFlags) + "pad=ceil(iw/2)*2:ceil(ih/2)*2"
            args += ["-c:v", "libx264", "-crf", "18", "-preset", "fast", "-pix_fmt", "yuv420p", "-vf", filter, "-fps_mode", "vfr"]
            if plan.isInterlaced && !plan.deinterlace {
                // field_order is the encoder option; FFmpeg 9 no longer accepts
                // the old -top flag as an output encoding option.
                // x264 must know field dominance when the encoder opens;
                // changing frame flags afterward can leave its initial TFF default.
                args += ["-flags", "+ilme+ildct", "-field_order", topFirst ? "tt" : "bb",
                         "-x264-params", topFirst ? "tff=1" : "bff=1"]
            }
        } else {
            args += ["-c:v", "copy"]
            if plan.videoCodec == "hevc" { args += ["-tag:v", "hvc1"] }
        }
        for (output, track) in plan.audioTracks.enumerated() {
            args += ["-c:a:\(output)", track.needsConversion ? "aac" : "copy"]
            if track.needsConversion { args += ["-b:a:\(output)", "192k"] }
            args += track.metadataArguments(output: output, quickTime: true)
        }
        // Default FFmpeg timestamp processing removes initial container offsets and
        // handles TS discontinuities; all later editing uses the resulting timeline.
        args += ["-progress", "pipe:1", copy.url.path]
        let meter = ImportProgress(duration: plan.duration, update: progress)
        progress(plan.duration > 0 ? 0 : nil)
        _ = try await Command().run(tools.ffmpeg, args, onLine: { meter.consume($0) })
        try Task.checkCancellation()
        progress(1)
        return copy
    }
}

/// FFmpeg progress parser confined to its command’s worker queue; callbacks receive values or unknown
/// duration.
private final class ImportProgress: @unchecked Sendable {
    let duration: Double
    let update: @Sendable (Double?) -> Void
    var lastUpdate = Date.distantPast
    var highWater = 0.0
    /// Stores the expected duration and callback for approximate preparation progress.
    init(duration: Double, update: @escaping @Sendable (Double?) -> Void) { self.duration = duration; self.update = update }
    /// Reports nondecreasing media-time progress at most every 150 ms, reserving completion for
    /// process exit.
    func consume(_ line: String) {
        guard line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst(12)), micros.isFinite else { return }
        highWater = max(highWater, micros / 1_000_000)
        guard Date().timeIntervalSince(lastUpdate) >= 0.15 else { return }
        lastUpdate = Date()
        update(duration > 0 ? min(0.99, highWater / duration) : nil)
    }
}

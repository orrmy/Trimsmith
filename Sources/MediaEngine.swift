import Foundation
import Darwin

/// A kept interval in seconds: start is included and end is excluded.
struct Clip: Identifiable, Equatable, Codable {
    var id = UUID()
    var start: Double
    var end: Double
    var duration: Double { end - start }
}

/// Whether a marker starts or ends a kept interval.
enum CutKind: String, Codable { case start = "IN", end = "OUT" }

/// An individually selectable marker; its identity survives sorting and undo.
struct CutPoint: Identifiable, Equatable, Codable {
    var id = UUID()
    let kind: CutKind
    let time: Double
}

/// A selection derived from markers; a missing OUT extends to the media duration.
struct CutSelection: Identifiable, Equatable {
    let start: CutPoint
    let end: CutPoint?
    let duration: Double
    // Reuse the opening marker's identity so rebuilding selections does not
    // discard SwiftUI selection state or create new list rows on every edit.
    var id: UUID { start.id }
    var clip: Clip { Clip(id: id, start: start.time, end: end?.time ?? duration) }
}

/// Derives chronological selections while retaining redundant markers for editing.
enum CutTimeline {
    /// Orders markers by time, with OUT before IN so adjacent selections stay separate.
    static func sorted(_ points: [CutPoint]) -> [CutPoint] {
        points.sorted {
            if $0.time != $1.time { return $0.time < $1.time }
            // OUT then IN permits adjacent selections at the same timestamp.
            if $0.kind != $1.kind { return $0.kind == .end }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    /// Pairs each opening IN with the next OUT, ignoring redundant markers and extending an
    /// unmatched IN to EOF.
    static func selections(_ points: [CutPoint], duration: Double) -> [CutSelection] {
        var result: [CutSelection] = []
        var start: CutPoint?
        for point in sorted(points) where point.time.isFinite && point.time >= 0 && point.time <= duration {
            switch point.kind {
            case .start:
                if start == nil && point.time < duration { start = point }
            case .end:
                if let first = start, point.time > first.time {
                    result.append(CutSelection(start: first, end: point, duration: duration))
                    start = nil
                }
            }
        }
        if let start { result.append(CutSelection(start: start, end: nil, duration: duration)) }
        return result
    }
}

/// Chooses whether edit boundaries expand to keyframes or use the marked frames.
enum ExportMode: String, CaseIterable, Identifiable {
    case lossless = "Lossless"
    case exact = "Frame-exact"
    var id: String { rawValue }
}

/// The video encoding choices offered in the save dialog, including unchanged stream copy.
enum ExportCodec: String, CaseIterable {
    case lossless = "Lossless (copy streams)"
    case h264 = "H.264"
    case hevc = "HEVC (H.265)"
    case prores = "Apple ProRes"
    /// Encoder-supported tune identifiers; an empty string means the encoder default.
    var tunes: [String] {
        switch self {
        case .h264: return ["", "film", "animation", "grain", "stillimage", "fastdecode", "zerolatency", "psnr", "ssim"]
        case .hevc: return ["", "animation", "grain", "fastdecode", "zerolatency", "psnr", "ssim"]
        case .lossless, .prores: return []
        }
    }
}

/// Supported 4:2:2 ProRes profiles, using FFmpeg prores_ks profile numbers.
enum ProResProfile: Int, CaseIterable {
    case proxy = 0, lt, standard, hq
    var title: String {
        switch self {
        case .proxy: return "ProRes 422 Proxy"
        case .lt: return "ProRes 422 LT"
        case .standard: return "ProRes 422"
        case .hq: return "ProRes 422 HQ"
        }
    }
}

/// Video encoder settings and the corresponding audio policy for a single export.
struct ExportSettings: Equatable {
    var codec: ExportCodec
    var crf: Int
    var tune = ""
    var proResProfile: ProResProfile = .standard
    /// Supplies codec-specific starting quality: HEVC CRF 22, otherwise CRF 18 where applicable.
    static func defaults(for codec: ExportCodec) -> ExportSettings {
        ExportSettings(codec: codec, crf: codec == .hevc ? 22 : 18)
    }
    /// Defaults to stream copy for lossless cuts and HEVC for frame-exact cuts.
    static func defaults(for mode: ExportMode) -> ExportSettings {
        defaults(for: mode == .lossless ? ExportCodec.lossless : .hevc)
    }
    /// Rejects incompatible mode, container, quality, or tune choices before writing output.
    func validate(mode: ExportMode, destination: URL) throws {
        guard mode != .exact || codec != .lossless else {
            throw MediaError(message: "Frame-exact cuts require re-encoding. Choose H.264, HEVC, or ProRes.")
        }
        let ext = destination.pathExtension.lowercased()
        guard ["mov", "mp4"].contains(ext), codec != .prores || ext == "mov" else {
            throw MediaError(message: "Choose MOV for ProRes; H.264, HEVC, and stream copy support MOV or MP4 when their streams are compatible.")
        }
        if codec == .h264 || codec == .hevc {
            guard (0...51).contains(crf), codec.tunes.contains(tune) else {
                throw MediaError(message: "Choose a CRF between 0 and 51 and a tune supported by the selected codec.")
            }
        }
    }
    /// Builds FFmpeg video options, retaining variable frame timing and Apple-compatible pixel
    /// formats/tags.
    var videoArguments: [String] {
        switch codec {
        case .lossless: return ["-c:v", "copy"]
        case .h264, .hevc:
            var args = ["-c:v", codec == .h264 ? "libx264" : "libx265", "-preset", "medium", "-crf", String(crf),
                        "-pix_fmt", codec == .h264 ? "yuv420p" : "yuv420p10le", "-fps_mode", "vfr"]
            if !tune.isEmpty { args += ["-tune", tune] }
            if codec == .hevc { args += ["-tag:v", "hvc1"] }
            return args
        case .prores:
            return ["-c:v", "prores_ks", "-profile:v", String(proResProfile.rawValue), "-pix_fmt", "yuv422p10le", "-fps_mode", "vfr"]
        }
    }
    /// Uses 24-bit PCM with ProRes and AAC at 192 kb/s per track for other encoded exports.
    var audioArguments: [String] {
        codec == .prores ? ["-c:a", "pcm_s24le"] : ["-c:a", "aac", "-b:a", "192k"]
    }
}

/// A source audio stream and its labels/default flags, retained across remuxing and filtered exports.
struct AudioTrack {
    let index: Int
    let codec: String
    let language: String?
    let title: String?
    let disposition: String
    /// Whether this audio codec falls outside the conservative Apple-compatible copy list.
    var needsConversion: Bool {
        !["aac", "alac", "mp3", "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f64le"].contains(codec)
    }
    /// Reads one ffprobe audio stream whose numeric index has already been checked.
    init(_ stream: [String: Any]) {
        index = stream["index"] as! Int
        codec = stream["codec_name"] as? String ?? "unknown"
        let tags = stream["tags"] as? [String: String] ?? [:]
        language = tags["language"]
        title = tags["title"] ?? tags["handler_name"]
        let flags = stream["disposition"] as? [String: Int] ?? [:]
        disposition = flags.filter { $0.value != 0 }.map(\.key).sorted().joined(separator: "+")
    }
    /// Collects every valid audio stream in source order; there is no track-selection policy.
    static func all(in streams: [[String: Any]]) -> [AudioTrack] {
        streams.filter { $0["codec_type"] as? String == "audio" && $0["index"] is Int }.map(AudioTrack.init)
    }
    /// Restores a track’s labels and dispositions at its new output ordinal, adapting MOV
    /// language codes.
    func metadataArguments(output: Int, quickTime: Bool = false) -> [String] {
        var args = ["-disposition:a:\(output)", disposition.isEmpty ? "0" : disposition]
        if let language {
            // FFmpeg's MOV muxer uses QuickTime's legacy language table, not
            // MP4's packed ISO codes (e.g. German must be "ger", not "deu").
            let aliases = ["deu": "ger", "nld": "dut", "swe": "sve", "ell": "gre", "isl": "ice",
                           "zho": "chi", "fas": "per", "gle": "iri", "sqi": "alb", "mkd": "mac",
                           "hye": "arm", "kat": "geo", "bod": "tib", "mya": "bur", "msa": "may",
                           "cym": "wel", "eus": "baq", "fre": "fra", "cze": "ces", "slo": "slk", "rum": "ron"]
            args += ["-metadata:s:a:\(output)", "language=" + (quickTime ? aliases[language] ?? language : language)]
        }
        if let title {
            args += ["-metadata:s:a:\(output)", "title=" + title, "-metadata:s:a:\(output)", "handler_name=" + title]
        }
        return args
    }
}

/// A user-facing operation failure whose message is shown directly by the editor.
struct MediaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Nonfatal review notes for an export that can still be saved.
struct ExportResult {
    var reviewNotes: [String] = []
    var needsReview: Bool { !reviewNotes.isEmpty }
    /// Explains advisory verification results and asks the user to check the saved file.
    var warningMessage: String? {
        guard needsReview else { return nil }
        return "The video was saved, but Trimsmith found a possible issue:\n\n" + reviewNotes.joined(separator: "\n") +
            "\n\nPlay the saved file and check the cuts and audio sync before relying on it. If it is unusable, try Frame-exact export."
    }
}

/// Sorted keyframe and packet presentation times on the working-copy playback timeline.
struct MediaIndex {
    var keyframes: [Double]
    // Compact timestamps collected during the same packet scan as the keyframes.
    var packetTimes: [Double]
    /// Binary-searches for the last packet strictly before a boundary, allowing for timestamp
    /// rounding.
    func lastPacket(before boundary: Double) -> Double? {
        var low = 0, high = packetTimes.count
        while low < high {
            let mid = (low + high) / 2
            if packetTimes[mid] < boundary - 0.000001 { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? packetTimes[low - 1] : nil
    }
    /// Counts indexed packets in the kept ranges as an advisory estimate of exported frame count.
    func frameCount(in clips: [Clip]) -> Int {
        // Packets are cheap to retain during indexing, but need not correspond
        // one-to-one with decoded frames in interlaced or open-GOP recordings.
        // A mismatch therefore supports a warning, not proof of unusable output.
        /// Finds the first packet at or after a timestamp without rescanning the recording.
        func lowerBound(_ value: Double) -> Int {
            var low = 0, high = packetTimes.count
            while low < high {
                let mid = (low + high) / 2
                if packetTimes[mid] < value { low = mid + 1 } else { high = mid }
            }
            return low
        }
        return clips.reduce(0) { $0 + lowerBound($1.end - 0.00001) - lowerBound($1.start - 0.00001) }
    }
}

/// Locations of the FFmpeg and ffprobe executables used for media operations.
struct Toolchain {
    let ffmpeg: URL
    let ffprobe: URL
    /// Finds bundled tools first, then common Homebrew and system locations.
    static func locate() throws -> Toolchain {
        /// Returns the first executable candidate or explains how to install the missing
        /// tool.
        func find(_ name: String) throws -> URL {
            let candidates = [Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)").path,
                              "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
                .compactMap { $0 }
            guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw MediaError(message: "\(name) is missing. Install FFmpeg with Homebrew (brew install ffmpeg), then reopen Trimsmith.")
            }
            return URL(fileURLWithPath: path)
        }
        return try Toolchain(ffmpeg: find("ffmpeg"), ffprobe: find("ffprobe"))
    }
}

/// Runs one cancellable child process; its lock protects process state shared with cancellation.
final class Command: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    /// Marks the operation cancelled and kills only its own active child, including a stalled
    /// probe.
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        // These are exclusively our disposable probe/export children. SIGKILL also
        // works when a child inherited a blocked/ignored SIGTERM from its launcher.
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    /// Runs off the caller’s actor, returning stdout or streaming its lines and propagating task
    /// cancellation.
    func run(_ executable: URL, _ arguments: [String],
             onLine: (@Sendable (String) -> Void)? = nil) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try self.runBlocking(executable, arguments, onLine: onLine)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel() })
    }
    /// Drains stdout on a worker queue and captures stderr separately to avoid a full-pipe
    /// deadlock.
    private func runBlocking(_ executable: URL, _ arguments: [String],
                             onLine: (@Sendable (String) -> Void)?) throws -> Data {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }
        let child = Process()
        let output = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.standardOutput = output
        child.standardError = errors
        child.standardInput = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw error }
        var data = Data()
        var pending = Data()
        // Parse packet lines on this worker queue. Never build a whole-file packet
        // JSON tree or dispatch one UI task per packet on a long recording.
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if let onLine {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    onLine(String(decoding: pending[..<newline], as: UTF8.self))
                    pending.removeSubrange(...newline)
                }
            } else { data.append(chunk) }
        }
        if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        child.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; process = nil; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard child.terminationStatus == 0 else {
            let details = String(data: (try? Data(contentsOf: log)) ?? Data(), encoding: .utf8) ?? ""
            throw MediaError(message: String(details.suffix(5000)))
        }
        return data
    }
}

/// Worker-confined packet parser; read its arrays only after the command has completed.
private final class KeyframeIndex: @unchecked Sendable {
    let origin: Double
    let duration: Double
    let progress: @Sendable (Double) -> Void
    var frames: [Double] = []
    var packetTimes: [Double] = []
    private var highWater = 0.0
    private var lastUpdate = Date.distantPast
    /// Sets the timestamp origin and duration used to normalize packets and estimate scan
    /// progress.
    init(origin: Double, duration: Double, progress: @escaping @Sendable (Double) -> Void) {
        self.origin = origin; self.duration = duration; self.progress = progress
    }
    /// Collects packet/keyframe times from compact ffprobe output and throttles progress
    /// callbacks.
    func consume(_ line: String) {
        let fields = line.split(separator: "|")
        guard let raw = fields.first(where: { $0.hasPrefix("pts_time=") }),
              let pts = Double(raw.dropFirst(9)), pts.isFinite else { return }
        let time = pts - origin
        packetTimes.append(time)
        if fields.contains(where: { $0.hasPrefix("flags=") && $0.dropFirst(6).contains("K") }) {
            frames.append(max(0, time))
        }
        highWater = max(highWater, time)
        let now = Date()
        if duration > 0, now.timeIntervalSince(lastUpdate) >= 0.15 {
            lastUpdate = now
            progress(min(0.99, highWater / duration))
        }
    }
}

/// Media indexing, boundary validation, FFmpeg export, and safe destination publication.
struct MediaEngine {
    // Cheap header inspection also catches a transport stream renamed to .mp4.
    /// Checks for a MOV-family working copy and reads the start offset used by playback and
    /// FFmpeg seeking.
    static func sourceOrigin(source: URL, tools: Toolchain) async throws -> Double {
        let data = try await Command().run(tools.ffprobe, ["-v", "error", "-select_streams", "v:0",
            "-show_entries", "format=format_name,start_time:stream=start_time", "-of", "json", source.path])
        try Task.checkCancellation()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let format = (json?["format"] as? [String: Any])?["format_name"] as? String ?? ""
        guard format.split(separator: ",").contains("mov") else {
            throw MediaError(message: "This file is not an MP4, MOV, or M4V container, even if its filename says otherwise. Remux or convert it before opening it in FrameCut.")
        }
        let streams = json?["streams"] as? [[String: Any]] ?? []
        let formatInfo = json?["format"] as? [String: Any]
        // Prefer the container origin: video can begin after audio, and using
        // only the video start would shift cuts relative to input -ss/playback.
        return Double(formatInfo?["start_time"] as? String ?? streams.first?["start_time"] as? String ?? "0") ?? 0
    }

    /// Returns the working copy’s sorted keyframe times using the shared packet indexer.
    static func keyframes(source: URL, tools: Toolchain) async throws -> [Double] {
        try await index(source: source, tools: tools).keyframes
    }

    /// Scans video packets incrementally without decoding or building a whole-file packet JSON
    /// tree.
    static func index(source: URL, tools: Toolchain, duration: Double = 0,
                          origin: Double? = nil,
                          progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> MediaIndex {
        let start: Double
        if let origin { start = origin }
        else { start = try await sourceOrigin(source: source, tools: tools) }
        let index = KeyframeIndex(origin: start, duration: duration, progress: progress)
        _ = try await Command().run(tools.ffprobe, ["-v", "error", "-select_streams", "v:0",
            "-show_packets", "-show_entries", "packet=pts_time,flags", "-of", "compact=p=0:nk=0", source.path],
            onLine: { index.consume($0) })
        try Task.checkCancellation()
        progress(1)
        return MediaIndex(keyframes: Array(Set(index.frames)).sorted(), packetTimes: index.packetTimes.sorted())
    }

    /// Expands lossless IN backward and exclusive OUT forward to keyframes; exact cuts stay
    /// unchanged.
    static func effective(_ clip: Clip, mode: ExportMode, keyframes: [Double], duration: Double) -> Clip {
        guard mode == .lossless else { return clip }
        // The small tolerance absorbs timestamp serialization differences so a
        // marker already on a keyframe does not expand into another whole GOP.
        let start = keyframes.last(where: { $0 <= clip.start + 0.00001 }) ?? 0
        let end = keyframes.first(where: { $0 >= clip.end - 0.00001 }) ?? duration
        return Clip(id: clip.id, start: start, end: min(duration, end))
    }

    /// Requires finite, positive, chronologically nonoverlapping export ranges.
    static func validate(_ clips: [Clip]) throws {
        guard !clips.isEmpty, clips.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }) else {
            throw MediaError(message: "Add at least one valid segment before exporting.")
        }
        for (a, b) in zip(clips, clips.dropFirst()) where a.end > b.start + 0.00001 {
            throw MediaError(message: "Segments overlap after keyframe snapping. Adjust the marks, combine these segments, or use Frame-exact export.")
        }
    }

    /// Builds stream-copy extraction options and removes packets outside the presentation-time
    /// range.
    static func segmentArguments(source: URL, clip: Clip, output: URL, progress: URL) -> [String] {
        var args = ["-hide_banner", "-v", "warning", "-nostdin", "-y", "-progress", progress.path,
                    "-ss", number(clip.start), "-i", source.path, "-t", number(clip.duration),
                    "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0"]
        // FFmpeg's -t stops on decode timestamps. B-frames can otherwise carry
        // packets from the next GOP beyond the advertised presentation boundary.
        args += ["-c", "copy", "-bsf:v", "noise=drop=lt(pts\\,0)+gte(pts*tb\\,\(number(clip.duration)))"]
        return args + [output.path]
    }

    /// Prepares and joins locally, checks copied video, then saves with byte progress; returns
    /// advisory issues.
    @discardableResult
    static func export(source: URL, clips: [Clip], mode: ExportMode, destination: URL, tools: Toolchain, expectedVideoFrames: Int? = nil, settings suppliedSettings: ExportSettings? = nil,
                       progress: @escaping @Sendable (Double, String) async -> Void) async throws -> ExportResult {
        try validate(clips)
        let settings = suppliedSettings ?? ExportSettings.defaults(for: mode)
        try settings.validate(mode: mode, destination: destination)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("FrameCut-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        // Joining/faststart stays local. Saving to a slow volume is a separate,
        // byte-measured phase rather than an unobservable part of FFmpeg muxing.
        let staged = work.appendingPathComponent("joined." + destination.pathExtension)
        defer { try? fm.removeItem(at: work) }
        if settings.codec != .lossless {
            try await exportEncoded(source: source, clips: clips, staged: staged, work: work, tools: tools, settings: settings, progress: progress)
            try Task.checkCancellation()
            try await save(staged, to: destination, progress: progress)
            await progress(1, "Export complete")
            return ExportResult()
        }
        var audioTracks: [AudioTrack] = []
        var audioMetadataUnavailable = false
        do {
            let data = try await Command().run(tools.ffprobe, ["-v", "error", "-show_streams", "-of", "json", source.path])
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            audioTracks = AudioTrack.all(in: json?["streams"] as? [[String: Any]] ?? [])
        } catch is CancellationError { throw CancellationError() }
        catch { audioMetadataUnavailable = true }
        var filenames: [String] = []
        for (index, clip) in clips.enumerated() {
            try Task.checkCancellation()
            let name = "segment-\(index).mov"
            let target = work.appendingPathComponent(name)
            let report = work.appendingPathComponent("progress-\(index)")
            await progress(-1, "Preparing segment \(index + 1) of \(clips.count)…")
            _ = try await Command().run(tools.ffmpeg, segmentArguments(source: source, clip: clip, output: target, progress: report))
            filenames.append(name)
        }
        try Task.checkCancellation()
        await progress(-1, "Joining segments…")
        let list = work.appendingPathComponent("segments.ffconcat")
        try ("ffconcat version 1.0\n" + zip(filenames, clips).map { "file '\($0.0)'\nduration \(number($0.1.duration))" }.joined(separator: "\n") + "\n")
            .write(to: list, atomically: true, encoding: .utf8)
        var joinArgs = ["-hide_banner", "-v", "warning", "-nostdin", "-y",
            "-f", "concat", "-safe", "1", "-i", list.path, "-map", "0:v:0", "-map", "0:a?", "-c", "copy"]
        // The concat demuxer does not retain disposition flags. Restore identities
        // from the working copy rather than accepting an arbitrary new default.
        for (output, track) in audioTracks.enumerated() {
            joinArgs += track.metadataArguments(output: output, quickTime: staged.pathExtension.lowercased() == "mov")
        }
        joinArgs += ["-movflags", "+faststart", staged.path]
        _ = try await Command().run(tools.ffmpeg, joinArgs)
        try Task.checkCancellation()
        await progress(-1, "Checking lossless export…")
        var result = try await verifyLossless(output: staged, clips: clips, expectedVideoFrames: expectedVideoFrames, tools: tools)
        if audioMetadataUnavailable { result.reviewNotes.append("Audio track labels and default-track flags could not be verified.") }
        try Task.checkCancellation()
        try await save(staged, to: destination, progress: progress)
        await progress(1, result.needsReview ? "Export saved · check playback" : "Export complete")
        return result
    }

    /// Copies to a hidden sibling file, synchronizes it, and publishes only after success and a
    /// cancellation check.
    /// Cancellation or a failed write removes the partial file and preserves an existing export.
    static func save(_ source: URL, to destination: URL,
                     progress: @escaping @Sendable (Double, String) async -> Void) async throws {
        let fm = FileManager.default
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".FrameCut-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? fm.removeItem(at: partial) }
        let total = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw MediaError(message: "Could not create the export at the chosen location.")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        await progress(0, "Saving video…")
        var copied = 0
        var lastReport = Date.distantPast
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            try output.write(contentsOf: data)
            copied += data.count
            if Date().timeIntervalSince(lastReport) >= 0.15 {
                await progress(min(0.99, Double(copied) / Double(max(1, total))), "Saving video…")
                lastReport = Date()
            }
        }
        try Task.checkCancellation()
        await progress(0.99, "Finishing save…")
        try output.synchronize()
        try output.close()
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: partial)
        } else { try fm.moveItem(at: partial, to: destination) }
        await progress(1, "Video saved")
    }

    /// Spot-checks metadata and decoded join windows; uncertain results warn, while empty or
    /// video-less output fails.
    static func verifyLossless(output: URL, clips: [Clip], expectedVideoFrames: Int?, tools: Toolchain) async throws -> ExportResult {
        // Damaged recordings and open GOPs can still produce useful output.
        // Only definite empty/video-less results block saving; inspection and
        // decode uncertainty is advisory. Cancellation must still abort saving.
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw MediaError(message: "The export produced an empty file. No output was saved.") }
        let data: Data
        do {
            data = try await Command().run(tools.ffprobe, ["-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=codec_type,nb_frames,duration:format=duration", "-of", "json", output.path])
        } catch is CancellationError { throw CancellationError() }
        catch { return ExportResult(reviewNotes: ["Trimsmith could not inspect the exported video's metadata."]) }
        try Task.checkCancellation()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else {
            return ExportResult(reviewNotes: ["Trimsmith could not read the exported video's metadata."])
        }
        guard let video = streams.first(where: { $0["codec_type"] as? String == "video" }) else {
            throw MediaError(message: "The export contains no video track. No output was saved.")
        }
        var result = ExportResult()
        // MOV/MP4 stores this count in the container; no full decode is needed.
        if let expectedVideoFrames, let raw = video["nb_frames"] as? String, let count = Int(raw) {
            if count != expectedVideoFrames {
                result.reviewNotes.append("The saved video reports \(count) frames; the selected ranges contain \(expectedVideoFrames) video packets. Some frames may be missing or extra.")
            }
        } else {
            result.reviewNotes.append("Trimsmith could not confirm the saved video's frame count.")
        }
        let expectedDuration = clips.reduce(0) { $0 + $1.duration }
        let format = json["format"] as? [String: Any]
        let actualDuration = Double(video["duration"] as? String ?? format?["duration"] as? String ?? "")
        if let actualDuration, actualDuration.isFinite, abs(actualDuration - expectedDuration) > 0.25 {
            result.reviewNotes.append("The saved video's duration differs from the selected ranges by more than a quarter of a second.")
        }
        let length = min(expectedDuration, actualDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? expectedDuration)
        let windows = verificationWindows(clips: clips, duration: length)
        for window in windows {
            try Task.checkCancellation()
            do {
                let fullSample = window.start == 0 && window.end >= expectedDuration - 0.00001
                var arguments = ["-hide_banner", "-v", "error", "-nostdin", "-xerror"]
                if !fullSample { arguments += ["-ss", number(window.start)] }
                arguments += ["-i", output.path]
                // For a complete short-video check, read to EOF. Limiting by its
                // duration can drop the final frame when the first PTS is nonzero.
                if !fullSample { arguments += ["-t", number(window.duration)] }
                arguments += ["-map", "0:v:0", "-an", "-fps_mode", "passthrough", "-progress", "pipe:1", "-f", "null", "-"]
                let report = try await Command().run(tools.ffmpeg, arguments)
                let frames = String(decoding: report, as: UTF8.self).components(separatedBy: .newlines)
                    .last(where: { $0.hasPrefix("frame=") }).flatMap { Int($0.dropFirst(6)) }
                // For a short export the merged sample covers the whole video.
                // Compare actual decoded frames too: open GOPs can report packets
                // in the container that the decoder cannot turn into frames.
                if fullSample,
                   let frames, let expectedVideoFrames, frames != expectedVideoFrames {
                    result.reviewNotes.append("The playback check decoded \(frames) frames; the selected ranges contain \(expectedVideoFrames) video packets. Some frames may be missing or extra.")
                }
                if frames == nil || frames == 0 {
                    result.reviewNotes.append("A playback check could not decode video near \(timestamp(window.start)).")
                    break
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                result.reviewNotes.append("A playback check found a decoding problem near \(timestamp(window.start)).")
                break
            }
        }
        return result
    }

    /// Samples two seconds on each side of joins/endpoints, merging overlaps to avoid decoding
    /// short exports repeatedly.
    static func verificationWindows(clips: [Clip], duration: Double) -> [Clip] {
        var boundaries = [0.0]
        var cursor = 0.0
        for clip in clips { cursor += clip.duration; boundaries.append(cursor) }
        boundaries.append(duration)
        let windows = boundaries.map { Clip(start: max(0, min(duration, $0) - 2), end: min(duration, $0 + 2)) }
            .filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var merged: [Clip] = []
        for window in windows {
            if let last = merged.last, window.start <= last.end {
                merged[merged.count - 1].end = max(last.end, window.end)
            } else { merged.append(window) }
        }
        return merged
    }

    /// Trims decoded video and every audio track, concatenates once, and encodes to the requested
    /// settings.
    /// Encoding audio once avoids introducing AAC priming at every segment join.
    static func exportEncoded(source: URL, clips: [Clip], staged: URL, work: URL, tools: Toolchain, settings: ExportSettings,
                            progress: @escaping @Sendable (Double, String) async -> Void) async throws {
        let probe = try await Command().run(tools.ffprobe, ["-v", "error", "-show_streams", "-of", "json", source.path])
        let json = try JSONSerialization.jsonObject(with: probe) as? [String: Any]
        let streams = json?["streams"] as? [[String: Any]] ?? []
        let audioTracks = AudioTrack.all(in: streams)
        let video = streams.first { $0["codec_type"] as? String == "video" }
        let transfer = video?["color_transfer"] as? String ?? ""
        guard !["smpte2084", "arib-std-b67"].contains(transfer) else {
            throw MediaError(message: "Video re-encoding does not support HDR yet. Use Lossless stream copy to preserve this video's HDR, or convert it to SDR first.")
        }
        var filters: [String] = []
        let count = clips.count
        // Split explicitly: each trim needs its own copy of the decoded source stream.
        filters.append("[0:v:0]split=\(count)" + (0..<count).map { "[vs\($0)]" }.joined())
        for audio in audioTracks.indices {
            filters.append("[0:a:\(audio)]asplit=\(count)" + (0..<count).map { "[as\(audio)_\($0)]" }.joined())
        }
        for (index, clip) in clips.enumerated() {
            filters.append("[vs\(index)]trim=start=\(number(clip.start)):end=\(number(clip.end)),setpts=PTS-STARTPTS,pad=ceil(iw/2)*2:ceil(ih/2)*2[v\(index)]")
            for audio in audioTracks.indices {
                filters.append("[as\(audio)_\(index)]atrim=start=\(number(clip.start)):end=\(number(clip.end)),asetpts=PTS-STARTPTS[a\(audio)_\(index)]")
            }
        }
        let inputs = (0..<count).map { segment in
            "[v\(segment)]" + audioTracks.indices.map { "[a\($0)_\(segment)]" }.joined()
        }.joined()
        filters.append(inputs + "concat=n=\(count):v=1:a=\(audioTracks.count)[vout]" + audioTracks.indices.map { "[aout\($0)]" }.joined())
        let script = work.appendingPathComponent("exact.fffilter")
        try filters.joined(separator: ";\n").write(to: script, atomically: true, encoding: .utf8)
        let report = work.appendingPathComponent("exact-progress")
        let total = clips.reduce(0) { $0 + $1.duration }
        let monitor = Task {
            while !Task.isCancelled {
                let contents = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
                let time = contents.components(separatedBy: .newlines).last(where: { $0.hasPrefix("out_time_us=") })
                    .flatMap { Double($0.dropFirst(12)) }.map { $0 / 1_000_000 } ?? 0
                await progress(min(0.98, max(0, time) / total), "Encoding \(settings.codec.rawValue) cuts…")
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        // Load the graph from a file without growing argv for long cut lists.
        // The general -/ option syntax replaces filter_complex_script, removed in FFmpeg 9.
        var args = ["-hide_banner", "-v", "warning", "-nostdin", "-y", "-progress", report.path,
                    "-t", number(clips.last!.end), "-i", source.path, "-/filter_complex", script.path,
                    "-map", "[vout]"]
        for audio in audioTracks.indices {
            args += ["-map", "[aout\(audio)]", "-map_metadata:s:a:\(audio)", "0:s:a:\(audio)"]
            args += audioTracks[audio].metadataArguments(output: audio, quickTime: staged.pathExtension.lowercased() == "mov")
        }
        args += settings.videoArguments
        if !audioTracks.isEmpty { args += settings.audioArguments }
        args += ["-movflags", "+faststart", staged.path]
        do {
            _ = try await Command().run(tools.ffmpeg, args)
            monitor.cancel(); await monitor.value
        } catch {
            monitor.cancel(); await monitor.value
            throw error
        }
    }
    /// Formats precise FFmpeg timestamps with a decimal point regardless of the user’s locale.
    static func number(_ time: Double) -> String { String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), time) }
}

/// Formats finite nonnegative time for display as hours:minutes:seconds.milliseconds.
func timestamp(_ seconds: Double) -> String {
    let millis = Int((max(0, seconds.isFinite ? seconds : 0) * 1000).rounded())
    return String(format: "%02d:%02d:%02d.%03d", millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60, millis % 1000)
}

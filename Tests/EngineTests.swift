import Foundation

/// Generated-media integration checks for export boundaries, codecs, verification, cancellation, and safe saving.
@main
struct EngineTests {
    /// Creates the shared fixtures and checks encoded/stream-copy output against decoded frames
    /// and filesystem invariants.
    static func main() async throws {
        let tools = try Toolchain.testing()
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fixture.mp4")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=8",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=8", "-c:v", "libx264", "-g", "50", "-keyint_min", "50", "-sc_threshold", "0", "-c:a", "aac", source.path])
        let sourceIndex = try await MediaEngine.index(source: source, tools: tools)
        let keys = sourceIndex.keyframes
        precondition(sourceIndex.frameCount(in: [Clip(start: 0, end: 2), Clip(start: 4, end: 6)]) == 100)
        precondition(keys.count == 4 && abs(keys[1] - 2) < 0.001, "Unexpected keyframe index: \(keys)")
        let snapped = MediaEngine.effective(Clip(start: 0.52, end: 1.4), mode: .lossless, keyframes: keys, duration: 8)
        precondition(snapped.start == 0 && snapped.end == 2)
        do {
            try MediaEngine.validate([Clip(start: 0, end: 3), Clip(start: 2, end: 4)])
            fatalError("Overlap should be rejected")
        } catch is MediaError { }
        let selected = [Clip(start: 0.52, end: 1.4), Clip(start: 4.12, end: 5.32)]
        let exact = root.appendingPathComponent("exact.mp4")
        try await MediaEngine.export(source: source, clips: selected, mode: .exact, destination: exact, tools: tools) { _, _ in }
        let exactData = try await Command().run(tools.ffprobe, ["-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries", "stream=nb_read_frames,duration", "-of", "json", exact.path])
        let exactJSON = try JSONSerialization.jsonObject(with: exactData) as! [String: Any]
        let stream = (exactJSON["streams"] as! [[String: Any]])[0]
        precondition(stream["nb_read_frames"] as? String == "52", "Expected 52 frames, got \(stream)")
        let lossless = root.appendingPathComponent("lossless.mov")
        let cleanResult = try await MediaEngine.export(source: source, clips: [Clip(start: 0, end: 2), Clip(start: 4, end: 6)], mode: .lossless, destination: lossless, tools: tools, expectedVideoFrames: 100) { _, _ in }
        precondition(!cleanResult.needsReview, "Clean H.264 export should not warn: \(cleanResult.reviewNotes)")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-i", lossless.path, "-f", "null", "-"])
        /// Returns one checksum per decoded video frame, ignoring muxer-dependent timestamps
        /// and metadata.
        func hashes(_ file: URL) async throws -> [String] {
            let data = try await Command().run(tools.ffmpeg, ["-v", "error", "-i", file.path, "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", "-"])
            return String(data: data, encoding: .utf8)!.components(separatedBy: .newlines)
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { $0.components(separatedBy: ",").last!.trimmingCharacters(in: .whitespaces) }
        }
        let originalHashes = try await hashes(source)
        let exportedHashes = try await hashes(lossless)
        let expectedHashes = Array(originalHashes[0..<50]) + Array(originalHashes[100..<150])
        precondition(exportedHashes == expectedHashes, "Lossless output must contain exactly the selected decoded frames")
        // Cover no-audio sources and replacing an existing destination.
        let silent = root.appendingPathComponent("silent.mp4")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-i", source.path, "-map", "0:v:0", "-c", "copy", silent.path])
        try await MediaEngine.export(source: silent, clips: [Clip(start: 0.52, end: 1.4)], mode: .exact, destination: exact, tools: tools) { _, _ in }
        let singleData = try await Command().run(tools.ffprobe, ["-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", exact.path])
        precondition(String(data: singleData, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines) == "22")
        let hevc = root.appendingPathComponent("hevc.mov")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-i", source.path, "-map", "0:v:0", "-c:v", "libx265", "-x265-params", "log-level=error:keyint=50:min-keyint=50:scenecut=0", "-tag:v", "hvc1", hevc.path])
        let hevcOut = root.appendingPathComponent("hevc-open-gop-cut.mov")
        let openResult = try await MediaEngine.export(source: hevc, clips: [Clip(start: 2, end: 4), Clip(start: 6, end: 8)], mode: .lossless, destination: hevcOut, tools: tools, expectedVideoFrames: 100) { _, _ in }
        precondition(openResult.needsReview && openResult.warningMessage!.contains("The video was saved"))
        precondition(FileManager.default.fileExists(atPath: hevcOut.path), "Questionable output must be saved for review")
        let closed = root.appendingPathComponent("hevc-closed.mov")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-i", source.path, "-map", "0:v:0", "-c:v", "libx265", "-x265-params", "log-level=error:keyint=50:min-keyint=50:scenecut=0:open-gop=0", "-tag:v", "hvc1", closed.path])
        let closedOut = root.appendingPathComponent("hevc-closed-cut.mov")
        let closedResult = try await MediaEngine.export(source: closed, clips: [Clip(start: 2, end: 4), Clip(start: 6, end: 8)], mode: .lossless, destination: closedOut, tools: tools, expectedVideoFrames: 100) { _, _ in }
        precondition(!closedResult.needsReview, "Clean HEVC export should not warn: \(closedResult.reviewNotes)")
        let hevcHashes = try await hashes(closed)
        let hevcCutHashes = try await hashes(closedOut)
        precondition(hevcCutHashes == Array(hevcHashes[50..<100]) + Array(hevcHashes[150..<200]), "HEVC lossless boundary mismatch")
        let windows = MediaEngine.verificationWindows(clips: [Clip(start: 0, end: 1000), Clip(start: 2000, end: 3000)], duration: 2000)
        precondition(windows.reduce(0) { $0 + $1.duration } == 8, "Long exports should sample only the beginning, join, and end")
        let mismatch = try await MediaEngine.verifyLossless(output: lossless, clips: [Clip(start: 0, end: 4)], expectedVideoFrames: 999, tools: tools)
        precondition(mismatch.needsReview && mismatch.reviewNotes.contains { $0.contains("999") })
        let decodeFailure = try await MediaEngine.verifyLossless(output: lossless, clips: [Clip(start: 0, end: 4)], expectedVideoFrames: 100,
            tools: Toolchain(ffmpeg: URL(fileURLWithPath: "/usr/bin/false"), ffprobe: tools.ffprobe))
        precondition(decodeFailure.needsReview && decodeFailure.reviewNotes.contains { $0.contains("decoding problem") })
        let unverified = root.appendingPathComponent("unverified.mov")
        let inspectionFailure = try await MediaEngine.export(source: source, clips: [Clip(start: 0, end: 2)], mode: .lossless, destination: unverified,
            tools: Toolchain(ffmpeg: tools.ffmpeg, ffprobe: URL(fileURLWithPath: "/usr/bin/false")), expectedVideoFrames: 50) { _, _ in }
        precondition(inspectionFailure.needsReview && FileManager.default.fileExists(atPath: unverified.path))
        let stallRoot = root.appendingPathComponent("verification-stall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stallRoot, withIntermediateDirectories: true)
        let marker = stallRoot.appendingPathComponent("started")
        let stalledProbe = stallRoot.appendingPathComponent("ffprobe")
        let markerPath = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try ("#!/bin/sh\ntrap '' TERM\nprintf ready > " + markerPath + "\nexec /bin/sleep 30\n")
            .write(to: stalledProbe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stalledProbe.path)
        let cancelledReview = stallRoot.appendingPathComponent("cancelled-review.mov")
        let reviewTask = Task {
            try await MediaEngine.export(source: source, clips: [Clip(start: 0, end: 2)], mode: .lossless, destination: cancelledReview,
                tools: Toolchain(ffmpeg: tools.ffmpeg, ffprobe: stalledProbe), expectedVideoFrames: 50) { _, _ in }
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(FileManager.default.fileExists(atPath: marker.path), "Verification must be running before cancellation")
        reviewTask.cancel()
        do { _ = try await reviewTask.value; fatalError("Verification cancellation must not become a warning") }
        catch is CancellationError { }
        precondition(!FileManager.default.fileExists(atPath: cancelledReview.path))
        let empty = root.appendingPathComponent("empty.mov")
        try Data().write(to: empty)
        do {
            _ = try await MediaEngine.verifyLossless(output: empty, clips: [Clip(start: 0, end: 2)], expectedVideoFrames: 50, tools: tools)
            fatalError("Empty output must fail")
        } catch is MediaError { }
        let audioOnly = root.appendingPathComponent("audio-only.mov")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-i", source.path, "-map", "0:a:0", "-c", "copy", audioOnly.path])
        do {
            _ = try await MediaEngine.verifyLossless(output: audioOnly, clips: [Clip(start: 0, end: 2)], expectedVideoFrames: 50, tools: tools)
            fatalError("No-video output must fail")
        } catch is MediaError { }
        let before = try Data(contentsOf: exact)
        do {
            try await MediaEngine.export(source: source, clips: [Clip(start: 0, end: 2)], mode: .lossless, destination: exact,
                tools: Toolchain(ffmpeg: URL(fileURLWithPath: "/usr/bin/false"), ffprobe: tools.ffprobe), expectedVideoFrames: 50) { _, _ in }
            fatalError("Failed FFmpeg export must fail")
        } catch is MediaError { }
        let after = try Data(contentsOf: exact)
        precondition(after == before, "Failed export must preserve the existing destination")
        let cancelled = root.appendingPathComponent("cancelled.mp4")
        let operation = Task {
            try await MediaEngine.export(source: source, clips: [Clip(start: 0, end: 8)], mode: .exact, destination: cancelled, tools: tools) { _, _ in }
        }
        operation.cancel()
        do { _ = try await operation.value; fatalError("Cancellation should throw") } catch is CancellationError { }
        precondition(!FileManager.default.fileExists(atPath: cancelled.path))
        // Saving measures bytes separately and preserves old output on cancellation.
        let saveSource = root.appendingPathComponent("save-source.bin")
        let saveTarget = root.appendingPathComponent("save-target.bin")
        let payload = Data(repeating: 0xA5, count: 4 * 1024 * 1024 + 17)
        try payload.write(to: saveSource)
        try await MediaEngine.save(saveSource, to: saveTarget) { value, _ in
            precondition(value >= 0 && value <= 1)
        }
        let savedBytes = try Data(contentsOf: saveTarget)
        precondition(savedBytes == payload)
        let saveTask = Task {
            try await MediaEngine.save(saveSource, to: saveTarget) { value, _ in
                if value == 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { try await saveTask.value; fatalError("Save cancellation must throw") } catch is CancellationError { }
        let preservedBytes = try Data(contentsOf: saveTarget)
        precondition(preservedBytes == payload)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".FrameCut-") }
        precondition(leftovers.isEmpty, "Partial saves must be cleaned up")
        // Codec/quality choices must affect the real encoder while retaining exact cuts.
        precondition(ExportSettings.defaults(for: ExportMode.lossless).codec == .lossless)
        precondition(ExportSettings.defaults(for: ExportMode.exact).codec == .hevc)
        for codec in [ExportCodec.h264, .hevc, .prores] {
            var settings = ExportSettings.defaults(for: codec)
            settings.crf = 21
            if codec != .prores { settings.tune = "animation" }
            else { settings.proResProfile = .hq }
            let output = root.appendingPathComponent("configured-\(codec == .h264 ? "h264" : codec == .hevc ? "hevc" : "prores").mov")
            try await MediaEngine.export(source: source, clips: selected, mode: .exact, destination: output, tools: tools, settings: settings) { _, _ in }
            let data = try await Command().run(tools.ffprobe, ["-v", "error", "-count_frames", "-show_streams", "-of", "json", output.path])
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let streams = json["streams"] as! [[String: Any]]
            let video = streams.first { $0["codec_type"] as? String == "video" }!
            precondition(video["codec_name"] as? String == (codec == .h264 ? "h264" : codec == .hevc ? "hevc" : "prores"))
            precondition(video["nb_read_frames"] as? String == "52", "Every codec must retain the exact selected frame count")
            let audio = streams.first { $0["codec_type"] as? String == "audio" }!
            precondition(audio["codec_name"] as? String == (codec == .prores ? "pcm_s24le" : "aac"))
            if codec == .hevc {
                precondition(video["codec_tag_string"] as? String == "hvc1" && video["pix_fmt"] as? String == "yuv420p10le")
            }
            if codec == .prores {
                precondition(video["profile"] as? String == "HQ" && video["pix_fmt"] as? String == "yuv422p10le")
            }
        }
        var sizes: [Int] = []
        for crf in [12, 40] {
            var settings = ExportSettings.defaults(for: ExportCodec.h264); settings.crf = crf
            let output = root.appendingPathComponent("quality-\(crf).mp4")
            try await MediaEngine.export(source: source, clips: [Clip(start: 0, end: 2)], mode: .exact, destination: output, tools: tools, settings: settings) { _, _ in }
            sizes.append(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        }
        precondition(sizes[0] > sizes[1], "The selected CRF must control encoding quality/size")
        let invalidOptions = [ExportSettings(codec: .h264, crf: -1), ExportSettings(codec: .hevc, crf: 22, tune: "film"),
                              ExportSettings.defaults(for: ExportCodec.prores), ExportSettings.defaults(for: ExportCodec.lossless)]
        for settings in invalidOptions {
            do {
                try await MediaEngine.export(source: source, clips: selected, mode: .exact, destination: exact, tools: tools, settings: settings) { _, _ in }
                fatalError("Invalid codec/quality/container combinations must fail before writing")
            } catch is MediaError { }
        }
        let stillPreserved = try Data(contentsOf: exact)
        precondition(stillPreserved == before, "Invalid settings must preserve an existing export")
        print("PASS: H.264/10-bit HEVC/ProRes HQ exact exports, animation tunes, CRF quality changes, invalid-setting preservation, keyframes, snapping, overlap rejection, exact frame counts (with/without audio), H.264/HEVC lossless frame hashes and boundaries, open-GOP warning with saved output, bounded checks, hard-failure preservation, overwrite, cancellation")
        print("Fixtures: \(root.path)")
    }
}

import Foundation

/// Integration checks for working-copy isolation, format conversion, retained audio tracks, and import cancellation.
@main
struct ImportTests {
    /// Exercises real FFmpeg imports and exports using the shared fixture created by EngineTests.
    static func main() async throws {
        let tools = try Toolchain.testing()
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = root.appendingPathComponent("fixture.mp4")
        let original = try Data(contentsOf: source)
        /// Returns decoded-frame checksums to verify that remuxing preserves picture content.
        func hashes(_ file: URL) async throws -> [String] {
            let data = try await Command().run(tools.ffmpeg, ["-v", "error", "-i", file.path, "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", "-"])
            return String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { $0.components(separatedBy: ",").last!.trimmingCharacters(in: .whitespaces) }
        }
        /// Reads stream and chapter metadata for track-preservation assertions.
        func metadata(_ url: URL) async throws -> [String: Any] {
            let data = try await Command().run(tools.ffprobe, ["-v", "error", "-show_streams", "-show_chapters", "-of", "json", url.path])
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        let originalHashes = try await hashes(source)
        for ext in ["mp4", "mkv", "ts"] {
            let file: URL
            if ext == "mp4" { file = source }
            else {
                file = root.appendingPathComponent("import-source.\(ext)")
                _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-i", source.path, "-c", "copy", file.path])
            }
            let plan = try await ImportEngine.inspect(file, tools: tools)
            precondition(!plan.needsConfirmation && !plan.convertVideo && !plan.convertAudio)
            let copy = try await ImportEngine.prepare(plan, tools: tools) { _ in }
            precondition(copy.url != file && copy.url.pathExtension == "mov")
            let copiedHashes = try await hashes(copy.url)
            precondition(copiedHashes == originalHashes, "Remux must preserve decoded frames for \(ext)")
            let index = try await MediaEngine.index(source: copy.url, tools: tools)
            let clips = [Clip(start: index.keyframes[0], end: index.keyframes[1]), Clip(start: index.keyframes[2], end: index.keyframes[3])]
            let cut = root.appendingPathComponent("import-cut-\(ext).mov")
            try await MediaEngine.export(source: copy.url, clips: clips, mode: .lossless, destination: cut,
                tools: tools, expectedVideoFrames: index.frameCount(in: clips)) { _, _ in }
            let cutHashes = try await hashes(cut)
            precondition(cutHashes == Array(originalHashes[0..<50]) + Array(originalHashes[100..<150]), "Imported \(ext) must cut and join the intended source frames")
        }
        let remoteStandIn = root.appendingPathComponent("detachable.mp4")
        try original.write(to: remoteStandIn)
        let offlinePlan = try await ImportEngine.inspect(remoteStandIn, tools: tools)
        let offlineCopy = try await ImportEngine.prepare(offlinePlan, tools: tools) { _ in }
        try FileManager.default.removeItem(at: remoteStandIn)
        let offlineIndex = try await MediaEngine.index(source: offlineCopy.url, tools: tools)
        let offlineExport = root.appendingPathComponent("offline-export.mov")
        try await MediaEngine.export(source: offlineCopy.url, clips: [Clip(start: 0, end: 2)], mode: .lossless,
            destination: offlineExport, tools: tools, expectedVideoFrames: offlineIndex.frameCount(in: [Clip(start: 0, end: 2)])) { _, _ in }
        precondition(FileManager.default.fileExists(atPath: offlineExport.path), "Export must work after the original disappears")
        let avi = root.appendingPathComponent("legacy.avi")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-i", source.path, "-t", "1", "-map", "0:v:0", "-c:v", "mpeg4", avi.path])
        let videoPlan = try await ImportEngine.inspect(avi, tools: tools)
        precondition(videoPlan.needsConfirmation && videoPlan.convertVideo)
        precondition(videoPlan.summary.contains { $0.contains("not lossless") })
        let videoCopy = try await ImportEngine.prepare(videoPlan, tools: tools) { _ in }
        let convertedMetadata = try await metadata(videoCopy.url)
        precondition((convertedMetadata["streams"] as! [[String: Any]])[0]["codec_name"] as? String == "h264")

        let ac3 = root.appendingPathComponent("ac3.mkv")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-i", source.path, "-c:v", "copy", "-c:a", "ac3", ac3.path])
        let audioPlan = try await ImportEngine.inspect(ac3, tools: tools)
        precondition(audioPlan.needsConfirmation && !audioPlan.convertVideo && audioPlan.convertAudio)
        let audioCopy = try await ImportEngine.prepare(audioPlan, tools: tools) { _ in }
        let audioMetadata = try await metadata(audioCopy.url)
        precondition((audioMetadata["streams"] as! [[String: Any]]).contains { $0["codec_name"] as? String == "aac" })
        let audioCopyHashes = try await hashes(audioCopy.url)
        precondition(audioCopyHashes == originalHashes, "Audio conversion must leave video untouched")

        let subtitles = root.appendingPathComponent("subtitles.srt")
        try "1\n00:00:00,000 --> 00:00:01,000\nTest subtitle\n".write(to: subtitles, atomically: true, encoding: .utf8)
        let chapters = root.appendingPathComponent("chapters.ffmeta")
        try ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Introduction\n".write(to: chapters, atomically: true, encoding: .utf8)
        let attachment = root.appendingPathComponent("attachment.txt")
        try "Test attachment".write(to: attachment, atomically: true, encoding: .utf8)
        let extras = root.appendingPathComponent("extra-tracks.mkv")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-i", source.path, "-i", subtitles.path,
            "-f", "ffmetadata", "-i", chapters.path, "-map", "0:v:0", "-map", "0:a:0", "-map", "0:a:0", "-map", "1:s:0",
            "-c", "copy", "-map_chapters", "2", "-metadata:s:a:1", "language=deu", "-metadata:s:a:1", "title=German alternative",
            "-attach", attachment.path, "-metadata:s:t:0", "mimetype=text/plain", extras.path])
        let extrasPlan = try await ImportEngine.inspect(extras, tools: tools)
        precondition(extrasPlan.needsConfirmation && extrasPlan.omissions.count == 3)
        precondition(extrasPlan.audioTracks.count == 2 && extrasPlan.summary.contains { $0.contains("German alternative") && $0.contains("deu") })
        precondition(extrasPlan.omissions.contains { $0.contains("Subtitle") })
        precondition(extrasPlan.omissions.contains { $0.contains("Attachment") })
        precondition(extrasPlan.omissions.contains { $0.contains("chapter") })
        let extrasCopy = try await ImportEngine.prepare(extrasPlan, tools: tools) { _ in }
        let extrasMetadata = try await metadata(extrasCopy.url)
        precondition((extrasMetadata["streams"] as! [[String: Any]]).count == 3)
        precondition((extrasMetadata["chapters"] as! [[String: Any]]).isEmpty)

        // Three distinct tracks catch accidentally duplicating the first audio,
        // dropping later tracks, or applying one codec decision to every track.
        let multi = root.appendingPathComponent("multi-audio.mkv")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-i", source.path,
            "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000:duration=8",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=8",
            "-map", "0:v:0", "-map", "0:a:0", "-map", "1:a:0", "-map", "2:a:0",
            "-c:v", "copy", "-c:a:0", "copy", "-c:a:1", "ac3", "-ac:a:1", "2", "-c:a:2", "aac",
            "-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "title=English",
            "-metadata:s:a:1", "language=deu", "-metadata:s:a:1", "title=German",
            "-metadata:s:a:2", "language=fra", "-metadata:s:a:2", "title=Audio description",
            "-disposition:a:0", "0", "-disposition:a:1", "default", "-disposition:a:2", "visual_impaired", multi.path])
        let multiPlan = try await ImportEngine.inspect(multi, tools: tools)
        precondition(multiPlan.audioTracks.count == 3 && multiPlan.omissions.isEmpty)
        precondition(multiPlan.audioTracks.map(\.needsConversion) == [false, true, false])
        let multiCopy = try await ImportEngine.prepare(multiPlan, tools: tools) { _ in }
        /// Hashes copied audio packet data to detect any unintended re-encoding.
        func packetHash(_ file: URL, track: Int) async throws -> Data {
            try await Command().run(tools.ffmpeg, ["-v", "error", "-i", file.path, "-map", "0:a:\(track)", "-c", "copy", "-f", "hash", "-hash", "sha256", "-"])
        }
        for track in [0, 2] {
            let before = try await packetHash(multi, track: track)
            let after = try await packetHash(multiCopy.url, track: track)
            precondition(before == after, "Compatible audio must be copied without re-encoding")
        }
        /// Checks all three audio identities, labels, channels, defaults, duration, and
        /// distinguishing test-tone frequencies.
        func checkTracks(_ file: URL, duration: Double) async throws {
            let info = try await metadata(file)
            let tracks = (info["streams"] as! [[String: Any]]).filter { $0["codec_type"] as? String == "audio" }
            precondition(tracks.count == 3, "Every audio track must survive import and both export modes")
            for (ordinal, track) in tracks.enumerated() {
                let tags = track["tags"] as? [String: String] ?? [:]
                precondition(tags["language"] == ["eng", "ger", "fra"][ordinal])
                precondition(tags["handler_name"] == ["English", "German", "Audio description"][ordinal])
                precondition(track["channels"] as? Int == [1, 2, 1][ordinal])
                precondition((track["disposition"] as? [String: Int])?["default"] == (ordinal == 1 ? 1 : 0))
                let length = Double(track["duration"] as? String ?? "0") ?? 0
                precondition(abs(length - duration) < 0.15, "Each audio track must cover the joined ranges")
                let pcm = try await Command().run(tools.ffmpeg, ["-v", "error", "-ss", "0.4", "-i", file.path,
                    "-t", "0.5", "-map", "0:a:\(ordinal)", "-ac", "1", "-ar", "8000", "-f", "f32le", "-"])
                let samples: [Float] = pcm.withUnsafeBytes { bytes in
                    stride(from: 0, to: bytes.count - 3, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
                }
                let crossings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
                let frequency = Double(crossings) / (Double(samples.count) / 8000)
                precondition(abs(frequency - [440.0, 660.0, 880.0][ordinal]) < 15, "Track identity must survive cutting")
            }
        }
        try await checkTracks(multiCopy.url, duration: 8)
        let compatibleMultiPlan = try await ImportEngine.inspect(multiCopy.url, tools: tools)
        precondition(compatibleMultiPlan.audioTracks.count == 3 && !compatibleMultiPlan.needsConfirmation,
                     "Multiple compatible audio tracks must not require a track-selection review")
        for mode in ExportMode.allCases {
            for ext in ["mov", "mp4"] {
                let output = root.appendingPathComponent("multi-audio-\(mode.id).\(ext)")
                try await MediaEngine.export(source: multiCopy.url, clips: [Clip(start: 0, end: 2), Clip(start: 4, end: 6)],
                    mode: mode, destination: output, tools: tools, expectedVideoFrames: 100) { _, _ in }
                try await checkTracks(output, duration: 4)
            }
        }

        let multiProRes = root.appendingPathComponent("multi-audio-prores.mov")
        try await MediaEngine.export(source: multiCopy.url, clips: [Clip(start: 0, end: 2), Clip(start: 4, end: 6)],
            mode: .exact, destination: multiProRes, tools: tools, settings: .defaults(for: ExportCodec.prores)) { _, _ in }
        try await checkTracks(multiProRes, duration: 4)

        let interlaced = root.appendingPathComponent("interlaced.ts")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=50:duration=2",
            "-vf", "tinterlace=interleave_top", "-c:v", "libx264", "-flags", "+ilme+ildct", "-field_order", "tt", interlaced.path])
        let interlacedPlan = try await ImportEngine.inspect(interlaced, tools: tools)
        precondition(interlacedPlan.isInterlaced && interlacedPlan.needsConfirmation)
        precondition(!interlacedPlan.deinterlace && !interlacedPlan.encodesVideo)
        precondition(interlacedPlan.summary.contains { $0.contains("may show artifacts") })
        let interlacedCopy = try await ImportEngine.prepare(interlacedPlan, tools: tools) { _ in }
        let interlacedOriginalHashes = try await hashes(interlaced)
        let interlacedCopyHashes = try await hashes(interlacedCopy.url)
        precondition(interlacedOriginalHashes == interlacedCopyHashes, "Default must preserve interlaced video without re-encoding")
        var progressivePlan = interlacedPlan
        progressivePlan.deinterlace = true
        precondition(progressivePlan.summary.contains { $0.contains("deinterlace to progressive") })
        let progressiveCopy = try await ImportEngine.prepare(progressivePlan, tools: tools) { _ in }
        let progressiveMetadata = try await metadata(progressiveCopy.url)
        let progressiveStream = (progressiveMetadata["streams"] as! [[String: Any]])[0]
        precondition(progressiveStream["field_order"] as? String == "progressive")
        let progressiveHashes = try await hashes(progressiveCopy.url)
        precondition(progressiveHashes.count == 2 * interlacedOriginalHashes.count, "One progressive frame per field must retain field-rate motion")
        let mpeg2 = root.appendingPathComponent("interlaced-mpeg2.ts")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-i", interlaced.path, "-c:v", "mpeg2video", "-flags", "+ilme+ildct", "-field_order", "tt", mpeg2.path])
        let mpeg2Plan = try await ImportEngine.inspect(mpeg2, tools: tools)
        precondition(mpeg2Plan.isInterlaced && mpeg2Plan.convertVideo && !mpeg2Plan.deinterlace)
        let mpeg2Copy = try await ImportEngine.prepare(mpeg2Plan, tools: tools) { _ in }
        let mpeg2Metadata = try await metadata(mpeg2Copy.url)
        let mpeg2Stream = (mpeg2Metadata["streams"] as! [[String: Any]])[0]
        precondition(mpeg2Stream["field_order"] as? String == "tt", "Required codec conversion must preserve interlacing when deinterlacing is off")

        // Field-order compatibility must also retain bottom-field-first recordings.
        let bottom = root.appendingPathComponent("interlaced-bottom-mpeg2.ts")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=50:duration=2",
            "-vf", "tinterlace=interleave_bottom", "-c:v", "mpeg2video", "-flags", "+ilme+ildct", "-field_order", "bb", bottom.path])
        let bottomPlan = try await ImportEngine.inspect(bottom, tools: tools)
        precondition(bottomPlan.fieldOrder == "bb" && bottomPlan.convertVideo && !bottomPlan.deinterlace)
        let bottomCopy = try await ImportEngine.prepare(bottomPlan, tools: tools) { _ in }
        let bottomMetadata = try await metadata(bottomCopy.url)
        let bottomOrder = (bottomMetadata["streams"] as! [[String: Any]])[0]["field_order"] as? String ?? ""
        // H.264 can code the top field first while displaying the bottom first (tb).
        precondition(["bb", "tb"].contains(bottomOrder),
                     "Required codec conversion must preserve bottom-field-first interlacing")

        // Partial copies must be cleaned when cancellation kills an active importer.
        let scratch = root.appendingPathComponent("import-stall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let marker = scratch.appendingPathComponent("output-path")
        let wrapper = scratch.appendingPathComponent("ffmpeg")
        let markerPath = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        trap '' TERM
        for last; do :; done
        printf partial > "$last"
        printf '%s' "$last" > \(markerPath)
        printf 'out_time_us=1000000\\n'
        exec /bin/sleep 30
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let plan = try await ImportEngine.inspect(source, tools: tools)
        let operation = Task { try await ImportEngine.prepare(plan, tools: Toolchain(ffmpeg: wrapper, ffprobe: tools.ffprobe)) { _ in } }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(FileManager.default.fileExists(atPath: marker.path))
        let partialPath = try String(contentsOf: marker, encoding: .utf8)
        precondition(FileManager.default.fileExists(atPath: partialPath))
        operation.cancel()
        do { _ = try await operation.value; fatalError("Import cancellation must throw") } catch is CancellationError { }
        precondition(!FileManager.default.fileExists(atPath: partialPath), "Cancelled partial copy must be removed")
        let after = try Data(contentsOf: source)
        precondition(after == original, "Original must remain byte-identical")
        print("PASS: MP4/MKV/TS remux hashes, AVI video conversion, AC3 audio-only conversion, all audio tracks in mixed-codec import and both MOV/MP4 export modes, audio packet preservation/identity/languages/labels/channels/defaults, explicit non-audio track/chapter omissions, interlacing warning/default-copy/optional-deinterlace, partial-copy cancellation, unchanged original")
    }
}

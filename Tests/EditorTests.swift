import AppKit
import AVFoundation
import Foundation
import Darwin

/// Main-actor regression checks for edit history, playback, previews, import replacement, document events, and shutdown.
@main
struct EditorTests {
    /// Waits with a deadline while yielding the main actor so AVFoundation and editor tasks can
    /// complete.
    @MainActor
    static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw MediaError(message: "Timed out: \(message)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Exercises one editor session against real local media and simulated slow/cancelled
    /// imports.
    @MainActor
    static func main() async throws {
        let tools = try Toolchain.testing()
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = root.appendingPathComponent("fixture.mp4")
        let silent = root.appendingPathComponent("silent.mp4")
        let disguised = root.appendingPathComponent("transport-renamed.mp4")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-i", source.path, "-c", "copy", "-f", "mpegts", disguised.path])
        let tsPlan = try await ImportEngine.inspect(disguised, tools: tools)
        precondition(!tsPlan.convertVideo)
        let editor = EditorModel(tools: tools)
        // Launch Services may send the document before the SwiftUI window attaches.
        let delegate = AppDelegate()
        delegate.openURLs([source])
        delegate.editor = editor
        try await waitUntil("cold-launch file opening") { editor.ready || editor.error != nil }
        precondition(editor.error == nil && editor.originalSource == source && editor.keyframes.count == 4)
        precondition(!editor.canUndo && editor.clips.isEmpty && !editor.canExport)
        let points = [CutPoint(kind: .end, time: 0.2), CutPoint(kind: .start, time: 0.52),
                      CutPoint(kind: .start, time: 0.8), CutPoint(kind: .end, time: 1.4),
                      CutPoint(kind: .end, time: 2), CutPoint(kind: .start, time: 4.12),
                      CutPoint(kind: .start, time: 4.4), CutPoint(kind: .end, time: 5.32)]
        let derived = CutTimeline.selections(points.reversed(), duration: 8).map(\.clip)
        precondition(derived.map(\.start) == [0.52, 4.12] && derived.map(\.end) == [1.4, 5.32])
        let adjacent = CutTimeline.selections([CutPoint(kind: .start, time: 1), CutPoint(kind: .start, time: 2),
                                              CutPoint(kind: .end, time: 2), CutPoint(kind: .end, time: 3)], duration: 8)
        precondition(adjacent.map { $0.clip.start } == [1, 2] && adjacent.map { $0.clip.end } == [2, 3])
        for point in points { editor.addCut(point.kind, at: point.time) }
        precondition(editor.clips.map(\.start) == [0.52, 4.12] && editor.clips.map(\.end) == [1.4, 5.32])
        precondition(editor.cutPoints.count == 8 && editor.canExport)
        let ordered = editor.sortedCutPoints
        editor.selectCut(ordered[0].id)
        editor.selectAdjacentCut(-1)
        precondition(editor.selectedCutID == ordered[0].id, "Navigation must stop at the first cut")
        for point in ordered.dropFirst() {
            editor.selectAdjacentCut(1)
            precondition(editor.selectedCutID == point.id && abs(editor.position - point.time) < 0.00001)
            precondition(editor.player.rate == 0, "Cut navigation pauses playback")
        }
        editor.selectAdjacentCut(1)
        precondition(editor.selectedCutID == ordered.last!.id, "Navigation must stop at the last cut")
        for point in ordered.dropLast().reversed() {
            editor.selectAdjacentCut(-1)
            precondition(editor.selectedCutID == point.id)
        }
        precondition(editor.editUndoManager.undoActionName == "Move Playhead", "Cut navigation must be undoable")
        editor.undo()
        precondition(editor.position == ordered[1].time)
        editor.redo()
        precondition(editor.position == ordered[0].time)
        editor.seek(3)
        editor.selectAdjacentCut(1)
        precondition(editor.selectedCut?.time == 4.12, "After scrubbing, navigate from the playhead")
        let beforeSelection = editor.position
        editor.selectSegment(editor.clips[0].id)
        precondition(editor.position == beforeSelection, "Selecting a segment must not seek")
        editor.seek(0.52)
        editor.selectAdjacentCut(1)
        precondition(editor.selectedCut?.time == 0.8, "Unused points must also be reachable")
        editor.seek(1)
        editor.editUndoManager.removeAllActions()
        editor.scrub(to: 2); editor.scrub(to: 3); editor.scrub(to: 4)
        editor.endScrubbing()
        precondition(editor.position == 4)
        editor.undo()
        precondition(editor.position == 1 && !editor.canUndo, "A complete drag must undo in one step")
        editor.redo()
        precondition(editor.position == 4 && !editor.canRedo)
        editor.undo()
        editor.seek(2)
        precondition(!editor.canRedo, "A new seek must discard the redo branch")
        let beforePlayback = editor.position
        let historyBeforeSelection = editor.editUndoManager.undoActionName
        editor.togglePlayback()
        editor.selectSegment(editor.clips[0].id)
        precondition(editor.player.rate != 0 && editor.position == beforePlayback,
                     "Segment selection must leave playback running and retain the playhead")
        precondition(editor.editUndoManager.undoActionName == historyBeforeSelection)
        editor.player.pause()
        editor.seek(1.4)
        editor.addCut(.start, at: 1.4)
        let coincidentIn = editor.selectedCutID!
        editor.selectAdjacentCut(-1)
        precondition(editor.selectedCut?.kind == .end && editor.selectedCut?.time == 1.4)
        editor.selectAdjacentCut(1)
        precondition(editor.selectedCutID == coincidentIn, "Coincident OUT/IN must each be selectable")
        editor.deleteSelectedCut()
        precondition(editor.cutPoints.count == 8)
        editor.addCut(.start, at: 0.52)
        precondition(editor.cutPoints.count == 8, "Duplicate points at the same frame must select the existing point")
        let firstIn = editor.cutPoints.first { $0.kind == .start && $0.time == 0.52 }!
        let firstOut = editor.cutPoints.first { $0.kind == .end && $0.time == 1.4 }!
        editor.selectCut(firstOut.id)
        editor.deleteSelectedCut()
        precondition(editor.clips[0].end == 2, "The next OUT becomes the selection boundary after deletion")
        editor.undo()
        precondition(editor.clips[0].end == 1.4 && editor.selectedCutID == firstOut.id)
        editor.redo()
        precondition(editor.clips[0].end == 2)
        editor.undo()
        editor.selectCut(firstIn.id); editor.deleteSelectedCut()
        precondition(editor.clips[0].start == 0.8, "The next IN becomes active after the first IN is removed")
        editor.undo()
        precondition(editor.clips[0].start == 0.52 && editor.selectedCutID == firstIn.id)
        editor.mode = .exact
        editor.undo(); precondition(editor.mode == .lossless)
        editor.redo(); precondition(editor.mode == .exact)
        editor.undo()
        editor.addCut(.end, at: 7)
        precondition(!editor.canRedo, "A new cut must discard the redo branch")
        editor.selectSpeed(0)
        precondition(editor.playbackRate == 0.25 && editor.player.rate == 0, "Speed selection while paused must not play")
        editor.changeSpeed(-1)
        precondition(editor.speedIndex == 0)
        editor.selectSpeed(4); editor.changeSpeed(1)
        precondition(editor.playbackRate == 4 && editor.speedIndex == 4)
        editor.selectSpeed(1)
        editor.togglePlayback()
        precondition(editor.player.rate == 0.5, "Play must use the selected rate")
        editor.selectSpeed(3)
        precondition(editor.player.rate == 2, "Changing speed during playback must take effect immediately")
        editor.togglePlayback()
        editor.selectSpeed(0)
        precondition(editor.player.rate == 0)
        editor.togglePlayback()
        precondition(editor.player.rate == 0.25, "Pause/resume must retain speed")
        editor.togglePlayback()
        // Exercise the native restart path directly, not only our toggle method.
        // AVPlayerView can call play() itself after a stop/pause.
        for speed in [0, 1, 3, 4] {
            editor.selectSpeed(speed)
            precondition(editor.player.rate == 0)
            precondition(editor.player.defaultRate == editor.playbackRate)
            editor.player.play()
            precondition(editor.player.rate == editor.playbackRate, "Native restart must use the slider rate")
            editor.player.pause()
            editor.player.play()
            precondition(editor.player.rate == editor.playbackRate, "Repeated native pause/resume must retain speed")
            editor.player.pause()
        }
        editor.seek(2)
        // currentTime can report the target before native decode preroll finishes.
        // Await seek completion so this test does not race stepping against a pending seek.
        let settled = await editor.player.seek(to: CMTime(seconds: 2, preferredTimescale: 600000),
                                               toleranceBefore: .zero, toleranceAfter: .zero)
        precondition(settled)
        try await waitUntil("settled frame-step origin") { abs(editor.player.currentTime().seconds - 2) < 0.001 }
        editor.step(1)
        try await waitUntil("native next frame") { editor.position > 2.001 }
        let stepped = editor.position
        editor.undo()
        precondition(abs(editor.position - 2) < 0.001)
        editor.redo()
        precondition(abs(editor.position - stepped) < 0.001, "Frame stepping must support redo")
        editor.seek(3)
        editor.jumpKeyframe(1)
        precondition(editor.position == 4)
        editor.undo(); precondition(editor.position == 3)
        editor.redo(); precondition(editor.position == 4)
        editor.selectSpeed(2)
        editor.selectSegment(editor.clips[0].id)
        try await waitUntil("lossless boundary pairs") {
            editor.cutPreviews[.inAfter]?.image != nil && editor.cutPreviews[.outBefore]?.image != nil && editor.cutPreviews[.outAfter]?.image != nil
        }
        precondition(editor.previewTime(for: .start) == 0 && editor.previewTime(for: .end) == 2)
        precondition(editor.cutPreviews[.inBefore]?.image == nil && editor.cutPreviews[.inBefore]?.loading == false)
        precondition(!editor.previewIncluded(.inBefore) && editor.previewIncluded(.inAfter))
        precondition(editor.previewIncluded(.outBefore) && !editor.previewIncluded(.outAfter))
        editor.mode = .exact
        try await waitUntil("exact boundary pairs") { CutPreviewSlot.allCases.allSatisfy { editor.cutPreviews[$0]?.image != nil } }
        precondition(editor.previewTime(for: .start) == 0.52 && editor.previewTime(for: .end) == 1.4)
        let firstPreview = editor.cutPreviews[.inAfter]!.image!
        editor.selectSegment(editor.clips[1].id)
        try await waitUntil("second selection previews") { editor.cutPreviews[.inAfter]?.image != nil && editor.cutPreviews[.inAfter]?.boundary == 4.12 }
        precondition(editor.previewTime(for: .end) == 5.32 && editor.cutPreviews[.inAfter]!.image !== firstPreview)
        let unusedIn = editor.cutPoints.first { $0.time == 0.8 }!
        editor.selectCut(unusedIn.id)
        try await waitUntil("unused point pair") { editor.cutPreviews[.inBefore]?.image != nil && editor.cutPreviews[.inAfter]?.image != nil }
        precondition(editor.selectedSegmentID == nil && editor.previewTime(for: .start) == 0.8)
        precondition(editor.previewIncluded(.inBefore) && editor.previewIncluded(.inAfter), "An unused IN inside a selection excludes neither side")
        editor.addCut(.start, at: 7.2)
        precondition(editor.clips.last!.end == editor.duration, "An unmatched IN must immediately select through EOF")
        try await waitUntil("EOF boundary pair") { editor.cutPreviews[.outBefore]?.image != nil }
        precondition(editor.cutPreviews[.outAfter]?.boundary == editor.duration && editor.cutPreviews[.outAfter]?.image == nil)
        precondition(editor.previewIncluded(.outBefore) && !editor.previewIncluded(.outAfter))
        editor.undo()
        precondition(editor.clips.count == 2)
        // Removing all cuts is undoable one point at a time, including unused cuts.
        while let point = editor.cutPoints.first { editor.selectCut(point.id); editor.deleteSelectedCut() }
        precondition(editor.clips.isEmpty && !editor.canExport)
        editor.mode = .lossless
        let firstCopy = editor.source!
        precondition(firstCopy != source && FileManager.default.fileExists(atPath: firstCopy.path))
        precondition(firstCopy.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        editor.open(root.appendingPathComponent("missing.ts"))
        try await waitUntil("failed import") { editor.error != nil }
        precondition(editor.ready && editor.originalSource == source && editor.source == firstCopy, "Failed import must preserve the current edit")
        editor.error = nil
        editor.addCut(.start, at: 0); editor.addCut(.end, at: 1)
        editor.open(root.appendingPathComponent("extra-tracks.mkv"))
        try await waitUntil("import review") { editor.pendingImport != nil || editor.error != nil }
        precondition(editor.pendingImport?.omissions.count == 3 && !editor.ready)
        precondition(!editor.canUndo, "Undo must be unavailable during import")
        precondition(editor.source == firstCopy && FileManager.default.fileExists(atPath: firstCopy.path))
        editor.cancelLoading()
        precondition(editor.ready && editor.clips.count == 1 && editor.source == firstCopy, "Declining import must preserve the edit")
        precondition(editor.canUndo, "Declining import must preserve undo history")
        let legacy = root.appendingPathComponent("legacy.avi")
        editor.open(legacy)
        try await waitUntil("video conversion review") { editor.pendingImport != nil || editor.error != nil }
        precondition(editor.pendingImport?.convertVideo == true && editor.source == firstCopy)
        editor.confirmImport()
        try await waitUntil("approved video conversion") { editor.ready || editor.error != nil }
        precondition(editor.error == nil && editor.originalSource == legacy && editor.importDescription.contains("converted to H.264"))
        let interlaced = root.appendingPathComponent("interlaced.ts")
        editor.open(interlaced)
        try await waitUntil("interlacing warning") { editor.pendingImport != nil || editor.error != nil }
        precondition(editor.pendingImport?.isInterlaced == true && editor.pendingImport?.deinterlace == false)
        editor.confirmImport()
        try await waitUntil("default interlaced copy") { editor.ready || editor.error != nil }
        precondition(editor.error == nil && editor.importDescription.contains("video copied losslessly"))
        editor.open(interlaced)
        try await waitUntil("optional deinterlacing") { editor.pendingImport != nil || editor.error != nil }
        var choice = editor.pendingImport!
        choice.deinterlace = true
        editor.confirmImport(choice)
        try await waitUntil("approved deinterlacing") { editor.ready || editor.error != nil }
        precondition(editor.error == nil && editor.importDescription.contains("deinterlaced to H.264"))
        // A warm Dock/Finder event should replace the source as well.
        delegate.application(NSApplication.shared, open: [silent])
        try await waitUntil("warm file opening") { editor.ready || editor.error != nil }
        precondition(editor.error == nil && editor.originalSource == silent)
        precondition(!FileManager.default.fileExists(atPath: firstCopy.path), "Replaced copy must be removed")
        editor.open(disguised)
        try await waitUntil("TS import") { editor.ready || editor.error != nil }
        precondition(editor.error == nil && editor.originalSource == disguised && editor.source != disguised)
        let lastCopy = editor.source!
        await editor.shutdown()
        precondition(!FileManager.default.fileExists(atPath: lastCopy.path), "Quit must remove the local working copy")

        let work = root.appendingPathComponent("slow-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let pidFile = work.appendingPathComponent("child.pid")
        let wrapper = work.appendingPathComponent("ffprobe")
        let slow = root.appendingPathComponent("slow.mp4")
        if !FileManager.default.fileExists(atPath: slow.path) {
            try FileManager.default.copyItem(at: source, to: slow)
        }
        /// Shell-quotes a fixture path for the test-only stalled ffprobe wrapper.
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // Model a probe stalled on network I/O, inheriting an ignored SIGTERM.
        // The last argument identifies the slow fixture; normal replacements run normally.
        let script = """
        #!/bin/sh
        case " $* " in
          *" -show_packets "*"/slow.mov "*)
            trap '' TERM
            echo $$ > \(quote(pidFile.path))
            printf 'pts_time=2.000000|flags=K__\\n'
            exec /bin/sleep 30
            ;;
        esac
        exec \(quote(tools.ffprobe.path)) "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let slowTools = Toolchain(ffmpeg: tools.ffmpeg, ffprobe: wrapper)
        let loading = EditorModel(tools: slowTools)
        loading.open(slow)
        try await waitUntil("active slow indexing") { loading.scanning && loading.indexingProgress > 0.1 }
        precondition(!loading.ready && !loading.canExport && loading.player.currentItem == nil)
        loading.togglePlayback(); loading.step(1); loading.seek(3); loading.setIn(); loading.addCut(.start, at: 1)
        precondition(loading.player.rate == 0 && loading.position == 0 && loading.cutPoints.isEmpty && loading.clips.isEmpty)
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        precondition(kill(pid, 0) == 0, "Slow probe should actually be running")
        let start = Date()
        await loading.shutdown()
        precondition(Date().timeIntervalSince(start) < 1, "Quit must not wait for indexing")
        try await waitUntil("probe exit") { kill(pid, 0) != 0 }
        precondition(!loading.scanning && !loading.loading && !loading.ready)

        loading.open(slow)
        try await waitUntil("second slow indexing") { loading.scanning && loading.indexingProgress > 0.1 }
        loading.cancelLoading()
        precondition(!loading.scanning && !loading.loading && loading.source == nil)
        loading.open(source)
        try await waitUntil("replacement after cancellation") { loading.ready || loading.error != nil }
        precondition(loading.error == nil && loading.originalSource == source && loading.keyframes.count == 4)
        await loading.shutdown()
        print("PASS: playhead seek/drag/frame/keyframe undo-redo, selection without seeking or pausing, edit undo/redo and redo branching, playback speed including native restarts, automatic chronological selections, unused/adjacent/duplicate cuts, cut deletion undo/redo, four boundary previews and EOF, selection/mode preview refresh, local-copy isolation/cleanup, failed/declined-import preservation, conversion/deinterlacing approval, TS import, cold/warm document opening, playback gate, progress, active probe kill, prompt shutdown, cancel and replacement")
    }
}

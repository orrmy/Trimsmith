import SwiftUI
import AppKit
import AVKit

/// App entry point, single editor window, and native menu/keyboard commands.
@main
struct TrimsmithApp: App {
    @StateObject private var editor = EditorModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        // One editor owns one player/export session. WindowGroup would let system
        // document/reopen events create extra views of that same shared session.
        Window("Trimsmith", id: "editor") {
            EditorView(editor: editor)
                .frame(minWidth: 940, minHeight: 780)
                .preferredColorScheme(.dark)
                .onAppear { delegate.editor = editor }
        }
        .defaultSize(width: 1160, height: 880)
        .commands {
            CommandGroup(after: .appInfo) {
                if let notices = Bundle.main.url(forResource: "README", withExtension: "txt", subdirectory: "ThirdParty") {
                    Button("Third-Party Licenses…") { NSWorkspace.shared.open(notices) }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Video…", action: editor.openPanel).keyboardShortcut("o").disabled(editor.exporting)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(editor.editUndoManager.canUndo ? "Undo " + editor.editUndoManager.undoActionName : "Undo", action: editor.undo)
                    .keyboardShortcut("z").disabled(!editor.canUndo)
                Button(editor.editUndoManager.canRedo ? "Redo " + editor.editUndoManager.redoActionName : "Redo", action: editor.redo)
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!editor.canRedo)
            }
            CommandMenu("Playback") {
                Button("Play / Pause", action: editor.togglePlayback).keyboardShortcut(.space, modifiers: []).disabled(!editor.ready)
                Button("Previous Frame") { editor.step(-1) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(!editor.ready || !editor.canStepBack)
                Button("Next Frame") { editor.step(1) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(!editor.ready || !editor.canStepForward)
                Button("Previous Keyframe") { editor.jumpKeyframe(-1) }.keyboardShortcut(.leftArrow, modifiers: .shift).disabled(!editor.ready || editor.keyframes.isEmpty)
                Button("Next Keyframe") { editor.jumpKeyframe(1) }.keyboardShortcut(.rightArrow, modifiers: .shift).disabled(!editor.ready || editor.keyframes.isEmpty)
                Divider()
                ForEach(0..<5) { index in
                    Button("Speed " + EditorModel.playbackRateLabels[index]) { editor.selectSpeed(index) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
                        .disabled(!editor.ready || editor.exporting)
                }
                Button("Faster") { editor.changeSpeed(1) }.keyboardShortcut(.upArrow, modifiers: []).disabled(!editor.ready || editor.exporting)
                Button("Slower") { editor.changeSpeed(-1) }.keyboardShortcut(.downArrow, modifiers: []).disabled(!editor.ready || editor.exporting)
            }
            CommandMenu("Segments") {
                Button("Previous Cut Point") { editor.selectAdjacentCut(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: .command).disabled(!editor.ready || editor.exporting || editor.cutPoints.isEmpty)
                Button("Next Cut Point") { editor.selectAdjacentCut(1) }
                    .keyboardShortcut(.rightArrow, modifiers: .command).disabled(!editor.ready || editor.exporting || editor.cutPoints.isEmpty)
                Divider()
                Button("Set In", action: editor.setIn).keyboardShortcut("i", modifiers: []).disabled(!editor.ready || editor.exporting)
                Button("Set Out", action: editor.setOut).keyboardShortcut("o", modifiers: []).disabled(!editor.ready || editor.exporting)
                Button("Delete Cut Point", action: editor.deleteSelectedCut).keyboardShortcut(.delete, modifiers: []).disabled(!editor.canDeleteCut)
                Button("Export…", action: editor.exportPanel).keyboardShortcut("e").disabled(!editor.canExport)
            }
        }
    }
}

/// Embeds AVPlayerView for native video rendering; the editor provides its own playback controls.
struct NativePlayer: NSViewRepresentable {
    let player: AVPlayer
    /// Creates an aspect-fitting player view without a second set of native playback controls.
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }
    /// Keeps the embedded view connected to the session’s player.
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

/// Main editing interface, including playback, selections, boundary previews, and operation
/// sheets/alerts.
struct EditorView: View {
    @ObservedObject var editor: EditorModel
    private let accent = Color(red: 0.67, green: 0.91, blue: 0.48)
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "scissors").font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Trimsmith").font(.headline)
                    Text(editor.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !editor.importDescription.isEmpty {
                    Text(editor.importDescription).font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 310, alignment: .trailing)
                }
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack {
                        Color.black
                        if editor.ready { NativePlayer(player: editor.player) }
                        if !editor.ready {
                            VStack(spacing: 16) {
                                if !editor.loading && !editor.scanning {
                                    Image(systemName: "film.stack").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(accent)
                                    Text("Keep the moments that matter").font(.title2)
                                    Text("Open or drop a video. Set IN and OUT points. Export one file.").foregroundStyle(.secondary)
                                }
                            }.padding(24)
                        }
                    }.frame(minHeight: 270)
                    VStack(spacing: 14) {
                        HStack {
                            Text(timestamp(editor.position)).monospacedDigit().font(.system(.body, design: .monospaced))
                            Spacer()
                            control("backward.end", "Previous keyframe · ⇧←", disabled: !editor.ready || editor.keyframes.isEmpty) { editor.jumpKeyframe(-1) }
                            control("backward.frame", "Previous frame · ←", disabled: !editor.ready || !editor.canStepBack) { editor.step(-1) }
                            control(editor.playing ? "pause.fill" : "play.fill", "Play / Pause · Space", disabled: !editor.ready) { editor.togglePlayback() }
                            control("forward.frame", "Next frame · →", disabled: !editor.ready || !editor.canStepForward) { editor.step(1) }
                            control("forward.end", "Next keyframe · ⇧→", disabled: !editor.ready || editor.keyframes.isEmpty) { editor.jumpKeyframe(1) }
                            Spacer()
                            Text(timestamp(editor.duration)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        PlaybackSpeedControl(editor: editor)
                        TimelineView(editor: editor, accent: accent).frame(height: 80)
                            .allowsHitTesting(editor.ready).opacity(editor.ready ? 1 : 0.4)
                        HStack(spacing: 12) {
                            Button("Set IN · I", action: editor.setIn)
                            Button("Set OUT · O", action: editor.setOut)
                            Spacer()
                            Text("Selections update automatically").font(.caption).foregroundStyle(.secondary)
                        }.disabled(!editor.ready || editor.exporting)
                        HStack(alignment: .top, spacing: 20) {
                            if editor.selectedCut != nil || editor.selectedSelection != nil {
                                if editor.previewTime(for: .start) != nil { CutBoundaryPreviews(editor: editor, kind: .start) }
                                Spacer(minLength: 0)
                                if editor.previewTime(for: .end) != nil { CutBoundaryPreviews(editor: editor, kind: .end) }
                            } else {
                                Text("Select a cut point or selection to compare the frames on either side of its boundaries.")
                                    .font(.callout).foregroundStyle(.secondary).frame(height: 142, alignment: .center)
                                Spacer(minLength: 0)
                            }
                        }
                        Text("⌘← / ⌘→ select cut points · Backspace deletes · Click a selection to inspect its boundaries.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(20).background(Color.white.opacity(0.025))
                }
                Divider()
                sidebar.frame(width: 300)
            }
            Divider()
            HStack(spacing: 10) {
                if editor.scanning || editor.exporting || editor.loading { ProgressView().controlSize(.small) }
                Text(editor.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if editor.exporting {
                    ExportProgressBar(progress: editor.progress).frame(width: 160, height: 6)
                    if editor.progress >= 0 {
                        Text("\(Int(editor.progress * 100))%").font(.caption.monospacedDigit())
                    }
                    Button("Cancel", action: editor.cancelExport)
                } else if editor.lastExport != nil {
                    if editor.exportNeedsReview {
                        Label("Check playback", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.yellow)
                    }
                    Button("Show in Finder", action: editor.revealExport)
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(Color(red: 0.085, green: 0.095, blue: 0.105))
        .tint(accent)
        .alert(editor.exportWarning == nil ? "Trimsmith" : "Video saved — check playback", isPresented: Binding(
            get: { editor.error != nil || editor.exportWarning != nil },
            set: { if !$0 { editor.error = nil; editor.exportWarning = nil } }
        )) {
            if editor.exportWarning != nil {
                Button("Show in Finder") { editor.revealExport(); editor.exportWarning = nil }
            }
            Button("OK", role: .cancel) { editor.error = nil; editor.exportWarning = nil }
        } message: { Text(editor.exportWarning ?? editor.error ?? "") }
        .sheet(isPresented: Binding(get: { editor.loading || editor.scanning }, set: { _ in })) {
            if let plan = editor.pendingImport {
                ImportReviewView(plan: plan, confirm: { editor.confirmImport($0) }, cancel: { editor.cancelLoading() })
                    .id(plan.id)
            } else {
                ImportProgressView(editor: editor)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !editor.exporting, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in editor.open(url) } }
            }
            return true
        }
    }
    /// Lists derived selections and individual markers, with mode and export actions.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("SELECTIONS").font(.caption.weight(.semibold)).tracking(1.2)
                Spacer()
                Text("\(editor.clips.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            if editor.clips.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Set an IN point to begin").font(.headline)
                    Text("I starts a selection. The next O ends it; without an OUT point it runs to the end of the video.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.vertical, 20)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(editor.clips.enumerated()), id: \.element.id) { index, clip in
                            let effective = editor.effective(clip)
                            Button { editor.selectSegment(clip.id) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Selection \(index + 1)").font(.callout.weight(.medium))
                                    Text("\(timestamp(clip.start)) → \(timestamp(clip.end))")
                                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                    if editor.mode == .lossless {
                                        Text("Export: \(timestamp(effective.start)) → \(timestamp(effective.end))")
                                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(accent)
                                    }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(accent.opacity(editor.selectedSegmentID == clip.id ? 0.16 : 0.04), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(editor.selectedSegmentID == clip.id ? 0.6 : 0)))
                            }.buttonStyle(.plain).disabled(!editor.ready || editor.exporting)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("CUT POINTS").font(.caption.weight(.semibold)).tracking(1.2)
                Spacer()
                Button(action: editor.deleteSelectedCut) { Image(systemName: "trash") }
                    .buttonStyle(.plain).disabled(!editor.canDeleteCut).help("Delete selected cut point · Backspace")
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(editor.sortedCutPoints) { point in
                        Button { editor.selectCut(point.id) } label: {
                            HStack(spacing: 8) {
                                Text(point.kind.rawValue).font(.caption.weight(.semibold)).frame(width: 30)
                                Text(timestamp(point.time)).font(.system(size: 11, design: .monospaced))
                                Spacer()
                                if !editor.isActive(point) { Text("Unused").font(.caption2).foregroundStyle(.secondary) }
                            }.padding(7).frame(maxWidth: .infinity)
                                .background(accent.opacity(editor.selectedCutID == point.id ? 0.2 : 0.03), in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).disabled(!editor.ready || editor.exporting)
                    }
                }
            }.frame(maxHeight: 140)
            Divider()
            Text("EXPORT").font(.caption.weight(.semibold)).tracking(1.2)
            Picker("Export mode", selection: $editor.mode) {
                ForEach(ExportMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }.pickerStyle(.segmented).labelsHidden().disabled(editor.exporting)
            Text(editor.mode == .lossless
                 ? "Copies the working copy’s video and audio. Ranges expand to surrounding keyframes; audio joins may have packet-level gaps."
                 : "Cuts at the marked frames. Choose codec, quality, and tune in the save dialog. HDR re-encoding is not supported yet.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Keeps every audio track automatically. The original file stays unchanged.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Output duration").foregroundStyle(.secondary)
                Spacer()
                Text(timestamp(editor.outputDuration)).monospacedDigit()
            }.font(.caption)
            Button(action: editor.exportPanel) {
                HStack { Spacer(); Label("Export Video…", systemImage: "square.and.arrow.up"); Spacer() }.padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black).disabled(!editor.canExport)
            Text("⌘E to export").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        }.padding(20)
    }
    /// Creates a consistently styled, accessible transport button with its disabled state and
    /// action.
    private func control(_ icon: String, _ help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 22, height: 24) }
            .buttonStyle(.plain).help(help).disabled(disabled)
    }

}

/// Modal preparation/indexing progress that blocks editing until the replacement source is ready.
struct ImportProgressView: View {
    @ObservedObject var editor: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Opening video", systemImage: "film.stack").font(.title2.weight(.semibold))
            Text(editor.importingName ?? "").font(.headline).lineLimit(2)
            Text(editor.status).foregroundStyle(.secondary)
            if editor.scanning {
                ProgressView(value: editor.indexingProgress)
                Text("\(Int(editor.indexingProgress * 100))% indexed").monospacedDigit()
            } else if editor.importing, let value = editor.importProgress {
                ProgressView(value: value)
                Text("\(Int(value * 100))% prepared").monospacedDigit()
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text("Preparing a local working copy. Your original stays unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel", action: { editor.cancelLoading() }).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 480).preferredColorScheme(.dark).interactiveDismissDisabled()
    }
}

/// Explains proposed conversions/omissions and collects the optional deinterlacing choice.
struct ImportReviewView: View {
    let plan: ImportPlan
    let confirm: (ImportPlan) -> Void
    let cancel: () -> Void
    @State private var deinterlace = false
    /// Returns a copy of the inspected plan with the sheet’s current deinterlacing choice.
    private var selection: ImportPlan {
        var chosen = plan
        chosen.deinterlace = deinterlace
        return chosen
    }
    /// Uses outcome colors for stream reports while leaving explanatory notes secondary grey.
    private func reportColor(_ outcome: ImportReport.Outcome) -> Color {
        switch outcome {
        case .copied: return .green
        case .converted: return .yellow
        case .omitted: return .red
        case .explanation: return .secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Review import", systemImage: "arrow.triangle.2.circlepath").font(.title2.weight(.semibold))
            Text(plan.original.lastPathComponent).font(.headline).lineLimit(2)
            Text("Trimsmith will create a local MOV working copy for playback, editing, and export. These changes affect the working copy and exports:")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(selection.reports.enumerated()), id: \.offset) { _, report in
                        Text(report.text).foregroundStyle(reportColor(report.outcome)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(14)
            }.frame(maxHeight: 280).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            if plan.isInterlaced {
                Toggle("Deinterlace for Apple playback (re-encodes video)", isOn: $deinterlace)
                    .disabled(plan.isHDR)
                Text(plan.isHDR
                     ? "HDR deinterlacing is not supported yet. The video can be copied with its interlacing preserved."
                     : "Optional and off by default. Copying preserves video quality; deinterlacing may improve Apple playback compatibility.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Preparation reads the entire source and uses local disk space. The working copy is removed when this editing session ends.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(selection.encodesVideo || selection.convertAudio ? "Convert and Import" : "Create Working Copy") { confirm(selection) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 540).preferredColorScheme(.dark).interactiveDismissDisabled()
    }
}

/// Displays selectable ranges and cut markers over seekable backgrounds, plus keyframe ticks and the
/// playhead.
struct TimelineView: View {
    @ObservedObject var editor: EditorModel
    let accent: Color
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(editor.duration, 0.001)
            // Keep seek gestures on background siblings of the buttons: an
            // ancestor gesture steals marker/segment clicks and seeks on selection.
            // Real stacked rows also keep drawing and hit-test coordinates aligned.
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.04))
                        .contentShape(Rectangle())
                        .gesture(scrubGesture(width: width))
                        .simultaneousGesture(seekTap(width: width))
                    ForEach(editor.clips) { clip in
                        Button { editor.selectSegment(clip.id) } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(accent.opacity(editor.selectedSegmentID == clip.id ? 0.65 : 0.3))
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(accent.opacity(0.8)))
                                .frame(width: max(2, clip.duration / duration * width), height: 18)
                        }.buttonStyle(.plain)
                            .offset(x: clip.start / duration * width, y: 4)
                            .accessibilityLabel("Selection from " + timestamp(clip.start) + " to " + timestamp(clip.end))
                            .disabled(editor.exporting)
                    }
                    ForEach(editor.sortedCutPoints) { point in
                        cutButton(point)
                            .offset(x: max(0, min(width - 20, point.time / duration * width - 10)), y: 27)
                            .zIndex(editor.selectedCutID == point.id ? 1 : 0)
                            .accessibilityLabel(point.kind.rawValue + " cut at " + timestamp(point.time))
                            .help("Select " + point.kind.rawValue + " at " + timestamp(point.time) + " · Backspace to delete")
                            .disabled(editor.exporting)
                    }
                }.frame(width: width, height: 52)
                // This is a real layout row, not an offset drawing with a gesture
                // attached outside it. Both clicks and drags use this row's coordinates.
                ZStack {
                    Rectangle().fill(.white.opacity(0.08))
                    Canvas { context, size in
                        var lastX = -2.0
                        for frame in editor.keyframes {
                            let x = frame / duration * size.width
                            if x - lastX < 2 { continue }; lastX = x
                            var path = Path(); path.move(to: CGPoint(x: x, y: 4)); path.addLine(to: CGPoint(x: x, y: 24))
                            context.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: 1)
                        }
                    }.allowsHitTesting(false)
                }.frame(width: width, height: 28)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture(width: width))
                    .simultaneousGesture(seekTap(width: width))
                    .accessibilityLabel("Video timeline").accessibilityValue(timestamp(editor.position))
                    .accessibilityAdjustableAction { direction in editor.seek(editor.position + (direction == .increment ? 1 : -1)) }
            }.onDisappear { editor.endScrubbing() }.overlay(alignment: .topLeading) {
                Rectangle().fill(.white).frame(width: 2, height: 80)
                    .offset(x: min(width - 2, editor.position / duration * width)).allowsHitTesting(false)
            }
        }
    }
    /// Converts a timeline x-coordinate to a clamped playhead position through the editor.
    private func scrub(_ x: Double, width: Double) {
        editor.scrub(to: x / max(1, width) * editor.duration)
    }
    /// Seeks throughout a drag and commits the whole gesture as one undoable playhead move.
    private func scrubGesture(width: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in scrub(value.location.x, width: width) }
            .onEnded { value in
                scrub(value.location.x, width: width)
                editor.endScrubbing()
            }
    }
    /// Handles stationary clicks on the same seek surface; duplicate drag-end delivery is a
    /// history no-op.
    private func seekTap(width: Double) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            scrub(value.location.x, width: width)
            editor.endScrubbing()
        }
    }
    /// Creates an IN/OUT chevron with selected and unused styling; clicking selects and seeks its
    /// marker.
    private func cutButton(_ point: CutPoint) -> some View {
        let selected = editor.selectedCutID == point.id
        let active = editor.isActive(point)
        return Button { editor.selectCut(point.id) } label: {
            Image(systemName: point.kind == .start ? "chevron.right" : "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 20, height: 22)
                .foregroundStyle(selected ? Color.black : accent.opacity(active ? 1 : 0.45))
                .background(selected ? accent : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

}

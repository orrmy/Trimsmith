import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

/// Main-actor editing session: playback, cut history, previews, import lifecycle, and export
/// presentation.
@MainActor
final class EditorModel: ObservableObject {
    let player = AVPlayer()
    let editUndoManager = UndoManager()
    private var recordingEdits = true
    @Published private(set) var undoRevision = 0
    var canUndo: Bool { ready && !exporting && editUndoManager.canUndo }
    var canRedo: Bool { ready && !exporting && editUndoManager.canRedo }
    /// Undoes one permitted edit and updates the menu/UI revision and status.
    func undo() {
        guard canUndo else { return }
        let action = editUndoManager.undoActionName
        editUndoManager.undo(); undoRevision += 1; status = "Undid " + action
    }
    /// Reapplies one undone edit and updates the menu/UI revision and status.
    func redo() {
        guard canRedo else { return }
        let action = editUndoManager.redoActionName
        editUndoManager.redo(); undoRevision += 1; status = "Redid " + action
    }
    /// Registers one named edit, preserving the original action name while undo/redo registers
    /// its inverse.
    private func recordUndo(_ name: String, restore: @escaping (EditorModel) -> Void) {
        guard recordingEdits, ready, !exporting else { return }
        let actionName = editUndoManager.isUndoing ? editUndoManager.undoActionName
            : editUndoManager.isRedoing ? editUndoManager.redoActionName : name
        let group = !editUndoManager.isUndoing && !editUndoManager.isRedoing
        // Explicit groups give each user action its own undo step. Opening a
        // new group during undo/redo would break UndoManager's inverse recording.
        if group { editUndoManager.beginUndoGrouping() }
        editUndoManager.registerUndo(withTarget: self, handler: restore)
        editUndoManager.setActionName(actionName)
        if group { editUndoManager.endUndoGrouping() }
        undoRevision += 1
    }
    @Published var source: URL?
    @Published var originalSource: URL?
    @Published var pendingImport: ImportPlan?
    @Published var importing = false
    @Published var importProgress: Double?
    @Published var importDescription = ""
    @Published var importingName: String?
    @Published var duration = 0.0
    @Published var position = 0.0
    @Published private(set) var cutPoints: [CutPoint] = [] { didSet {
        // Cache derived ranges and active IDs here rather than recomputing them
        // for every timeline marker on each 60 Hz playhead update.
        selections = CutTimeline.selections(cutPoints, duration: duration)
        activeCutIDs = Set(selections.flatMap { [$0.start.id] + ($0.end.map { [$0.id] } ?? []) })
    } }
    @Published private(set) var selections: [CutSelection] = []
    private var activeCutIDs: Set<UUID> = []
    @Published private(set) var selectedCutID: UUID?
    @Published private(set) var selectedSegmentID: UUID?
    var clips: [Clip] { selections.map(\.clip) }
    var selectionCountLabel: String { "\(clips.count) " + (clips.count == 1 ? "selection" : "selections") }
    var sortedCutPoints: [CutPoint] { CutTimeline.sorted(cutPoints) }
    var selectedCut: CutPoint? { cutPoints.first { $0.id == selectedCutID } }
    var selectedSelection: CutSelection? { selections.first { $0.id == selectedSegmentID } }
    var canDeleteCut: Bool { ready && !exporting && selectedCut != nil }
    /// Indicates whether a marker currently forms a selection boundary rather than remaining
    /// unused.
    func isActive(_ point: CutPoint) -> Bool {
        activeCutIDs.contains(point.id)
    }
    /// An undo snapshot of all markers and the selected cut/segment identities.
    private struct CutState {
        let points: [CutPoint]
        let cut: UUID?
        let segment: UUID?
    }
    private var cutState: CutState { CutState(points: cutPoints, cut: selectedCutID, segment: selectedSegmentID) }
    /// Restores a marker snapshot and registers the current state as its inverse for redo.
    private func restoreCuts(_ state: CutState, action: String) {
        let previous = cutState
        recordUndo(action) { $0.restoreCuts(previous, action: action) }
        cutPoints = state.points
        selectedCutID = state.cut; selectedSegmentID = state.segment
        schedulePreviews()
    }
    /// Adds an undoable, clamped marker or selects an existing same-kind marker at that time.
    func addCut(_ kind: CutKind, at seconds: Double) {
        guard ready, !exporting, seconds.isFinite else { return }
        let time = min(duration, max(0, seconds))
        guard kind != .start || time < duration else { return }
        if let existing = cutPoints.first(where: { $0.kind == kind && abs($0.time - time) < 0.000001 }) {
            selectCut(existing.id); return
        }
        let previous = cutState
        recordUndo("Add " + kind.rawValue + " Point") { $0.restoreCuts(previous, action: "Add " + kind.rawValue + " Point") }
        let point = CutPoint(kind: kind, time: time)
        cutPoints.append(point)
        selectCut(point.id, seekToPoint: false)
        status = selectionCountLabel + " · cuts update automatically"
    }
    /// Selects a marker and its associated selection, optionally pausing and seeking to the
    /// marker.
    func selectCut(_ id: UUID, seekToPoint: Bool = true) {
        guard ready, !exporting, let point = cutPoints.first(where: { $0.id == id }) else { return }
        selectedCutID = id
        selectedSegmentID = selections.first { $0.start.id == id || $0.end?.id == id }?.id
        if seekToPoint { player.pause(); playing = false; seek(point.time) }
        schedulePreviews()
    }
    /// Navigates markers without wrapping, using identity to make coincident IN/OUT points
    /// reachable.
    func selectAdjacentCut(_ direction: Int) {
        guard ready, !exporting, direction != 0 else { return }
        let points = sortedCutPoints
        let target: CutPoint?
        if let id = selectedCutID, let index = points.firstIndex(where: { $0.id == id }),
           abs(position - points[index].time) < 0.00001 {
            // Step by identity so coincident IN/OUT points are both reachable.
            let next = index + (direction < 0 ? -1 : 1)
            target = points.indices.contains(next) ? points[next] : nil
        } else {
            // After scrubbing or selecting a segment, navigate from the playhead.
            target = direction < 0 ? points.last { $0.time < position - 0.00001 }
                : points.first { $0.time > position + 0.00001 }
        }
        if let target { selectCut(target.id) }
    }
    /// Selects a range for boundary previews without moving the playhead or interrupting
    /// playback.
    func selectSegment(_ id: UUID) {
        guard ready, !exporting, selections.contains(where: { $0.id == id }) else { return }
        selectedSegmentID = id
        selectedCutID = nil
        schedulePreviews()
    }
    /// Deletes the selected marker as one undoable edit and refreshes derived
    /// selections/previews.
    func deleteSelectedCut() {
        guard canDeleteCut, let id = selectedCutID else { return }
        let previous = cutState
        recordUndo("Delete Cut Point") { $0.restoreCuts(previous, action: "Delete Cut Point") }
        cutPoints.removeAll { $0.id == id }
        selectedCutID = nil
        if !selections.contains(where: { $0.id == selectedSegmentID }) { selectedSegmentID = nil }
        schedulePreviews()
        status = "Cut point deleted · " + selectionCountLabel
    }
    /// Returns the effective export boundary for a selection, or the raw time for an unused
    /// marker.
    func previewTime(for kind: CutKind) -> Double? {
        if let selection = selectedSelection {
            let bounds = effective(selection.clip)
            return kind == .start ? bounds.start : bounds.end
        }
        if let point = selectedCut, point.kind == kind { return point.time }
        return nil
    }
    /// Labels a boundary with its marked time and, when different, its snapped export time.
    func previewTitle(for kind: CutKind) -> String {
        if let selection = selectedSelection {
            let raw = kind == .start ? selection.start.time : selection.clip.end
            let title = kind == .end && selection.end == nil ? "END OF VIDEO" : kind.rawValue
            guard let time = previewTime(for: kind) else { return title }
            return title + " · " + timestamp(raw) + (abs(raw - time) > 0.00001 ? "\nExport: " + timestamp(time) : "")
        }
        if let point = selectedCut, point.kind == kind { return "UNUSED " + kind.rawValue + " · " + timestamp(point.time) }
        return kind.rawValue
    }
    /// Tests the appropriate side of a boundary against all exported ranges, including adjacent
    /// selections.
    func previewIncluded(_ slot: CutPreviewSlot) -> Bool {
        guard let time = previewTime(for: slot.kind) else { return false }
        // Inspect membership on either side, not just marker kind: an unused
        // marker or adjoining selections can leave both frames included.
        let sample = time + (slot.before ? -0.000001 : 0.000001)
        return effectiveClips.contains { $0.start <= sample && $0.end > sample }
    }
    @Published var keyframes: [Double] = []
    @Published var mode: ExportMode = .lossless { didSet {
        if oldValue != mode { recordUndo("Change Export Mode") { $0.mode = oldValue } }; schedulePreviews()
    } }
    static let playbackRates: [Float] = [0.25, 0.5, 1, 2, 4]
    static let playbackRateLabels = ["0.25×", "0.5×", "1×", "2×", "4×"]
    @Published private(set) var speedIndex = 2
    var playbackRate: Float { Self.playbackRates[speedIndex] }
    var playbackRateLabel: String { Self.playbackRateLabels[speedIndex] }
    @Published var cutPreviews: [CutPreviewSlot: BoundaryPreview] = [:]
    private var previewTask: Task<Void, Never>?
    private var previewID = UUID()
    private var previewCache: [BoundaryPreviewRequest: NSImage] = [:]
    private var previewCacheOrder: [BoundaryPreviewRequest] = []
    @Published var loading = false
    @Published var scanning = false
    @Published var exporting = false
    @Published var playing = false
    @Published var indexingProgress = 0.0
    @Published var progress = 0.0
    @Published var status = "Open a video to begin"
    @Published var error: String?
    @Published var exportWarning: String?
    @Published var exportNeedsReview = false
    @Published var lastExport: URL?
    @Published var canStepBack = false
    @Published var canStepForward = false
    private var itemObservation: NSKeyValueObservation?
    private var observer: Any?
    private var loadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var exportSettingsByMode: [ExportMode: ExportSettings] = [:]
    private var tools: Toolchain?
    private var mediaIndex: MediaIndex?
    private var workingCopy: WorkingCopy?
    private var activeAsset: AVURLAsset?
    private var loadID = UUID()
    var displayName: String {
        if let importingName { return importingName }
        if let originalSource { return originalSource.lastPathComponent }
        return "A small, focused video cutter"
    }
    var ready: Bool { source != nil && duration > 0 && !loading && !scanning }
    var effectiveClips: [Clip] { clips.map { effective($0) } }
    var outputDuration: Double { effectiveClips.reduce(0) { $0 + $1.duration } }
    var canExport: Bool { ready && !exporting && !clips.isEmpty && (mode == .exact || (!scanning && !keyframes.isEmpty)) }

    /// Locates tools (or accepts injected ones for tests) and observes playback without recording
    /// playback ticks as edits.
    init(tools suppliedTools: Toolchain? = nil) {
        editUndoManager.groupsByEvent = false
        do { tools = try suppliedTools ?? Toolchain.locate() } catch { self.error = error.localizedDescription }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 60, preferredTimescale: 60000), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.ready else { return }
                if time.seconds.isFinite { self.position = max(0, time.seconds) }
                self.playing = self.player.rate != 0
                self.canStepBack = self.player.currentItem?.canStepBackward ?? false
                self.canStepForward = self.player.currentItem?.canStepForward ?? false
            }
        }
    }
    /// Presents a single-file picker; ffprobe, rather than the extension filter, decides
    /// compatibility.
    func openPanel() {
        guard !exporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    /// Starts an isolated import request, preserving the existing edit until its replacement is
    /// fully prepared.
    func open(_ url: URL) {
        guard !exporting else {
            error = "Wait for the current export to finish or cancel it before opening another video."
            return
        }
        guard url.isFileURL else { error = "Open a video file from Finder or a mounted volume."; return }
        cancelLoading()
        let request = UUID()
        loadID = request
        cancelPreviews()
        error = nil; loading = true; indexingProgress = 0; importingName = url.lastPathComponent
        status = "Inspecting video and audio tracks…"
        loadTask = Task {
            do {
                guard let tools else { throw MediaError(message: "FFmpeg is missing. Install FFmpeg, then reopen Trimsmith.") }
                let plan = try await ImportEngine.inspect(url, tools: tools)
                try Task.checkCancellation()
                guard loadID == request else { return }
                if plan.needsConfirmation {
                    pendingImport = plan; status = "Review import changes"
                } else { await prepare(plan, request: request, tools: tools) }
            } catch { finishLoadError(error, request: request) }
        }
    }
    /// Continues only the currently reviewed import, including its chosen deinterlacing option.
    func confirmImport(_ selection: ImportPlan? = nil) {
        guard let pending = pendingImport, let tools, !exporting else { return }
        guard selection == nil || selection?.id == pending.id else { return }
        let plan = selection ?? pending
        let request = loadID
        pendingImport = nil
        loadTask = Task { await prepare(plan, request: request, tools: tools) }
    }
    /// Creates, checks, and indexes a replacement, then commits it and resets history only after
    /// success.
    private func prepare(_ plan: ImportPlan, request: UUID, tools: Toolchain) async {
        do {
            loading = true; importing = true; importProgress = plan.duration > 0 ? 0 : nil
            status = plan.encodesVideo || plan.convertAudio ? "Converting local working copy…" : "Creating local working copy…"
            let copy = try await ImportEngine.prepare(plan, tools: tools) { value in
                Task { @MainActor [weak self] in
                    guard let self, self.loadID == request, self.importing else { return }
                    self.importProgress = value
                }
            }
            try Task.checkCancellation()
            guard loadID == request else { return }
            importing = false; status = "Checking local working copy…"
            let asset = AVURLAsset(url: copy.url)
            activeAsset = asset
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard playable, !tracks.isEmpty else {
                if !plan.convertVideo {
                    pendingImport = try plan.convertingVideo(reason: "Apple could not play the copied video. Converting the video may improve compatibility.")
                    activeAsset = nil; status = "Review video conversion"; return
                }
                throw MediaError(message: "Apple could not play the converted working copy. Try converting this recording externally. Your original is unchanged.")
            }
            let length = try await asset.load(.duration).seconds
            guard length.isFinite && length > 0 else { throw MediaError(message: "The working copy has no usable video duration. Your original is unchanged.") }
            try Task.checkCancellation()
            guard loadID == request else { return }
            loading = false; scanning = true; status = "Indexing local working copy…"
            let origin = try await MediaEngine.sourceOrigin(source: copy.url, tools: tools)
            let indexed = try await MediaEngine.index(source: copy.url, tools: tools, duration: length, origin: origin) { value in
                Task { @MainActor [weak self] in
                    guard let self, self.loadID == request, self.scanning else { return }
                    self.indexingProgress = value
                }
            }
            try Task.checkCancellation()
            guard loadID == request else { return }
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .spectral
            player.replaceCurrentItem(with: item)
            player.defaultRate = playbackRate
            itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.player.currentItem === item else { return }
                    self.canStepBack = item.canStepBackward
                    self.canStepForward = item.canStepForward
                    if item.status == .failed { self.error = item.error?.localizedDescription ?? "macOS could not decode this video." }
                }
            }
            // Commit only once the replacement is prepared. A cancelled/failed
            // import leaves the previous working copy and edit available.
            recordingEdits = false
            editUndoManager.removeAllActions(); undoRevision += 1
            workingCopy = copy; originalSource = plan.original; source = copy.url
            duration = length; position = 0; cutPoints = []; selectedCutID = nil; selectedSegmentID = nil
            mediaIndex = indexed; keyframes = indexed.keyframes.filter { $0 <= length }
            lastExport = nil; exportWarning = nil; exportNeedsReview = false
            importDescription = "Local working copy · " + (plan.encodesVideo ? (plan.deinterlace ? "video deinterlaced to H.264" : "video converted to H.264") : "video copied losslessly") +
                (plan.audioTracks.isEmpty ? "" : " · \(plan.audioTracks.count) " + (plan.audioTracks.count == 1 ? "audio track" : "audio tracks") + (plan.convertAudio ? " (some converted to AAC)" : " copied"))
            indexingProgress = 1; scanning = false; activeAsset = nil; importingName = nil
            status = keyframes.isEmpty ? "No keyframes found · use Frame-exact export" : "\(keyframes.count) keyframes · local copy ready"
            previewCache = [:]; previewCacheOrder = []
            recordingEdits = true
            schedulePreviews()
        } catch { finishLoadError(error, request: request) }
    }
    /// Ends the matching failed/cancelled load and restores previews for the previous session.
    private func finishLoadError(_ failure: Error, request: UUID) {
        guard loadID == request else { return }
        loading = false; scanning = false; importing = false; importingName = nil; pendingImport = nil; activeAsset = nil
        if failure is CancellationError { status = "Import cancelled" }
        else { error = failure.localizedDescription; status = "Import failed · original unchanged" }
        schedulePreviews()
    }
    /// Invalidates pending callbacks and stops import/playback; optionally releases the whole
    /// editing session.
    func cancelLoading(clearEditor: Bool = false) {
        endScrubbing()
        loadID = UUID()
        loadTask?.cancel(); loadTask = nil
        activeAsset?.cancelLoading(); activeAsset = nil
        pendingImport = nil; importing = false; importProgress = nil; importingName = nil
        player.pause(); playing = false
        player.cancelPendingPrerolls(); player.currentItem?.cancelPendingSeeks()
        scanning = false; loading = false; indexingProgress = 0; status = "Import cancelled"
        if clearEditor {
            editUndoManager.removeAllActions(); undoRevision += 1
            cancelPreviews()
            previewCache = [:]; previewCacheOrder = []
            player.replaceCurrentItem(with: nil); itemObservation = nil
            source = nil; originalSource = nil; workingCopy = nil; mediaIndex = nil
            cutPoints = []; selectedCutID = nil; selectedSegmentID = nil
            keyframes = []; duration = 0; position = 0
            canStepBack = false; canStepForward = false; importDescription = ""
        } else { schedulePreviews() }
    }
    private var scrubStart: (source: URL?, time: Double)?
    /// Restores a history position while paused and registers the inverse seek for redo.
    private func restorePlayhead(_ time: Double) {
        player.pause(); playing = false
        seek(time)
    }
    /// Moves during a drag without recording each intermediate position; remembers the gesture’s
    /// starting session.
    func scrub(to seconds: Double) {
        guard ready, !exporting else { return }
        if scrubStart == nil { scrubStart = (source, position) }
        player.pause(); playing = false
        seek(seconds, recordHistory: false)
    }
    /// Records one undo action for the completed drag, ignoring no-ops and gestures from a
    /// replaced source.
    func endScrubbing() {
        guard let start = scrubStart else { return }
        scrubStart = nil
        guard ready, source == start.source, abs(position - start.time) > 0.000001 else { return }
        recordUndo("Move Playhead") { $0.restorePlayhead(start.time) }
    }
    /// Clamps and accurately seeks the player, optionally recording the previous position for
    /// undo.
    func seek(_ seconds: Double, recordHistory: Bool = true) {
        guard ready, seconds.isFinite else { return }
        let time = min(duration, max(0, seconds))
        if recordHistory, abs(position - time) > 0.000001 {
            let previous = position
            recordUndo("Move Playhead") { $0.restorePlayhead(previous) }
        }
        position = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    /// Pauses or resumes at the selected speed, restarting from the beginning after reaching EOF.
    func togglePlayback() {
        guard ready else { return }
        if player.rate == 0 {
            if position >= duration - 0.001 { seek(0, recordHistory: false) }
            player.defaultRate = playbackRate
            player.play()
        } else { player.pause() }
        playing = player.rate != 0
    }
    /// Selects a supported speed and updates both future resumes and current playback without
    /// starting a paused player.
    func selectSpeed(_ index: Int) {
        guard ready, !exporting else { return }
        speedIndex = min(Self.playbackRates.count - 1, max(0, index))
        // Native AVPlayerView/media-key restart paths call play(), which restores
        // defaultRate rather than the last transient value of rate.
        player.defaultRate = playbackRate
        // Selecting a speed while paused must not start playback.
        if player.rate != 0 { player.rate = playbackRate }
    }
    /// Steps through the fixed playback-speed choices, clamping at either end.
    func changeSpeed(_ delta: Int) { selectSpeed(speedIndex + delta) }

    /// Cancels thumbnail decoding and invalidates results from older requests.
    private func cancelPreviews() {
        previewID = UUID(); previewTask?.cancel(); previewTask = nil
        cutPreviews = [:]
    }
    /// Debounces boundary changes, reuses a bounded image cache, and ignores cancelled or
    /// obsolete results.
    func schedulePreviews() {
        cancelPreviews()
        guard ready, let source, let tools,
              mode == .exact || !keyframes.isEmpty else { return }
        var requests: [(CutPreviewSlot, BoundaryPreviewRequest)] = []
        for slot in CutPreviewSlot.allCases {
            guard let time = previewTime(for: slot.kind) else { continue }
            // No source frame exists on the outer side of the file endpoints.
            guard slot.before ? time > 0 : time < duration else {
                cutPreviews[slot] = BoundaryPreview(boundary: time)
                continue
            }
            let request = BoundaryPreviewRequest(source: source, side: slot.before ? .last : .first,
                                                 boundary: time, lastPacketTime: mediaIndex?.lastPacket(before: time))
            requests.append((slot, request))
            cutPreviews[slot] = BoundaryPreview(image: previewCache[request], boundary: time, loading: previewCache[request] == nil)
        }
        guard !requests.isEmpty else { return }
        let requestID = previewID
        previewTask = Task { [weak self] in
            do {
                // Coalesce rapid frame stepping/mark changes and export-mode toggles.
                try await Task.sleep(nanoseconds: 180_000_000)
                for (slot, request) in requests {
                    try Task.checkCancellation()
                    guard let self, self.previewID == requestID else { return }
                    if let image = self.previewCache[request] {
                        self.cutPreviews[slot] = BoundaryPreview(image: image, boundary: request.boundary)
                        continue
                    }
                    do {
                        let data = try await BoundaryPreviewEngine.image(request, tools: tools)
                        try Task.checkCancellation()
                        guard self.previewID == requestID else { return }
                        guard let image = NSImage(data: data) else { throw MediaError(message: "Could not read thumbnail") }
                        self.previewCache[request] = image; self.previewCacheOrder.append(request)
                        if self.previewCacheOrder.count > 32 {
                            self.previewCache.removeValue(forKey: self.previewCacheOrder.removeFirst())
                        }
                        let preview = BoundaryPreview(image: image, boundary: request.boundary)
                        self.cutPreviews[slot] = preview
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        guard self.previewID == requestID else { return }
                        let preview = BoundaryPreview(boundary: request.boundary, unavailable: true)
                        self.cutPreviews[slot] = preview
                    }
                }
            } catch { } // Cancellation is expected when markers change.
        }
    }
    /// Requests native decoded-frame stepping while paused and records the previous playhead for
    /// undo.
    func step(_ count: Int) {
        guard ready, !exporting, count != 0, let item = player.currentItem,
              count < 0 ? item.canStepBackward : item.canStepForward else { return }
        let previous = position
        recordUndo("Step Frame") { $0.restorePlayhead(previous) }
        player.pause(); playing = false
        item.step(byCount: count)
    }
    /// Pauses and seeks to the strictly preceding/following indexed keyframe as an undoable move.
    func jumpKeyframe(_ direction: Int) {
        guard ready else { return }
        player.pause(); playing = false
        let value = direction < 0 ? keyframes.last(where: { $0 < position - 0.001 }) : keyframes.first(where: { $0 > position + 0.001 })
        if let value { seek(value) }
    }
    /// Adds an IN marker at the player’s current position.
    func setIn() { addCut(.start, at: currentTime) }
    /// Adds an OUT marker at the player’s current position.
    func setOut() { addCut(.end, at: currentTime) }
    /// Reads the player directly so a marker is not delayed by the periodic UI position observer.
    private var currentTime: Double {
        let actual = player.currentTime().seconds
        return min(duration, max(0, actual.isFinite ? actual : position))
    }
    /// Resolves a selection to the export boundaries for the current mode and source index.
    func effective(_ clip: Clip) -> Clip { MediaEngine.effective(clip, mode: mode, keyframes: keyframes, duration: duration) }
    /// Snapshots boundaries, collects validated settings, protects source paths, and starts the
    /// cancellable export.
    func exportPanel() {
        guard canExport, let source else { return }
        do {
            let snapshot = effectiveClips
            try MediaEngine.validate(snapshot)
            let tools = try Toolchain.locate()
            let panel = NSSavePanel()
            let initial = exportSettingsByMode[mode] ?? .defaults(for: mode)
            panel.allowsOtherFileTypes = false
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = (originalSource ?? source).deletingPathExtension().lastPathComponent + "-cut." + (mode == .exact && initial.codec != .prores ? "mp4" : "mov")
            let accessory = ExportAccessory(panel: panel, mode: mode, initial: initial)
            panel.accessoryView = accessory.view
            panel.canCreateDirectories = true
            // AppKit retains the view but control targets are weak. Keep the
            // controller alive throughout the modal loop so menu actions work.
            let response = withExtendedLifetime(accessory) { panel.runModal() }
            guard response == .OK, let destination = panel.url else { return }
            let settings = try accessory.chosenSettings()
            try settings.validate(mode: mode, destination: destination)
            exportSettingsByMode[mode] = settings
            guard ![source, originalSource].compactMap({ $0 }).contains(where: {
                $0.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath()
            }) else {
                throw MediaError(message: "Choose a new filename to keep your source video safe.")
            }
            player.pause(); playing = false; exporting = true; progress = -1; lastExport = nil
            exportWarning = nil; exportNeedsReview = false; error = nil
            let expectedVideoFrames = mediaIndex?.frameCount(in: snapshot)
            let selectedMode = mode
            exportTask = Task {
                do {
                    let result = try await MediaEngine.export(source: source, clips: snapshot, mode: selectedMode, destination: destination, tools: tools, expectedVideoFrames: expectedVideoFrames, settings: settings) { value, message in
                        await MainActor.run { self.progress = value; self.status = message }
                    }
                    lastExport = destination
                    exportNeedsReview = result.needsReview
                    exportWarning = result.warningMessage
                    status = "Saved \(destination.lastPathComponent)" + (result.needsReview ? " · check playback" : "")
                } catch is CancellationError { status = "Export cancelled" }
                catch { self.error = error.localizedDescription; status = "Export failed" }
                exporting = false
            }
        } catch { self.error = error.localizedDescription }
    }
    /// Cancels the export task; its engine removes temporary and unpublished output.
    func cancelExport() { exportTask?.cancel() }
    /// Cancels previews/import and waits for export cleanup without waiting on stalled asset
    /// metadata requests.
    func shutdown() async {
        // AVFoundation metadata requests on an unreachable network volume may
        // not finish promptly. Cancel them, but do not make Quit wait for them.
        cancelPreviews()
        exportTask?.cancel()
        await exportTask?.value
        cancelLoading(clearEditor: true)
    }
    /// Selects the last successfully saved file in Finder.
    func revealExport() { if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) } }
}


import SwiftUI

/// Displays the discrete playback-speed slider, selected rate, and shortcut hints.
struct PlaybackSpeedControl: View {
    @ObservedObject var editor: EditorModel
    var body: some View {
        HStack(spacing: 14) {
            Text("Speed").font(.caption).foregroundStyle(.secondary)
            NativeSpeedDial(index: editor.speedIndex, enabled: editor.ready && !editor.exporting, select: editor.selectSpeed)
                .frame(width: 200, height: 40)
            Text(editor.playbackRateLabel).font(.callout.weight(.medium)).monospacedDigit().frame(width: 48)
            Spacer(minLength: 0)
            Text("1–5 select speed · ↑ faster · ↓ slower").font(.caption2).foregroundStyle(.secondary)
        }.disabled(!editor.ready || editor.exporting)
    }
}

/// Bridges the AppKit tick slider and its aligned labels into SwiftUI.
struct NativeSpeedDial: NSViewRepresentable {
    let index: Int
    let enabled: Bool
    let select: (Int) -> Void
    /// Creates the reusable native speed slider and labels.
    func makeNSView(context: Context) -> SpeedDialView { SpeedDialView() }
    /// Synchronizes selection, enabled state, label emphasis, and accessibility with the editor.
    func updateNSView(_ view: SpeedDialView, context: Context) {
        view.select = select
        view.slider.integerValue = index
        view.slider.isEnabled = enabled
        view.slider.setAccessibilityValueDescription(EditorModel.playbackRateLabels[index])
        for (ordinal, label) in view.labels.enumerated() {
            label.textColor = ordinal == index ? .labelColor : .secondaryLabelColor
        }
        view.needsLayout = true
    }
}

/// Owns a five-position native slider and independently positioned, centered rate labels.
final class SpeedDialView: NSView {
    let slider = NSSlider(value: 2, minValue: 0, maxValue: 4, target: nil, action: nil)
    let labels = EditorModel.playbackRateLabels.map { NSTextField(labelWithString: $0) }
    var select: ((Int) -> Void)?
    /// Builds the snapping slider and noninteractive labels with a single accessible speed value.
    override init(frame: NSRect) {
        super.init(frame: frame)
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.target = self; slider.action = #selector(changed)
        slider.setAccessibilityLabel("Playback speed")
        addSubview(slider)
        for label in labels {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.alignment = .center
            label.setAccessibilityElement(false)
            addSubview(label)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Positions labels from track geometry rather than the slider’s cached or animated thumb
    /// position.
    override func layout() {
        super.layout()
        // Leave room for the widest endpoint label on either side of the track.
        slider.frame = NSRect(x: 16, y: 14, width: max(0, bounds.width - 32), height: 26)
        guard let cell = slider.cell as? NSSliderCell else { return }
        // Sampling knobRect after changing values returned the same cached thumb
        // position in the live app. Fixed track geometry keeps all five labels
        // correctly centered even while the native thumb animates.
        let track = cell.barRect(flipped: slider.isFlipped)
        let inset = cell.knobThickness / 2
        let first = slider.frame.minX + track.minX + inset
        let travel = max(0, track.width - cell.knobThickness)
        for (index, label) in labels.enumerated() {
            let center = first + travel * CGFloat(index) / CGFloat(labels.count - 1)
            label.frame = NSRect(x: center - 20, y: 0, width: 40, height: 14)
        }
    }
    /// Forwards a native slider change as the selected speed index.
    @objc private func changed() { select?(slider.integerValue) }
}

/// Shows a small boundary frame with a hover/click enlargement and an explicit unavailable/endpoint
/// state.
struct BoundaryThumbnailView: View {
    let preview: BoundaryPreview
    let label: String
    let before: Bool
    var edgeMessage: String? = nil
    @State private var hovered = false
    @State private var pinned = false
    /// Combines hover and pinned state; dismissing the popover clears both to prevent immediate
    /// reopening.
    private var previewVisible: Binding<Bool> {
        Binding(get: { (hovered || pinned) && preview.image != nil }, set: { visible in
            if !visible { hovered = false; pinned = false }
        })
    }
    private var title: String { label + (before ? " · frame before cut" : " · frame after cut") }
    /// Describes the frame’s side and boundary timestamp for the popover and accessibility.
    private var caption: String {
        guard let boundary = preview.boundary else { return title }
        return title + (before ? " · before " : " · at/after ") + timestamp(boundary)
    }
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Color.black
                if let image = preview.image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if preview.loading {
                    ProgressView().controlSize(.mini)
                } else if let edgeMessage {
                    Text(edgeMessage).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(4)
                } else {
                    Image(systemName: preview.unavailable ? "exclamationmark.triangle" : "photo")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.12)))
            Text(label).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(label == "Included" ? Color.green : .secondary)
            Text(before ? "Before" : "After").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(caption)
        .help(preview.unavailable ? "This frame could not be decoded. Export is still available." : caption + " · Hover or click for a larger preview")
        .onHover { hovered = $0 && preview.image != nil }
        .onTapGesture { if preview.image != nil { pinned.toggle() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { pinned = preview.image != nil }
        .onChange(of: preview.loading) { _, loading in if loading { hovered = false; pinned = false } }
        .popover(isPresented: previewVisible, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                if let image = preview.image {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 480, height: 270).background(.black)
                }
                Text(caption).font(.caption).monospacedDigit()
            }.padding(10).preferredColorScheme(.dark)
        }
    }
}

/// Groups the before/after frames for one IN or OUT boundary, labeled by actual inclusion in the
/// export.
struct CutBoundaryPreviews: View {
    @ObservedObject var editor: EditorModel
    let kind: CutKind
    private var slots: [CutPreviewSlot] { kind == .start ? [.inBefore, .inAfter] : [.outBefore, .outAfter] }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(editor.previewTitle(for: kind)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(2).frame(height: 28, alignment: .bottomLeading)
            HStack(alignment: .top, spacing: 8) {
                ForEach(slots, id: \.self) { slot in
                    let preview = editor.cutPreviews[slot] ?? BoundaryPreview()
                    let edge: String? = preview.boundary == 0 && slot.before ? "Start of video"
                        : preview.boundary == editor.duration && !slot.before ? "End of video" : nil
                    BoundaryThumbnailView(preview: preview,
                        label: editor.previewIncluded(slot) ? "Included" : "Excluded", before: slot.before, edgeMessage: edge)
                    if slot.before { CutPreviewDivider() }
                }
            }
        }.padding(12)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.09)))
    }
}

/// A decorative scissors-and-dotted-line separator between the two sides of a cut.
private struct CutPreviewDivider: View {
    var body: some View {
        VStack(spacing: 4) {
            DottedCutLine().stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 4]))
            Image(systemName: "scissors").font(.system(size: 10)).rotationEffect(.degrees(90))
            DottedCutLine().stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 4]))
        }.frame(width: 16, height: 54).foregroundStyle(.secondary).accessibilityHidden(true)
    }
}

/// The vertical path stroked with dots above and below the scissors symbol.
private struct DottedCutLine: Shape {
    /// Draws the centered vertical line; the caller supplies the dotted stroke style.
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

// AppKit's indeterminate bar uses the native animated stripes during joining.
/// Uses native animated stripes for unknown progress and a determinate bar for measured progress.
struct ExportProgressBar: NSViewRepresentable {
    let progress: Double
    /// Creates a native bar supporting both animated and determinate phases.
    func makeNSView(context: Context) -> NSProgressIndicator {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.minValue = 0; bar.maxValue = 1
        bar.usesThreadedAnimation = true
        return bar
    }
    /// Treats negative progress as indeterminate; otherwise displays a fraction from zero to one.
    func updateNSView(_ bar: NSProgressIndicator, context: Context) {
        bar.isIndeterminate = progress < 0
        if progress < 0 { bar.startAnimation(nil) }
        else { bar.stopAnimation(nil); bar.doubleValue = progress }
    }
}

import AppKit
import UniformTypeIdentifiers

/// Owns the save-panel export controls and remembers per-codec choices while the dialog is open.
@MainActor
final class ExportAccessory: NSObject {
    let view = ExportAccessoryView()
    private weak var panel: NSSavePanel?
    private let mode: ExportMode
    private let codecs: [ExportCodec]
    private var codec: ExportCodec
    private var saved: [ExportCodec: ExportSettings] = [:]
    private let codecPopup = ExportMenuButton()
    private let formatPopup = ExportMenuButton()
    private let tunePopup = ExportMenuButton()
    private let profilePopup = ExportMenuButton()
    private let crfField = NSTextField(string: "22")
    private let crfStepper = NSStepper()
    private let qualityRow = NSStackView()
    private let tuneRow = NSStackView()
    private let profileRow = NSStackView()
    private let formatRow = NSStackView()
    private var descriptionLabel: NSTextField { view.descriptionLabel }
    private var formats: [UTType] = []

    /// Builds codec/quality controls and uses the system format picker on macOS 15 or a custom
    /// picker on macOS 14.
    init(panel: NSSavePanel, mode: ExportMode, initial: ExportSettings) {
        self.panel = panel; self.mode = mode
        codecs = mode == .lossless ? ExportCodec.allCases : [.h264, .hevc, .prores]
        codec = codecs.contains(initial.codec) ? initial.codec : .hevc
        super.init()
        saved[codec] = initial.codec == codec ? initial : .defaults(for: codec)
        for popup in [codecPopup, formatPopup, tunePopup, profilePopup] {
            popup.isBordered = true
            popup.isTransparent = false
            popup.bezelStyle = .rounded
            popup.controlSize = .regular
            popup.font = .systemFont(ofSize: 13)
            popup.widthAnchor.constraint(equalToConstant: 240).isActive = true
            popup.heightAnchor.constraint(equalToConstant: 28).isActive = true
            popup.setFrameSize(NSSize(width: 240, height: 28))
        }
        codecPopup.setAccessibilityLabel("Video codec")
        formatPopup.setAccessibilityLabel("File format")
        tunePopup.setAccessibilityLabel("Encoder tune")
        profilePopup.setAccessibilityLabel("ProRes profile")
        codecPopup.addItems(withTitles: codecs.map(\.rawValue))
        codecPopup.selectItem(at: codecs.firstIndex(of: codec)!)
        codecPopup.target = self; codecPopup.action = #selector(changeCodec)
        view.addRow(row("Video:", [codecPopup]))

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal; formatter.allowsFloats = false
        formatter.minimum = 0; formatter.maximum = 51
        crfField.formatter = formatter
        crfField.alignment = .right
        crfField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        crfField.target = self; crfField.action = #selector(changeCRF)
        crfField.setAccessibilityLabel("CRF quality")
        crfStepper.minValue = 0; crfStepper.maxValue = 51; crfStepper.increment = 1
        crfStepper.target = self; crfStepper.action = #selector(stepCRF)
        crfStepper.setAccessibilityLabel("Adjust CRF quality")
        let hint = NSTextField(labelWithString: "Lower = higher quality and larger files")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        configure(qualityRow, label: "Quality (CRF):", controls: [crfField, crfStepper, hint])
        configure(tuneRow, label: "Tune:", controls: [tunePopup])
        profilePopup.addItems(withTitles: ProResProfile.allCases.map(\.title))
        configure(profileRow, label: "Profile:", controls: [profilePopup])
        for controlRow in [qualityRow, tuneRow, profileRow] { view.addRow(controlRow) }
        if #available(macOS 15.0, *) { panel.showsContentTypes = true }
        else {
            configure(formatRow, label: "File format:", controls: [formatPopup])
            formatPopup.target = self; formatPopup.action = #selector(changeFormat)
            view.addRow(formatRow)
        }
        descriptionLabel.font = .systemFont(ofSize: 11)
        descriptionLabel.textColor = .secondaryLabelColor
        refresh()
    }

    /// Reads and validates current field text, including edits not yet committed by Return or
    /// focus changes.
    func chosenSettings() throws -> ExportSettings {
        var settings = ExportSettings.defaults(for: codec)
        if codec == .h264 || codec == .hevc {
            guard let number = Int(crfField.stringValue), (0...51).contains(number) else {
                throw MediaError(message: "Enter a whole-number CRF quality between 0 and 51.")
            }
            settings.crf = number
            settings.tune = codec.tunes[max(0, tunePopup.indexOfSelectedItem)]
        }
        if codec == .prores { settings.proResProfile = ProResProfile.allCases[max(0, profilePopup.indexOfSelectedItem)] }
        return settings
    }

    /// Builds a consistently aligned label/control row with flexible trailing space.
    private func configure(_ stack: NSStackView, label: String, controls: [NSView]) {
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 8
        let caption = NSTextField(labelWithString: label)
        caption.alignment = .right
        caption.widthAnchor.constraint(equalToConstant: 88).isActive = true
        stack.addArrangedSubview(caption)
        for control in controls { stack.addArrangedSubview(control) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
    }
    /// Creates a new labeled control row using the shared alignment rules.
    private func row(_ label: String, _ controls: [NSView]) -> NSStackView {
        let stack = NSStackView(); configure(stack, label: label, controls: controls); return stack
    }
    /// Remembers valid settings for the old codec and restores defaults or prior choices for the
    /// new one.
    @objc private func changeCodec() {
        if let settings = try? chosenSettings() { saved[codec] = settings }
        codec = codecs[codecPopup.indexOfSelectedItem]
        refresh()
    }
    /// Synchronizes the stepper after a valid typed quality value is committed.
    @objc private func changeCRF() {
        if let value = Int(crfField.stringValue), (0...51).contains(value) { crfStepper.integerValue = value }
    }
    /// Copies the stepper’s quality value into the editable field.
    @objc private func stepCRF() { crfField.integerValue = crfStepper.integerValue }
    /// Restores codec settings, shows applicable rows, and recalculates supported formats and
    /// layout.
    private func refresh() {
        let settings = saved[codec] ?? .defaults(for: codec)
        crfField.integerValue = settings.crf; crfStepper.integerValue = settings.crf
        tunePopup.removeAllItems()
        tunePopup.addItems(withTitles: codec.tunes.map(Self.tuneTitle))
        tunePopup.selectItem(at: codec.tunes.firstIndex(of: settings.tune) ?? 0)
        profilePopup.selectItem(at: settings.proResProfile.rawValue)
        qualityRow.isHidden = codec != .h264 && codec != .hevc
        tuneRow.isHidden = qualityRow.isHidden
        profileRow.isHidden = codec != .prores
        let boundary = mode == .exact ? "Uses the marked frames." : "Uses the surrounding keyframes shown in the editor."
        let detail: String
        switch codec {
        case .lossless: detail = "Copies video and every audio track without further re-encoding."
        case .h264: detail = "H.264 video, medium preset. Audio: AAC, 192 kbps per track."
        case .hevc: detail = "10-bit HEVC video, medium preset. Audio: AAC, 192 kbps per track. CRF values are codec-specific."
        case .prores: detail = "10-bit ProRes 422 video and 24-bit PCM audio. Uses MOV and creates large files. CRF and tune do not apply."
        }
        descriptionLabel.stringValue = boundary + " " + detail
        updateFormats()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        for popup in [codecPopup, formatPopup, tunePopup, profilePopup] { popup.needsDisplay = true }
    }
    /// Restricts ProRes to MOV while preserving a still-compatible chosen container when codecs
    /// change.
    private func updateFormats() {
        guard let panel else { return }
        let previous: UTType?
        if #available(macOS 15.0, *) { previous = panel.currentContentType }
        else { previous = formats.indices.contains(formatPopup.indexOfSelectedItem) ? formats[formatPopup.indexOfSelectedItem] : nil }
        formats = codec == .prores ? [.quickTimeMovie]
            : mode == .lossless ? [.quickTimeMovie, .mpeg4Movie] : [.mpeg4Movie, .quickTimeMovie]
        let chosen = previous.flatMap { formats.contains($0) ? $0 : nil } ?? formats[0]
        panel.allowedContentTypes = formats
        if #available(macOS 15.0, *) { panel.currentContentType = chosen }
        formatPopup.removeAllItems()
        formatPopup.addItems(withTitles: formats.map { $0 == .mpeg4Movie ? "MPEG-4 (.mp4)" : "QuickTime (.mov)" })
        formatPopup.selectItem(at: formats.firstIndex(of: chosen)!)
        rename(for: chosen)
    }
    /// Applies the macOS 14 format choice to the panel’s accepted type and filename extension.
    @objc private func changeFormat() {
        guard formats.indices.contains(formatPopup.indexOfSelectedItem) else { return }
        let type = formats[formatPopup.indexOfSelectedItem]
        panel?.allowedContentTypes = [type]
        rename(for: type)
    }
    /// Changes only a known movie extension, preserving dots that belong to the original
    /// basename.
    private func rename(for type: UTType) {
        guard let panel else { return }
        let name = panel.nameFieldStringValue as NSString
        let base = ["mov", "mp4"].contains(name.pathExtension.lowercased()) ? name.deletingPathExtension : name as String
        panel.nameFieldStringValue = base + (type == .mpeg4Movie ? ".mp4" : ".mov")
    }
    /// Converts FFmpeg tune identifiers into readable menu labels.
    private static func tuneTitle(_ tune: String) -> String {
        ["": "Default", "film": "Film", "animation": "Animation", "grain": "Grain", "stillimage": "Still image",
         "fastdecode": "Fast decode", "zerolatency": "Zero latency", "psnr": "PSNR (benchmark)", "ssim": "SSIM (benchmark)"][tune] ?? tune
    }
}

// NSPopUpButton's themed bezel can remain invisible on first presentation in
// the system save panel. Draw the closed control ourselves; its cell still owns
// the native menu, selection, keyboard handling, and accessibility behavior.
/// A native popup with explicit closed-state drawing to avoid invisible controls on initial
/// save-panel presentation.
@MainActor
final class ExportMenuButton: NSPopUpButton {
    override var wantsUpdateLayer: Bool { false }
    /// Paints the bezel, selected title, and arrows while retaining NSPopUpButton’s native menu
    /// behavior.
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 2)
        let bezel = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        (isHighlighted ? NSColor.selectedControlColor : NSColor.controlBackgroundColor).setFill()
        bezel.fill()
        NSColor.separatorColor.setStroke()
        bezel.lineWidth = 1; bezel.stroke()
        let color: NSColor = isEnabled ? .labelColor : .disabledControlTextColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: titleOfSelectedItem ?? "", attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: color, .paragraphStyle: paragraph
        ])
        let height = ceil(title.size().height)
        title.draw(in: NSRect(x: rect.minX + 9, y: rect.midY - height / 2, width: max(0, rect.width - 32), height: height))
        color.setStroke()
        let arrows = NSBezierPath()
        let x = rect.maxX - 13
        arrows.move(to: NSPoint(x: x - 3, y: rect.midY + 2))
        arrows.line(to: NSPoint(x: x, y: rect.midY + 5))
        arrows.line(to: NSPoint(x: x + 3, y: rect.midY + 2))
        arrows.move(to: NSPoint(x: x - 3, y: rect.midY - 2))
        arrows.line(to: NSPoint(x: x, y: rect.midY - 5))
        arrows.line(to: NSPoint(x: x + 3, y: rect.midY - 2))
        arrows.lineWidth = 1.2; arrows.lineCapStyle = .round; arrows.lineJoinStyle = .round
        arrows.stroke()
    }
}

// The panel owns the accessory's width. Lay out rows and explanatory text using
// that actual width, rather than a pre-sized stack whose controls can start at
// zero height when attached to the system save panel.
/// Lays out export rows and wrapping explanatory text at the width assigned by the save panel.
@MainActor
final class ExportAccessoryView: NSView {
    let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private var rows: [NSView] = []
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: frame.height) }
    /// Creates a width-resizable accessory with multiline explanatory text.
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 100))
        autoresizingMask = [.width]
        descriptionLabel.maximumNumberOfLines = 0
        descriptionLabel.lineBreakMode = .byWordWrapping
        addSubview(descriptionLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Adds an ordered settings row to the accessory’s manually managed layout.
    func addRow(_ row: NSView) { rows.append(row); addSubview(row) }
    /// Fits visible rows and text to the actual panel width, updating the accessory’s required
    /// height.
    override func layout() {
        super.layout()
        let padding: CGFloat = 20
        let width = max(0, bounds.width - padding * 2)
        var y: CGFloat = 12
        for row in rows where !row.isHidden {
            row.frame = NSRect(x: padding, y: y, width: width, height: 28)
            row.layoutSubtreeIfNeeded()
            y += 38
        }
        descriptionLabel.preferredMaxLayoutWidth = width
        let textHeight = ceil(descriptionLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10000)).height ?? 28)
        descriptionLabel.frame = NSRect(x: padding, y: y, width: width, height: textHeight)
        let height = y + textHeight + 12
        if abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: height))
            invalidateIntrinsicContentSize()
        }
    }
    /// Requests fresh layout and drawing once the system panel attaches the accessory.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        for row in rows { row.needsDisplay = true }
    }
}

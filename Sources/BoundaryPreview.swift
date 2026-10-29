import AppKit
import Foundation

/// Display state for a single boundary thumbnail, including pending and failed decoding.
struct BoundaryPreview {
    var image: NSImage?
    var boundary: Double?
    var loading = false
    var unavailable = false
}

/// The four before/after thumbnail positions for the selected IN and OUT boundaries.
enum CutPreviewSlot: CaseIterable, Hashable {
    case inBefore, inAfter, outBefore, outAfter
    var kind: CutKind { self == .inBefore || self == .inAfter ? .start : .end }
    var before: Bool { self == .inBefore || self == .outBefore }
}

/// Requests either the first frame at/after a boundary or the last frame strictly before it.
enum BoundarySide: String { case first, last }

/// A hashable thumbnail request, including the seek range needed for variable-rate media.
struct BoundaryPreviewRequest: Hashable {
    let source: URL
    let side: BoundarySide
    let boundary: Double
    let seekStart: Double

    /// Chooses a short decode tail while including a preceding packet even across a long
    /// variable-rate gap.
    init(source: URL, side: BoundarySide, boundary: Double, lastPacketTime: Double? = nil) {
        self.source = source; self.side = side; self.boundary = boundary
        // The final decoded frame can precede the boundary by a long interval in
        // variable-rate media. Include its packet even if it lies outside 2 seconds.
        seekStart = side == .first ? boundary : max(0, min(boundary - 2, lastPacketTime ?? boundary))
    }
}

/// Decodes boundary thumbnails with FFmpeg independently of the visible AVPlayer.
struct BoundaryPreviewEngine {
    /// Returns one aspect-correct PNG at the requested side of a boundary, with bounded
    /// scaled-frame buffering.
    static func image(_ request: BoundaryPreviewRequest, tools: Toolchain) async throws -> Data {
        var args = ["-hide_banner", "-v", "error", "-nostdin", "-ss", MediaEngine.number(request.seekStart)]
        if request.side == .last {
            // Include decode lookahead, then exclude end and later presentation
            // frames explicitly. -t alone uses different timestamp conventions.
            args += ["-t", MediaEngine.number(request.boundary - request.seekStart + 1)]
        }
        args += ["-i", request.source.path, "-map", "0:v:0", "-an"]
        let scale = "scale=w='min(480,270*dar)':h='min(270,480/dar)',setsar=1"
        let filter: String
        if request.side == .last {
            // Scale before buffering/reversal. Only this short tail is retained,
            // never an entire recording or a full-resolution GOP.
            filter = "trim=end=\(MediaEngine.number(request.boundary - request.seekStart)),\(scale),reverse"
        } else { filter = scale }
        args += ["-vf", filter, "-frames:v", "1", "-fps_mode", "passthrough", "-c:v", "png", "-f", "image2pipe", "pipe:1"]
        let data = try await Command().run(tools.ffmpeg, args)
        try Task.checkCancellation()
        guard !data.isEmpty else { throw MediaError(message: "No included frame could be decoded at this boundary.") }
        return data
    }
}

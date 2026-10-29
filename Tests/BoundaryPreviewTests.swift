import Foundation

/// Compares boundary thumbnails with independently selected decoded frames, including variable-rate gaps.
@main
struct BoundaryPreviewTests {
    /// Checks exclusive cut boundaries and file endpoints using generated constant- and
    /// variable-rate media.
    static func main() async throws {
        let tools = try Toolchain.testing()
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = root.appendingPathComponent("fixture.mp4")
        let scale = "scale=w='min(480,270*dar)':h='min(270,480/dar)',setsar=1"
        /// Decodes a known frame ordinal from the start, providing a reference independent of
        /// boundary seeking.
        func expected(_ source: URL, frame: Int) async throws -> Data {
            try await Command().run(tools.ffmpeg, ["-v", "error", "-i", source.path, "-map", "0:v:0", "-an",
                "-vf", "select=eq(n\\,\(frame)),\(scale)", "-frames:v", "1", "-fps_mode", "passthrough", "-c:v", "png", "-f", "image2pipe", "pipe:1"])
        }
        /// Compares the requested boundary PNG with the reference frame’s PNG.
        func check(_ source: URL, side: BoundarySide, boundary: Double, last: Double? = nil, frame: Int) async throws {
            let actual = try await BoundaryPreviewEngine.image(BoundaryPreviewRequest(source: source, side: side, boundary: boundary, lastPacketTime: last), tools: tools)
            let reference = try await expected(source, frame: frame)
            precondition(actual == reference, "\(side) at \(boundary) must show decoded frame \(frame)")
        }
        let index = try await MediaEngine.index(source: source, tools: tools)
        let bounds = MediaEngine.effective(Clip(start: 0.52, end: 1.4), mode: .lossless, keyframes: index.keyframes, duration: 8)
        try await check(source, side: .first, boundary: bounds.start, frame: 0)
        try await check(source, side: .last, boundary: bounds.end, last: index.lastPacket(before: bounds.end), frame: 49)
        try await check(source, side: .last, boundary: 0.52, last: index.lastPacket(before: 0.52), frame: 12)
        try await check(source, side: .first, boundary: 0.52, frame: 13)
        try await check(source, side: .last, boundary: 1.4, last: index.lastPacket(before: 1.4), frame: 34)
        try await check(source, side: .first, boundary: 1.4, frame: 35)
        try await check(source, side: .first, boundary: 2, frame: 50)
        try await check(source, side: .last, boundary: 8, last: index.lastPacket(before: 8), frame: 199)
        let vfr = root.appendingPathComponent("thumbnail-vfr.mp4")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=10:duration=4",
            "-vf", "select=not(mod(n\\,3))", "-fps_mode", "vfr", "-c:v", "libx264", vfr.path])
        let vfrIndex = try await MediaEngine.index(source: vfr, tools: tools)
        try await check(vfr, side: .first, boundary: 0.5, frame: 2)
        try await check(vfr, side: .last, boundary: 2, last: vfrIndex.lastPacket(before: 2), frame: 6)
        try await check(vfr, side: .first, boundary: 2, frame: 7)
        let gaps = root.appendingPathComponent("thumbnail-gaps.mp4")
        _ = try await Command().run(tools.ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=10:duration=4",
            "-vf", "select=eq(n\\,0)+eq(n\\,39)", "-fps_mode", "vfr", "-c:v", "libx264", gaps.path])
        let gapIndex = try await MediaEngine.index(source: gaps, tools: tools)
        try await check(gaps, side: .last, boundary: 3, last: gapIndex.lastPacket(before: 3), frame: 0)
        print("PASS: frames immediately before/after lossless and exact cut boundaries, exclusive exact out-point, file-end thumbnail, variable-rate frames and long gaps")
    }
}

import Foundation

extension Toolchain {
    /// Uses explicitly selected release tools in tests, or the normal locator for development checks.
    static func testing() throws -> Toolchain {
        guard let path = ProcessInfo.processInfo.environment["TEST_TOOL_DIR"] else { return try locate() }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let tools = Toolchain(ffmpeg: directory.appendingPathComponent("ffmpeg"), ffprobe: directory.appendingPathComponent("ffprobe"))
        guard [tools.ffmpeg, tools.ffprobe].allSatisfy({ FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw MediaError(message: "TEST_TOOL_DIR must contain executable ffmpeg and ffprobe files.")
        }
        return tools
    }
}

import Foundation

func loadConfig(from path: String) throws -> Config {
    let absolutePath = resolveAbsolutePath(path)
    let fileURL = URL(fileURLWithPath: absolutePath)
    let data: Data
    do {
        data = try Data(contentsOf: fileURL)
    } catch {
        throw OverseerError.io("failed to read config \(absolutePath): \(error.localizedDescription)")
    }

    let decoder = JSONDecoder()
    let config: Config
    do {
        config = try decoder.decode(Config.self, from: data)
    } catch {
        throw OverseerError.invalidConfig("failed to parse config \(absolutePath): \(error.localizedDescription)")
    }

    try config.validate()
    return config
}

func resolveAbsolutePath(_ path: String, currentDirectory: String = FileManager.default.currentDirectoryPath) -> String {
    let expandedPath = (path as NSString).expandingTildeInPath
    if expandedPath.hasPrefix("/") {
        return URL(fileURLWithPath: expandedPath).standardized.path
    }
    return URL(fileURLWithPath: currentDirectory).appendingPathComponent(expandedPath).standardized.path
}

func nowEpochSeconds() -> UInt64 {
    UInt64(Date().timeIntervalSince1970)
}

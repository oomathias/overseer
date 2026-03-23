import Foundation

func resolveCurrentExecutablePath(
  arguments: [String] = CommandLine.arguments,
  currentDirectory: String = FileManager.default.currentDirectoryPath,
  environment: [String: String] = Foundation.ProcessInfo.processInfo.environment,
  bundleExecutablePath: String? = Bundle.main.executablePath,
  fileManager: FileManager = .default
) throws -> String {
  if let bundleExecutablePath, !bundleExecutablePath.isEmpty {
    return try resolveAbsolutePath(bundleExecutablePath, currentDirectory: currentDirectory)
  }

  guard let firstArgument = arguments.first, !firstArgument.isEmpty else {
    throw OverseerError.system("failed to resolve current executable path")
  }

  if firstArgument.contains("/") {
    return try resolveAbsolutePath(firstArgument, currentDirectory: currentDirectory)
  }

  if let executablePath = resolveExecutableInPATH(
    named: firstArgument,
    currentDirectory: currentDirectory,
    searchPath: environment["PATH"],
    fileManager: fileManager
  ) {
    return executablePath
  }

  return try resolveAbsolutePath(firstArgument, currentDirectory: currentDirectory)
}

private func resolveExecutableInPATH(
  named executableName: String,
  currentDirectory: String,
  searchPath: String?,
  fileManager: FileManager
) -> String? {
  guard let searchPath, !searchPath.isEmpty else {
    return nil
  }

  for pathEntry in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
    let directory = pathEntry.isEmpty ? currentDirectory : String(pathEntry)
    let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executableName).standardized.path
    if fileManager.isExecutableFile(atPath: candidate) {
      return candidate
    }
  }

  return nil
}

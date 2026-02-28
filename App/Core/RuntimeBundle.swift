import Foundation
import Darwin
import AppKit

private let runtimeBundleName = "OverseerRunner.app"
private let runtimeBundleExecutableName = "overseer-swift"
private let runtimeBundleIdentifier = "io.m7b.overseer.runner"
private let runtimeReexecEnv = "OVERSEER_REEXEC_BUNDLED"

func ensureBundledRuntimeForMonitor() throws {
    if runningFromValidAppBundle() {
        return
    }
    if Foundation.ProcessInfo.processInfo.environment[runtimeReexecEnv] == "1" {
        return
    }

    let bundledExecutable = try prepareBundledExecutable()
    try reexecCurrentProcess(with: bundledExecutable)
}

func resolveBundledExecutableForService() throws -> String {
    if runningFromValidAppBundle(), let executable = Bundle.main.executablePath {
        return executable
    }
    return try prepareBundledExecutable()
}

func runningFromValidAppBundle() -> Bool {
    let bundle = Bundle.main
    guard bundle.bundleIdentifier != nil else {
        return false
    }
    return bundle.bundleURL.pathExtension == "app"
}

private func prepareBundledExecutable() throws -> String {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let supportDir = home
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("overseer", isDirectory: true)
    let bundleURL = supportDir.appendingPathComponent(runtimeBundleName, isDirectory: true)
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
    let plistURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
    let bundledExecutableURL = macOSURL.appendingPathComponent(runtimeBundleExecutableName, isDirectory: false)

    try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

    let sourceExecutable = resolveAbsolutePath(Bundle.main.executablePath ?? CommandLine.arguments[0])
    if sourceExecutable != bundledExecutableURL.path {
        if fm.fileExists(atPath: bundledExecutableURL.path) {
            try fm.removeItem(at: bundledExecutableURL)
        }
        try fm.copyItem(atPath: sourceExecutable, toPath: bundledExecutableURL.path)
        _ = chmod(bundledExecutableURL.path, mode_t(0o755))
    }

    try writeRuntimeBundlePlist(plistURL: plistURL)
    try writeRuntimeBundleIcon(resourcesURL: resourcesURL)
    return bundledExecutableURL.path
}

private func writeRuntimeBundlePlist(plistURL: URL) throws {
    let plist: [String: Any] = [
        "CFBundleName": "OverseerRunner",
        "CFBundleDisplayName": "OverseerRunner",
        "CFBundleIdentifier": runtimeBundleIdentifier,
        "CFBundleExecutable": runtimeBundleExecutableName,
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": appVersion,
        "CFBundleIconFile": "OverseerRunner.png",
        "LSUIElement": true,
    ]

    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: plistURL, options: .atomic)
}

private func writeRuntimeBundleIcon(resourcesURL: URL) throws {
    let iconURL = resourcesURL.appendingPathComponent("OverseerRunner.png", isDirectory: false)
    if FileManager.default.fileExists(atPath: iconURL.path) {
        return
    }

    let size = NSSize(width: 256, height: 256)
    let image = NSImage(size: size)
    image.lockFocus()

    let rect = NSRect(origin: .zero, size: size)
    NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.23, alpha: 1).setFill()
    NSBezierPath(rect: rect).fill()

    let circleRect = rect.insetBy(dx: 24, dy: 24)
    NSColor(calibratedRed: 0.22, green: 0.63, blue: 0.91, alpha: 1).setFill()
    NSBezierPath(roundedRect: circleRect, xRadius: 64, yRadius: 64).fill()

    let text = "O"
    let font = NSFont.systemFont(ofSize: 140, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let textSize = text.size(withAttributes: attributes)
    let textRect = NSRect(
        x: (size.width - textSize.width) / 2,
        y: (size.height - textSize.height) / 2 - 8,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: textRect, withAttributes: attributes)

    image.unlockFocus()

    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        return
    }

    try png.write(to: iconURL, options: .atomic)
}

private func reexecCurrentProcess(with executablePath: String) throws {
    var arguments = CommandLine.arguments
    if arguments.isEmpty {
        arguments = [executablePath]
    } else {
        arguments[0] = executablePath
    }

    setenv(runtimeReexecEnv, "1", 1)

    var cStrings: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
    cStrings.append(nil)

    defer {
        for cString in cStrings where cString != nil {
            free(cString)
        }
    }

    let result = executablePath.withCString { pathPointer in
        cStrings.withUnsafeMutableBufferPointer { argv in
            execv(pathPointer, argv.baseAddress)
        }
    }

    if result != 0 {
        throw OverseerError.system("failed to re-exec bundled runtime: \(String(cString: strerror(errno)))")
    }
}

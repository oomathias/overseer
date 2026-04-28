import Foundation

struct PIDFileMatch: Equatable {
  let pid: Int32
  let filePath: String
  let modifiedAt: Date
}

struct PIDFilter: Equatable {
  let matches: [Int32: PIDFileMatch]

  func contains(process: ProcessInfo) -> Bool {
    guard let match = matches[process.pid] else {
      return false
    }
    return match.modifiedAt.timeIntervalSince1970 >= process.startTime.timeIntervalSince1970
  }
}

final class PIDGlobResolver {
  func resolveFilters(rules: [Rule]) -> [Int: PIDFilter] {
    var filters: [Int: PIDFilter] = [:]

    for (index, rule) in rules.enumerated() {
      guard let pattern = normalizedProcessFilter(rule.pidFileGlob) else {
        continue
      }

      filters[index] = PIDFilter(matches: [:])

      let expanded = (pattern as NSString).expandingTildeInPath
      let directory = (expanded as NSString).deletingLastPathComponent
      let filePattern = (expanded as NSString).lastPathComponent
      if filePattern.isEmpty {
        continue
      }

      let dirPath = directory.isEmpty ? "." : directory
      guard isSecureDirectory(path: dirPath) else {
        continue
      }
      guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else {
        continue
      }

      var matches: [Int32: PIDFileMatch] = [:]
      for entry in entries where globMatch(pattern: filePattern, text: entry) {
        let filePath = (dirPath as NSString).appendingPathComponent(entry)
        if let match = readPIDFile(path: filePath), match.pid > 0 {
          if let existing = matches[match.pid], existing.modifiedAt >= match.modifiedAt {
            continue
          }
          matches[match.pid] = match
        }
      }

      filters[index] = PIDFilter(matches: matches)
    }

    return filters
  }

  private func readPIDFile(path: String) -> PIDFileMatch? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
      return nil
    }
    let token = content.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).first
    guard let token, let pid = Int32(token) else {
      return nil
    }
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let modifiedAt = attributes[.modificationDate] as? Date
    else {
      return nil
    }
    return PIDFileMatch(pid: pid, filePath: path, modifiedAt: modifiedAt)
  }

  private func isSecureDirectory(path: String) -> Bool {
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
      return false
    }
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let permissions = attributes[.posixPermissions] as? NSNumber
    else {
      return false
    }
    return permissions.intValue & 0o022 == 0
  }

  private func globMatch(pattern: String, text: String) -> Bool {
    let p = Array(pattern.utf8)
    let t = Array(text.utf8)

    let star = UInt8(ascii: "*")
    let question = UInt8(ascii: "?")

    var pIndex = 0
    var tIndex = 0
    var starIndex: Int? = nil
    var backtrackText = 0

    while tIndex < t.count {
      if pIndex < p.count, p[pIndex] == question || p[pIndex] == t[tIndex] {
        pIndex += 1
        tIndex += 1
        continue
      }

      if pIndex < p.count, p[pIndex] == star {
        starIndex = pIndex
        pIndex += 1
        backtrackText = tIndex
        continue
      }

      if let starIndex {
        pIndex = starIndex + 1
        backtrackText += 1
        tIndex = backtrackText
        continue
      }

      return false
    }

    while pIndex < p.count, p[pIndex] == star {
      pIndex += 1
    }

    return pIndex == p.count
  }
}

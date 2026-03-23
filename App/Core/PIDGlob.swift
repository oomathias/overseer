import Foundation

final class PIDGlobResolver {
  func resolveFilters(rules: [Rule]) -> [Int: Set<Int32>] {
    var filters: [Int: Set<Int32>] = [:]

    for (index, rule) in rules.enumerated() {
      guard let pattern = normalizedProcessFilter(rule.pidFileGlob) else {
        continue
      }

      filters[index] = []

      let expanded = (pattern as NSString).expandingTildeInPath
      let directory = (expanded as NSString).deletingLastPathComponent
      let filePattern = (expanded as NSString).lastPathComponent
      if filePattern.isEmpty {
        continue
      }

      let dirPath = directory.isEmpty ? "." : directory
      guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else {
        continue
      }

      var pids: Set<Int32> = []
      for entry in entries where globMatch(pattern: filePattern, text: entry) {
        let filePath = (dirPath as NSString).appendingPathComponent(entry)
        if let pid = readPIDFromFile(path: filePath), pid > 0 {
          pids.insert(pid)
        }
      }

      filters[index] = pids
    }

    return filters
  }

  private func readPIDFromFile(path: String) -> Int32? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
      return nil
    }
    let token = content.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).first
    guard let token, let pid = Int32(token) else {
      return nil
    }
    return pid
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

import Darwin
import Foundation

struct ExecutablePathCache {
  private struct Record {
    let startTime: ProcessStartTime
    let path: String
  }

  private var records: [Int32: Record] = [:]

  mutating func resolve(
    pid: Int32,
    startTime: ProcessStartTime,
    readPath: (Int32) -> String?
  ) -> String? {
    if let cached = records[pid], cached.startTime == startTime {
      return cached.path
    }

    guard let path = readPath(pid), !path.isEmpty else {
      return nil
    }

    records[pid] = Record(startTime: startTime, path: path)
    return path
  }
}

final class ProcessSampler {
  private struct CPURecord {
    let totalCPUTimeNS: UInt64
    let timestampNS: UInt64
  }

  private var previousCPU: [Int32: CPURecord] = [:]
  private var executablePathCache = ExecutablePathCache()

  func snapshot(includeCommandPath: Bool) throws -> [ProcessInfo] {
    let pids = listPIDs()
    let nowEpoch = nowEpochSeconds()
    let nowUptimeNS = DispatchTime.now().uptimeNanoseconds

    var processes: [ProcessInfo] = []
    processes.reserveCapacity(pids.count)

    var nextCPU: [Int32: CPURecord] = [:]
    nextCPU.reserveCapacity(pids.count)
    var nextExecutablePathCache = ExecutablePathCache()

    for pid in pids where pid > 0 {
      guard let bsdInfo = readBSDInfo(pid: pid) else {
        continue
      }
      guard let taskInfo = readTaskInfo(pid: pid) else {
        continue
      }

      let bsdProcessName = processName(from: bsdInfo)
      let startTime = processStartTime(from: bsdInfo)
      let executablePath = resolveExecutablePath(
        pid: pid,
        startTime: startTime,
        includeCommandPath: includeCommandPath,
        nextCache: &nextExecutablePathCache
      )
      let processName =
        includeCommandPath
        ? executablePath.flatMap(executableName(from:)) ?? ""
        : bsdProcessName
      let processNameSource: ProcessNameSource = includeCommandPath ? .executablePath : .bsdComm
      let commandLine = includeCommandPath ? executablePath ?? "" : bsdProcessName
      let totalCPU = taskInfo.pti_total_user &+ taskInfo.pti_total_system
      let cpuPercent: Double

      if let prior = previousCPU[pid], nowUptimeNS > prior.timestampNS, totalCPU >= prior.totalCPUTimeNS {
        let cpuDelta = Double(totalCPU - prior.totalCPUTimeNS)
        let wallDelta = Double(nowUptimeNS - prior.timestampNS)
        cpuPercent = wallDelta > 0 ? (cpuDelta / wallDelta) * 100.0 : 0.0
      } else {
        cpuPercent = 0.0
      }

      let elapsedSeconds =
        nowEpoch >= startTime.epochSeconds ? (nowEpoch - startTime.epochSeconds) : 0
      let rssKB = UInt64(taskInfo.pti_resident_size / 1024)

      processes.append(
        ProcessInfo(
          pid: pid,
          ppid: Int32(clamping: bsdInfo.pbi_ppid),
          name: processName,
          nameSource: processNameSource,
          command: commandLine,
          startTime: startTime,
          cpuPercent: cpuPercent,
          rssKB: rssKB,
          elapsedSeconds: elapsedSeconds
        )
      )

      nextCPU[pid] = CPURecord(totalCPUTimeNS: totalCPU, timestampNS: nowUptimeNS)
    }

    previousCPU = nextCPU
    executablePathCache = includeCommandPath ? nextExecutablePathCache : ExecutablePathCache()

    return processes
  }

  private func listPIDs() -> [Int32] {
    let count = proc_listallpids(nil, 0)
    if count <= 0 {
      return []
    }

    var pids = [pid_t](repeating: 0, count: Int(count))
    let bytes = Int32(pids.count * MemoryLayout<pid_t>.size)
    let filled = proc_listallpids(&pids, bytes)
    if filled <= 0 {
      return []
    }

    return pids.prefix(Int(filled)).map { Int32($0) }
  }

  private func readBSDInfo(pid: Int32) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let filled = withUnsafeMutableBytes(of: &info) { bytes in
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, bytes.baseAddress, Int32(bytes.count))
    }
    if filled != Int32(MemoryLayout<proc_bsdinfo>.size) {
      return nil
    }
    return info
  }

  private func readTaskInfo(pid: Int32) -> proc_taskinfo? {
    var info = proc_taskinfo()
    let filled = withUnsafeMutableBytes(of: &info) { bytes in
      proc_pidinfo(pid, PROC_PIDTASKINFO, 0, bytes.baseAddress, Int32(bytes.count))
    }
    if filled != Int32(MemoryLayout<proc_taskinfo>.size) {
      return nil
    }
    return info
  }

  private func processName(from bsdInfo: proc_bsdinfo) -> String {
    var comm = bsdInfo.pbi_comm
    let commSize = MemoryLayout.size(ofValue: comm)
    return withUnsafePointer(to: &comm) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: commSize) { cString in
        String(cString: cString)
      }
    }
  }

  private func processStartTime(from bsdInfo: proc_bsdinfo) -> ProcessStartTime {
    ProcessStartTime(
      seconds: max(Int64(0), Int64(clamping: bsdInfo.pbi_start_tvsec)),
      microseconds: max(Int64(0), Int64(clamping: bsdInfo.pbi_start_tvusec))
    )
  }

  private func resolveExecutablePath(
    pid: Int32,
    startTime: ProcessStartTime,
    includeCommandPath: Bool,
    nextCache: inout ExecutablePathCache
  ) -> String? {
    if !includeCommandPath {
      return nil
    }

    let path = executablePathCache.resolve(pid: pid, startTime: startTime, readPath: processPath(pid:))
    if let path {
      _ = nextCache.resolve(pid: pid, startTime: startTime) { _ in path }
    }
    return path
  }

  private func executableName(from path: String) -> String? {
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? nil : name
  }

  private func processPath(pid: Int32) -> String? {
    var pathBuffer = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_SIZE))
    let copied = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
    if copied <= 0 {
      return nil
    }
    let raw = pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: raw, as: UTF8.self)
  }
}

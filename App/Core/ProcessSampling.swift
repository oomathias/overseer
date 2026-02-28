import Foundation
import Darwin

final class ProcessSampler {
    private struct CPURecord {
        let totalCPUTimeNS: UInt64
        let timestampNS: UInt64
    }

    private struct CommandCacheKey: Hashable {
        let startSeconds: Int64
        let startMicroseconds: Int64
    }

    private struct CommandCacheRecord {
        let key: CommandCacheKey
        let command: String
    }

    private var previousCPU: [Int32: CPURecord] = [:]
    private var commandCache: [Int32: CommandCacheRecord] = [:]

    func snapshot(includeCommandPath: Bool) throws -> [ProcessInfo] {
        let pids = listPIDs()
        let nowEpoch = nowEpochSeconds()
        let nowUptimeNS = DispatchTime.now().uptimeNanoseconds

        var processes: [ProcessInfo] = []
        processes.reserveCapacity(pids.count)

        var nextCPU: [Int32: CPURecord] = [:]
        nextCPU.reserveCapacity(pids.count)
        var nextCommandCache: [Int32: CommandCacheRecord] = [:]
        if includeCommandPath {
            nextCommandCache.reserveCapacity(pids.count)
        }

        for pid in pids where pid > 0 {
            guard let bsdInfo = readBSDInfo(pid: pid) else {
                continue
            }
            guard let taskInfo = readTaskInfo(pid: pid) else {
                continue
            }

            let processName = processName(from: bsdInfo)
            let commandLine = resolveCommandLine(
                pid: pid,
                bsdInfo: bsdInfo,
                fallbackName: processName,
                includeCommandPath: includeCommandPath,
                nextCache: &nextCommandCache
            )
            let totalCPU = taskInfo.pti_total_user &+ taskInfo.pti_total_system
            let cpuPercent: Double

            if let prior = previousCPU[pid], nowUptimeNS > prior.timestampNS, totalCPU >= prior.totalCPUTimeNS {
                let cpuDelta = Double(totalCPU - prior.totalCPUTimeNS)
                let wallDelta = Double(nowUptimeNS - prior.timestampNS)
                cpuPercent = wallDelta > 0 ? (cpuDelta / wallDelta) * 100.0 : 0.0
            } else {
                cpuPercent = 0.0
            }

            let startSeconds = max(Int64(0), Int64(bsdInfo.pbi_start_tvsec))
            let elapsedSeconds = nowEpoch >= UInt64(startSeconds) ? (nowEpoch - UInt64(startSeconds)) : 0
            let rssKB = UInt64(taskInfo.pti_resident_size / 1024)

            processes.append(
                ProcessInfo(
                    pid: pid,
                    ppid: Int32(clamping: bsdInfo.pbi_ppid),
                    name: processName,
                    command: commandLine,
                    cpuPercent: cpuPercent,
                    rssKB: rssKB,
                    elapsedSeconds: elapsedSeconds
                )
            )

            nextCPU[pid] = CPURecord(totalCPUTimeNS: totalCPU, timestampNS: nowUptimeNS)
        }

        previousCPU = nextCPU
        commandCache = includeCommandPath ? nextCommandCache : [:]

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

    private func resolveCommandLine(
        pid: Int32,
        bsdInfo: proc_bsdinfo,
        fallbackName: String,
        includeCommandPath: Bool,
        nextCache: inout [Int32: CommandCacheRecord]
    ) -> String {
        if !includeCommandPath {
            return fallbackName
        }

        let cacheKey = CommandCacheKey(
            startSeconds: Int64(clamping: bsdInfo.pbi_start_tvsec),
            startMicroseconds: Int64(clamping: bsdInfo.pbi_start_tvusec)
        )

        if let cached = commandCache[pid], cached.key == cacheKey {
            nextCache[pid] = cached
            return cached.command
        }

        let command: String
        if let path = processPath(pid: pid), !path.isEmpty {
            command = path
        } else {
            command = fallbackName
        }

        nextCache[pid] = CommandCacheRecord(key: cacheKey, command: command)
        return command
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

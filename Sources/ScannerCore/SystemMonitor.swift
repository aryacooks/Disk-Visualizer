import Darwin
import Foundation

public struct ProcessSample: Identifiable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let residentBytes: Int64
    public let diskWrittenBytes: Int64
    public let diskReadBytes: Int64
}

public struct SystemSample: Sendable {
    public var cpuUser = 0.0
    public var cpuSystem = 0.0
    public var cpuIdle = 100.0
    public var loadAverage = 0.0

    public var memTotal: Int64 = 0
    public var memWired: Int64 = 0
    public var memCompressed: Int64 = 0
    public var memUsed: Int64 = 0

    public var netInPerSec: Int64 = 0
    public var netOutPerSec: Int64 = 0
    public var netInTotal: Int64 = 0
    public var netOutTotal: Int64 = 0

    public var processes: [ProcessSample] = []

    public init() {}

    public var cpuBusy: Double { max(0, min(100, 100 - cpuIdle)) }
}

/// Samples CPU, memory, network and per-process activity.
///
/// Everything here is a *counter*, so a single reading is meaningless — rates
/// come from differencing two samples. The first tick therefore reports no
/// rate rather than a spike, which is why `previous` is optional throughout.
public final class SystemSampler: @unchecked Sendable {

    private var prevCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var prevNet: (inB: Int64, outB: Int64, at: Date)?
    private var prevProcCPU: [Int32: UInt64] = [:]
    private var prevProcAt: Date?

    /// `pti_total_user` / `pti_total_system` are mach absolute-time units, NOT
    /// nanoseconds. On Apple silicon the timebase is 125/3, so reading them as
    /// nanoseconds under-reports every process's CPU by ~41x.
    private let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        if t.denom == 0 { t.numer = 1; t.denom = 1 }
        return t
    }()

    public init() {}

    public func sample() -> SystemSample {
        var s = SystemSample()
        readCPU(&s)
        readMemory(&s)
        readNetwork(&s)
        readProcesses(&s)
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) > 0 { s.loadAverage = load[0] }
        return s
    }

    // MARK: CPU

    private func readCPU(_ s: inout SystemSample) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }

        let user = info.cpu_ticks.0, system = info.cpu_ticks.1
        let idle = info.cpu_ticks.2, nice = info.cpu_ticks.3

        if let p = prevCPUTicks {
            let du = Double(user &- p.user), ds = Double(system &- p.system)
            let di = Double(idle &- p.idle), dn = Double(nice &- p.nice)
            let total = du + ds + di + dn
            if total > 0 {
                s.cpuUser = (du + dn) / total * 100
                s.cpuSystem = ds / total * 100
                s.cpuIdle = di / total * 100
            }
        }
        prevCPUTicks = (user, system, idle, nice)
    }

    // MARK: Memory

    private func readMemory(_ s: inout SystemSample) {
        s.memTotal = Int64(ProcessInfo.processInfo.physicalMemory)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }

        let page = Int64(vm_kernel_page_size)
        s.memWired = Int64(stats.wire_count) * page
        s.memCompressed = Int64(stats.compressor_page_count) * page
        // Roughly what Activity Monitor calls "Memory Used".
        s.memUsed = Int64(stats.active_count + stats.wire_count + stats.compressor_page_count) * page
    }

    // MARK: Network

    private func readNetwork(_ s: inout SystemSample) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return }
        defer { freeifaddrs(head) }

        var inB: Int64 = 0, outB: Int64 = 0
        var cur: UnsafeMutablePointer<ifaddrs>? = start
        while let c = cur {
            defer { cur = c.pointee.ifa_next }
            guard let addr = c.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: c.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }   // loopback isn't real traffic
            guard let data = c.pointee.ifa_data else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            inB += Int64(d.ifi_ibytes)
            outB += Int64(d.ifi_obytes)
        }

        s.netInTotal = inB
        s.netOutTotal = outB
        let now = Date()
        if let p = prevNet {
            let dt = now.timeIntervalSince(p.at)
            if dt > 0.05 {
                s.netInPerSec = Int64(max(0, Double(inB - p.inB) / dt))
                s.netOutPerSec = Int64(max(0, Double(outB - p.outB) / dt))
            }
        }
        prevNet = (inB, outB, now)
    }

    // MARK: Processes

    private func readProcesses(_ s: inout SystemSample) {
        let cap = proc_listallpids(nil, 0)
        guard cap > 0 else { return }
        var pids = [Int32](repeating: 0, count: Int(cap) + 64)
        let byteCount = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard byteCount > 0 else { return }
        let n = Int(byteCount) / MemoryLayout<Int32>.size

        let now = Date()
        let dt = prevProcAt.map { now.timeIntervalSince($0) } ?? 0
        var nextCPU: [Int32: UInt64] = [:]
        nextCPU.reserveCapacity(n)
        var out: [ProcessSample] = []
        out.reserveCapacity(n)

        for i in 0..<n {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var info = proc_taskallinfo()
            let sz = MemoryLayout<proc_taskallinfo>.size
            let got = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, $0, Int32(sz))
            }
            guard got == Int32(sz) else { continue }

            let ticks = info.ptinfo.pti_total_user &+ info.ptinfo.pti_total_system
            let totalNs = ticks / UInt64(timebase.denom) * UInt64(timebase.numer)
            nextCPU[pid] = totalNs

            var cpuPct = 0.0
            if dt > 0.05, let prev = prevProcCPU[pid], totalNs >= prev {
                cpuPct = Double(totalNs - prev) / (dt * 1_000_000_000) * 100
            }

            var name = withUnsafePointer(to: &info.pbsd.pbi_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN * 2)) { String(cString: $0) }
            }
            if name.isEmpty {
                name = withUnsafePointer(to: &info.pbsd.pbi_comm) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
                }
            }
            if name.isEmpty { name = "pid \(pid)" }

            // Disk I/O counters. Requires the same-user check to succeed;
            // other users' processes simply report zero rather than failing.
            var written: Int64 = 0, read: Int64 = 0
            var rusage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &rusage) { rp -> Bool in
                rp.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { ptr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, ptr) == 0
                }
            }
            if ok {
                written = Int64(bitPattern: rusage.ri_diskio_byteswritten)
                read = Int64(bitPattern: rusage.ri_diskio_bytesread)
            }

            out.append(ProcessSample(pid: pid, name: name,
                                     cpuPercent: cpuPct,
                                     residentBytes: Int64(info.ptinfo.pti_resident_size),
                                     diskWrittenBytes: written,
                                     diskReadBytes: read))
        }

        prevProcCPU = nextCPU
        prevProcAt = now
        s.processes = out.sorted { $0.cpuPercent > $1.cpuPercent }
    }
}

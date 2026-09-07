import Darwin
import Foundation

public struct MonthBucket: Identifiable, Sendable {
    public var id: String { "\(year)-\(month)" }
    public let year: Int
    public let month: Int // 1...12
    public var bytes: Int64
    public var fileCount: Int

    public init(year: Int, month: Int, bytes: Int64, fileCount: Int) {
        self.year = year
        self.month = month
        self.bytes = bytes
        self.fileCount = fileCount
    }

    public var monthShortName: String {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard month >= 1 && month <= 12 else { return "" }
        return names[month - 1]
    }
}

public struct BigAndUntouchedItem: Identifiable, Sendable {
    public var id: Int { nodeIndex }
    public let nodeIndex: Int
    public let name: String
    public let path: String
    public let size: Int64
    public let mtime: Date
    public let daysUntouched: Int

    public init(nodeIndex: Int, name: String, path: String, size: Int64, mtime: Date, daysUntouched: Int) {
        self.nodeIndex = nodeIndex
        self.name = name
        self.path = path
        self.size = size
        self.mtime = mtime
        self.daysUntouched = daysUntouched
    }
}

public struct AgeMapResult: Sendable {
    public let months: [MonthBucket]
    public let busiestMonth: MonthBucket?
    public let years: [Int]
    public let bigAndUntouched: [BigAndUntouchedItem]
    public let maxMonthBytes: Int64

    public init(months: [MonthBucket], busiestMonth: MonthBucket?, years: [Int], bigAndUntouched: [BigAndUntouchedItem], maxMonthBytes: Int64) {
        self.months = months
        self.busiestMonth = busiestMonth
        self.years = years
        self.bigAndUntouched = bigAndUntouched
        self.maxMonthBytes = maxMonthBytes
    }

    public func bytesFor(year: Int, month: Int) -> Int64 {
        months.first(where: { $0.year == year && $0.month == month })?.bytes ?? 0
    }
}

public enum AgeMapEngine {
    public static func compute(store: NodeStore) -> AgeMapResult {
        let count = store.count
        guard count > 0 else {
            return AgeMapResult(months: [], busiestMonth: nil, years: [], bigAndUntouched: [], maxMonthBytes: 0)
        }

        let now = Int32(Date().timeIntervalSince1970)
        let oneYearSecs: Int32 = 31_536_000
        let fortyMBSecs: Int64 = 40 * 1024 * 1024

        // Key: (year * 100 + month) -> (bytes, files)
        var monthMap: [Int: (bytes: Int64, files: Int)] = [:]
        monthMap.reserveCapacity(256)

        var bigUntouched: [BigAndUntouchedItem] = []
        bigUntouched.reserveCapacity(100)

        var timeVal: time_t = 0
        var tmStruct = tm()

        let currentYear = Calendar.current.component(.year, from: Date())
        let minYear = currentYear - 6

        for i in 1..<count {
            if store.isDir(i) { continue }
            let alloc = store.allocated[i]
            let mtimeSec = store.mtime[i]
            guard mtimeSec > 0 else { continue }

            // Big & Untouched (> 40 MB and mtime > 1 year)
            if alloc >= fortyMBSecs && (now - mtimeSec >= oneYearSecs) {
                let name = store.name(i)
                let path = store.path(i)
                let mtimeDate = Date(timeIntervalSince1970: TimeInterval(mtimeSec))
                let days = Int((now - mtimeSec) / 86400)
                bigUntouched.append(BigAndUntouchedItem(nodeIndex: i, name: name, path: path, size: alloc, mtime: mtimeDate, daysUntouched: days))
            }

            // Extract year and month using fast POSIX gmtime_r
            timeVal = time_t(mtimeSec)
            gmtime_r(&timeVal, &tmStruct)
            let year = Int(tmStruct.tm_year) + 1900
            let month = Int(tmStruct.tm_mon) + 1

            // Limit heatmap tracking to reasonable recent window
            guard year >= minYear && year <= currentYear + 1 else { continue }

            let key = year * 100 + month
            if let cur = monthMap[key] {
                monthMap[key] = (cur.bytes + alloc, cur.files + 1)
            } else {
                monthMap[key] = (alloc, 1)
            }
        }

        // Convert to sorted MonthBucket array
        var buckets: [MonthBucket] = []
        var maxBytes: Int64 = 0
        var busiest: MonthBucket? = nil

        var allYears = Set<Int>()
        for y in minYear...currentYear {
            allYears.insert(y)
            for m in 1...12 {
                let key = y * 100 + m
                let data = monthMap[key] ?? (0, 0)
                let bucket = MonthBucket(year: y, month: m, bytes: data.bytes, fileCount: data.files)
                buckets.append(bucket)
                if data.bytes > maxBytes {
                    maxBytes = data.bytes
                    busiest = bucket
                }
            }
        }

        let sortedYears = Array(allYears).sorted(by: >)
        bigUntouched.sort { $0.size > $1.size }

        return AgeMapResult(
            months: buckets,
            busiestMonth: busiest,
            years: sortedYears,
            bigAndUntouched: Array(bigUntouched.prefix(100)),
            maxMonthBytes: maxBytes
        )
    }
}

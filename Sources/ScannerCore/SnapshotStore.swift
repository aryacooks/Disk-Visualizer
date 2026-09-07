import Compression
import Foundation

public struct SnapshotMeta: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let rootPath: String
    public let date: Date
    public let totalBytes: Int64
    public let fileCount: Int
    public let dirCount: Int
    public var label: String

    public var displayName: String {
        if rootPath == NSHomeDirectory() { return "Home" }
        if rootPath == "/" { return "Macintosh HD" }
        return (rootPath as NSString).lastPathComponent
    }
}

/// A saved scan is just the flat arena written to disk.
///
/// This is why the arena shape from §2 pays off twice: the same layout that
/// makes scanning fast makes a snapshot a near-free `write()`, and makes
/// diffing two scans a merge over sorted paths rather than a tree walk.
/// It also means the app can show your last scan instantly at launch instead
/// of re-reading the disk every time you open it.
public enum SnapshotStore {

    private static let magic: UInt32 = 0x44_42_53_31   // "DBS1"

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("DiskBuddyChecker/Snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: Save

    @discardableResult
    public static func save(store: NodeStore, rootPath: String,
                            label: String = "") throws -> SnapshotMeta {
        let id = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let meta = SnapshotMeta(id: id, rootPath: rootPath, date: Date(),
                                totalBytes: store.subtree.first ?? 0,
                                fileCount: Int(store.subtreeFiles.first ?? 0),
                                dirCount: Int(store.subtreeDirs.first ?? 0),
                                label: label)

        var body = Data()
        body.reserveCapacity(store.count * 48 + store.names.count)
        appendU32(&body, magic)
        appendU32(&body, UInt32(store.count))
        appendU32(&body, UInt32(store.names.count))

        append(&body, store.parent); append(&body, store.childStart); append(&body, store.childCount)
        append(&body, store.nameOff); append(&body, store.nameLen)
        append(&body, store.logical); append(&body, store.allocated); append(&body, store.subtree)
        append(&body, store.subtreeLogical); append(&body, store.subtreeCompressed)
        append(&body, store.subtreeFiles); append(&body, store.subtreeDirs)
        append(&body, store.mtime); append(&body, store.crtime)
        append(&body, store.flags); append(&body, store.names)

        let compressed = compress(body) ?? body
        try compressed.write(to: directory.appendingPathComponent("\(id).dbsnap"))
        let json = try JSONEncoder().encode(meta)
        try json.write(to: directory.appendingPathComponent("\(id).json"))
        return meta
    }

    // MARK: Load

    public static func list() -> [SnapshotMeta] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil) else { return [] }
        var out: [SnapshotMeta] = []
        for f in files where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f),
               let m = try? JSONDecoder().decode(SnapshotMeta.self, from: d) {
                out.append(m)
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    public static func load(_ id: String) -> NodeStore? {
        let url = directory.appendingPathComponent("\(id).dbsnap")
        guard let raw = try? Data(contentsOf: url) else { return nil }
        let data = decompress(raw) ?? raw
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> NodeStore? in
            var off = 0
            func u32() -> UInt32 {
                defer { off += 4 }
                return buf.loadUnaligned(fromByteOffset: off, as: UInt32.self)
            }
            guard buf.count > 12, u32() == magic else { return nil }
            let n = Int(u32()), nameBytes = Int(u32())

            func arr<T>(_ count: Int, _ type: T.Type) -> [T] {
                let bytes = count * MemoryLayout<T>.size
                guard off + bytes <= buf.count else { return [] }
                let out = [T](unsafeUninitializedCapacity: count) { dst, filled in
                    memcpy(dst.baseAddress!, buf.baseAddress! + off, bytes)
                    filled = count
                }
                off += bytes
                return out
            }

            let parent = arr(n, Int32.self), cs = arr(n, Int32.self), cc = arr(n, Int32.self)
            let nOff = arr(n, UInt32.self), nLen = arr(n, UInt16.self)
            let logical = arr(n, Int64.self), alloc = arr(n, Int64.self), sub = arr(n, Int64.self)
            let subL = arr(n, Int64.self), subC = arr(n, Int64.self)
            let subF = arr(n, Int32.self), subD = arr(n, Int32.self)
            let mt = arr(n, Int32.self), ct = arr(n, Int32.self)
            let fl = arr(n, UInt8.self), names = arr(nameBytes, UInt8.self)

            guard parent.count == n, names.count == nameBytes else { return nil }
            return NodeStore(parent: parent, childStart: cs, childCount: cc,
                             nameOff: nOff, nameLen: nLen,
                             logical: logical, allocated: alloc, subtree: sub,
                             subtreeLogical: subL, subtreeCompressed: subC,
                             subtreeFiles: subF, subtreeDirs: subD,
                             mtime: mt, crtime: ct, flags: fl, names: names)
        }
    }

    public static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).dbsnap"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }

    public static func rename(_ id: String, to label: String) {
        let url = directory.appendingPathComponent("\(id).json")
        guard let d = try? Data(contentsOf: url),
              var m = try? JSONDecoder().decode(SnapshotMeta.self, from: d) else { return }
        m.label = label
        if let out = try? JSONEncoder().encode(m) { try? out.write(to: url) }
    }

    // MARK: Bytes

    private static func appendU32(_ d: inout Data, _ v: UInt32) {
        withUnsafeBytes(of: v) { d.append(contentsOf: $0) }
    }

    private static func append<T>(_ d: inout Data, _ a: [T]) {
        a.withUnsafeBytes { d.append(contentsOf: $0) }
    }

    private static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let cap = data.count + 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(dst, cap,
                                      src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                      data.count, nil, COMPRESSION_LZFSE)
        }
        guard n > 0 else { return nil }
        var out = Data()
        appendU32(&out, 0x4C_5A_46_53)              // "LZFS"
        appendU32(&out, UInt32(data.count))
        out.append(dst, count: n)
        return out
    }

    private static func decompress(_ data: Data) -> Data? {
        guard data.count > 8 else { return nil }
        let tag = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard tag == 0x4C_5A_46_53 else { return nil }
        let size = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { src -> Int in
            let base = src.baseAddress!.assumingMemoryBound(to: UInt8.self) + 8
            return compression_decode_buffer(dst, size, base, data.count - 8, nil, COMPRESSION_LZFSE)
        }
        guard n == size else { return nil }
        return Data(bytes: dst, count: n)
    }
}

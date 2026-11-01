#if canImport(Darwin)
import Darwin
import Foundation

/// Walks a folder or a volume and builds the map's tree. Reads whole directories at a time with `getattrlistbulk`, from
/// a few threads at once, because a Mac holds millions of files. It only reads names and sizes:
/// - symbolic links are not followed, and other volumes mounted inside are not entered (but firmlinks are: on a Mac's
///   `/`, `/Users` and friends really live on the Data volume);
/// - a file with several hard links counts once;
/// - sizes are bytes on disk, so files kept only in the cloud count as nothing, and nothing is downloaded to look at it.
///
/// Memory stays small however many files there are. A file only gets a node when it is big enough to matter, and a
/// finished folder drops whatever is too small to see compared with what has been found so far; opening such a folder
/// scans it again.
public final class DiskScanner {
    public struct Progress: Equatable {
        public var files = 0
        public var folders = 0
        public var bytes: Int64 = 0
        public var unreadable = 0
        public var current = ""
    }

    private struct Work {
        let node: DiskNode
        let path: String
    }

    private struct LinkKey: Hashable {
        let device: Int32
        let file: UInt64
    }

    /// A file smaller than this never gets a node of its own.
    private static let smallestFile: Int64 = 64 << 10
    /// Keep a folder's contents when the folder is at least this share of everything found so far…
    private static let keptShare: Int64 = 40_000
    /// …or at least this big, so that small scans keep their detail.
    private static let smallestFolder: Int64 = 1 << 20

    private let rootPath: String
    private let rootName: String
    private let threads: Int
    private let lock = NSCondition()
    private var stack: [Work] = []
    private var active = 0
    private var cancelled = false
    private var counters = Progress()
    private var links = Set<LinkKey>()
    private var finished = false

    public init(path: String, name: String? = nil, threads: Int? = nil) {
        // The real place, not a link to it: the walk starts there, and what may be removed is judged by real paths.
        let real = realpath(path, nil)
        defer { free(real) }
        let resolved = real.map { String(cString: $0) } ?? path
        rootPath = resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
        rootName = name ?? (rootPath as NSString).lastPathComponent
        self.threads = max(1, threads ?? min(8, ProcessInfo.processInfo.activeProcessorCount))
    }

    public var progress: Progress {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.broadcast()
        lock.unlock()
    }

    /// Blocks until the walk is over. nil when it was cancelled or the folder cannot be read at all.
    public func run() -> DiskNode? {
        let root = DiskNode(name: rootName, kind: .folder, basePath: rootPath)
        stack = [Work(node: root, path: rootPath)]
        DispatchQueue.concurrentPerform(iterations: threads) { _ in worker() }
        lock.lock()
        defer { lock.unlock() }
        if cancelled || (root.isUnreadable && root.children.isEmpty) { return nil }
        return root
    }

    private func worker() {
        // Listing a folder that lives in the cloud would fetch it: this thread looks at what is on the disk only.
        let policy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if policy >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, policy) } }
        let capacity = 512 << 10
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        while let work = next() {
            list(work, buffer: buffer, capacity: capacity)
        }
    }

    private func next() -> Work? {
        lock.lock()
        defer { lock.unlock() }
        while stack.isEmpty && active > 0 && !cancelled { lock.wait() }
        guard !cancelled, let work = stack.popLast() else {
            lock.broadcast()
            return nil
        }
        active += 1
        return work
    }

    /// Bytes a folder must reach to keep its contents, given what has been found so far. Grows with the scan.
    private func keptFolderBytes(found: Int64) -> Int64 { max(DiskScanner.smallestFolder, found / DiskScanner.keptShare) }

    private func list(_ work: Work, buffer: UnsafeMutableRawPointer, capacity: Int) {
        let node = work.node
        var subfolders: [Work] = []
        var files = 0
        var bytes: Int64 = 0
        var smallFiles = 0
        var smallBytes: Int64 = 0
        var newest = 0.0
        var unreadable = false

        let descriptor = open(work.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            unreadable = true
        } else {
            defer { close(descriptor) }
            var request = attrlist()
            request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            request.commonattr = attrgroup_t(bitPattern: Int32(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)) | attrgroup_t(ATTR_CMN_ERROR)
                | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
                | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
            request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
            request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
            let base = work.path.hasSuffix("/") ? work.path : work.path + "/"

            reading: while true {
                let count = getattrlistbulk(descriptor, &request, buffer, capacity, 0)
                if count < 0 { unreadable = true; break }
                if count == 0 { break }
                var entry = buffer
                for _ in 0..<count {
                    let item = Entry(entry)
                    entry += item.length
                    guard item.error == 0 else { continue }
                    newest = max(newest, item.modified)
                    switch item.type {
                    case Entry.directory:
                        // Mount points lead to other volumes; a dataless folder is only in the cloud.
                        if item.mountStatus & Entry.mountPointBits != 0 || item.flags & Entry.dataless != 0 { continue }
                        let folder = DiskNode(name: item.name, kind: .folder, modified: item.modified)
                        node.add(folder)
                        subfolders.append(Work(node: folder, path: base + folder.name))
                    default:
                        if item.linkCount > 1 {
                            let key = LinkKey(device: item.device, file: item.fileID)
                            lock.lock()
                            let first = links.insert(key).inserted
                            lock.unlock()
                            guard first else { continue }
                        }
                        files += 1
                        bytes += item.allocated
                        if item.allocated >= DiskScanner.smallestFile {
                            node.add(DiskNode(name: item.name, kind: .file, size: item.allocated, fileCount: 1, modified: item.modified))
                        } else {
                            smallFiles += 1
                            smallBytes += item.allocated
                        }
                    }
                }
                if isCancelled { break reading }
            }
        }

        node.modified = max(node.modified, newest)
        node.size = bytes
        node.fileCount = files
        node.isUnreadable = unreadable
        if smallFiles > 0 { node.add(DiskNode(name: DiskNode.smallerName(smallFiles), kind: .smaller, size: smallBytes, fileCount: smallFiles, modified: newest)) }

        lock.lock()
        node.pending = subfolders.count
        counters.files += files
        counters.folders += 1
        counters.bytes += bytes
        counters.current = work.path
        if unreadable { counters.unreadable += 1 }
        stack.append(contentsOf: subfolders)
        active -= 1
        if !subfolders.isEmpty || active == 0 { lock.broadcast() }
        lock.unlock()
        if subfolders.isEmpty { seal(node) }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// A folder and everything in it are done: tidy it, tell its parent, and go on upward while that finishes parents.
    private func seal(_ start: DiskNode) {
        var node = start
        while true {
            guard let parent = node.parent else {
                node.trim()
                return
            }
            lock.lock()
            let found = counters.bytes
            lock.unlock()
            if node.isFolder, node.size < keptFolderBytes(found: found) {
                // Too small to see in anything but its own view: opening it scans it again.
                node.isCollapsed = !node.children.isEmpty || node.fileCount > 0
                node.children = []
            } else {
                node.trim()
            }
            lock.lock()
            parent.size += node.size
            parent.fileCount += node.fileCount
            parent.modified = max(parent.modified, node.modified)
            parent.pending -= 1
            let ready = parent.pending == 0
            lock.unlock()
            guard ready else { return }
            node = parent
        }
    }

    /// One entry of a `getattrlistbulk` buffer: the length, the set of attributes returned, then those attributes in the
    /// order of their bits, each at a 4-byte boundary (so 8-byte values may sit unaligned).
    private struct Entry {
        static let directory: UInt32 = 2
        static let dataless: UInt32 = 0x4000_0000
        /// DIR_MNTSTATUS_MNTPT | DIR_MNTSTATUS_TRIGGER
        static let mountPointBits: UInt32 = 0x1 | 0x2

        var length = 0
        var error: UInt32 = 0
        private var namePointer: UnsafePointer<CChar>?
        var device: Int32 = 0
        var type: UInt32 = 0
        var modified = 0.0
        var flags: UInt32 = 0
        var fileID: UInt64 = 0
        var mountStatus: UInt32 = 0
        var linkCount: UInt32 = 1
        var allocated: Int64 = 0

        /// Decoded only for what gets a node: most files never need their name.
        var name: String { namePointer.map { String(cString: $0) } ?? "" }

        init(_ raw: UnsafeMutableRawPointer) {
            var field = UnsafeRawPointer(raw)
            length = Int(Entry.read32(field))
            field += 4
            let common = Entry.read32(field)
            let directory = Entry.read32(field + 8)
            let file = Entry.read32(field + 12)
            field += MemoryLayout<attribute_set_t>.size
            if common & UInt32(ATTR_CMN_ERROR) != 0 {
                error = Entry.read32(field)
                field += 4
            }
            if common & UInt32(ATTR_CMN_NAME) != 0 {
                let offset = Int(Int32(bitPattern: Entry.read32(field)))
                namePointer = (field + offset).assumingMemoryBound(to: CChar.self)
                field += MemoryLayout<attrreference_t>.size
            }
            if common & UInt32(ATTR_CMN_DEVID) != 0 {
                device = Int32(bitPattern: Entry.read32(field))
                field += 4
            }
            if common & UInt32(ATTR_CMN_OBJTYPE) != 0 {
                type = Entry.read32(field)
                field += 4
            }
            if common & UInt32(ATTR_CMN_MODTIME) != 0 {
                modified = Double(Int64(bitPattern: Entry.read64(field)))
                field += MemoryLayout<timespec>.size
            }
            if common & UInt32(ATTR_CMN_FLAGS) != 0 {
                flags = Entry.read32(field)
                field += 4
            }
            if common & UInt32(ATTR_CMN_FILEID) != 0 {
                fileID = Entry.read64(field)
                field += 8
            }
            if directory & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 {
                mountStatus = Entry.read32(field)
                field += 4
            }
            if file & UInt32(ATTR_FILE_LINKCOUNT) != 0 {
                linkCount = Entry.read32(field)
                field += 4
            }
            if file & UInt32(ATTR_FILE_ALLOCSIZE) != 0 {
                allocated = Int64(bitPattern: Entry.read64(field))
            }
        }

        private static func read32(_ pointer: UnsafeRawPointer) -> UInt32 {
            var value: UInt32 = 0
            memcpy(&value, pointer, 4)
            return value
        }

        private static func read64(_ pointer: UnsafeRawPointer) -> UInt64 {
            var value: UInt64 = 0
            memcpy(&value, pointer, 8)
            return value
        }
    }
}
#endif

import Foundation

// MARK: - FileAttributes

/// 文件/目录属性快照。
struct FileAttributes: Sendable {
    /// 文件大小（字节）。目录大小为 0。
    let size: Int64

    /// 最后修改时间。
    let modificationDate: Date

    /// 创建时间（iOS 上通常与 modificationDate 相同）。
    let creationDate: Date

    /// 是否是目录。
    let isDirectory: Bool

    /// POSIX 权限位（如 0o755）。
    let permissions: Int16

    /// 是否为符号链接。
    let isSymlink: Bool

    /// 硬链接数。
    let linkCount: Int16

    /// 所有者 UID。
    let ownerUID: uid_t

    /// 所属组 GID。
    let ownerGID: gid_t
}

// MARK: - FileSystemError

/// 文件系统操作错误。
enum FileSystemError: Error, LocalizedError {
    /// 文件/目录不存在。
    case fileNotFound(path: String)

    /// 权限不足。
    case permissionDenied(path: String)

    /// 磁盘空间不足。
    case diskFull

    /// 路径已存在（创建时冲突）。
    case alreadyExists(path: String)

    /// 不是目录（对目录操作的路径指向了文件）。
    case notDirectory(path: String)

    /// 是目录（对文件操作的路径指向了目录）。
    case isDirectory(path: String)

    /// 操作被中断。
    case interrupted

    /// IO 错误，携带 errno 值。
    case ioError(errno: Int32)

    /// 路径为空。
    case emptyPath

    /// 缓冲区溢出。
    case bufferOverflow

    /// 通用系统错误。
    case systemError(errno: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let p):      return "文件未找到: \(p)"
        case .permissionDenied(let p):  return "权限不足: \(p)"
        case .diskFull:                 return "磁盘空间不足"
        case .alreadyExists(let p):     return "路径已存在: \(p)"
        case .notDirectory(let p):      return "不是目录: \(p)"
        case .isDirectory(let p):       return "是目录: \(p)"
        case .interrupted:              return "操作被中断"
        case .ioError(let e):           return "IO 错误，errno: \(e)"
        case .emptyPath:                return "路径为空"
        case .bufferOverflow:           return "缓冲区溢出"
        case .systemError(let e, let m): return "系统错误 [errno=\(e)]: \(m)"
        }
    }

    // MARK: - Factory from errno

    /// 从 errno 值创建对应的 FileSystemError。
    static func fromErrno(_ err: Int32, path: String = "") -> FileSystemError {
        switch err {
        case ENOENT:  return .fileNotFound(path: path)
        case EACCES:  return .permissionDenied(path: path)
        case ENOSPC:  return .diskFull
        case EEXIST:  return .alreadyExists(path: path)
        case ENOTDIR: return .notDirectory(path: path)
        case EISDIR:  return .isDirectory(path: path)
        case EINTR:   return .interrupted
        case EIO:     return .ioError(errno: err)
        default:      return .systemError(errno: err, message: String(cString: strerror(err)))
        }
    }
}

// MARK: - FileSystemAccess

/// 无沙盒文件系统操作包装器。
///
/// 全部使用 POSIX C API（`open`/`read`/`write`/`close`/`unlink`/`mkdir`/
/// `rename`/`opendir`/`readdir`/`stat`/`lstat`），不经过 Foundation
/// `FileManager`，确保完全绕过 iOS 沙盒路径检查。
///
/// - Important: 需要 `no-sandbox` entitlement（TrollStore 已配置）。
///   路径空间是 **iOS 原生文件系统**（如 `/var/mobile/Documents/`、
///   `/tmp/`、`/var/root/`），**不是** ish Linux guest 路径。
///
/// 使用示例：
/// ```swift
/// // 写入文件
/// try FileSystemAccess.writeFile(
///     at: "/tmp/agentbox-test.txt",
///     data: "Hello World".data(using: .utf8)!,
///     createIntermediate: true
/// )
///
/// // 读取文件
/// let data = try FileSystemAccess.readFile(at: "/tmp/agentbox-test.txt")
/// print(String(data: data, encoding: .utf8)!) // "Hello World"
/// ```
enum FileSystemAccess {

    // MARK: - Constants

    /// 默认文件创建权限：rw-r--r-- (0o644)
    private static let defaultFileMode: mode_t = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH

    /// 默认目录创建权限：rwxr-xr-x (0o755)
    private static let defaultDirMode: mode_t = S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH

    /// 读写缓冲区大小。
    private static let bufferSize: Int = 65536 // 64KB

    // MARK: - Basic I/O

    /// 读取文件全部内容。
    ///
    /// - Parameter path: 文件绝对路径。
    /// - Returns: 文件原始数据。
    /// - Throws: ``FileSystemError``。
    static func readFile(at path: String) throws -> Data {
        guard !path.isEmpty else { throw FileSystemError.emptyPath }

        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw FileSystemError.fromErrno(errno, path: path)
        }
        defer { close(fd) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            let bytesRead = read(fd, &buffer, bufferSize)
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw FileSystemError.fromErrno(errno, path: path)
            }
            if bytesRead == 0 { break } // EOF
            data.append(buffer, count: bytesRead)
        }

        return data
    }

    /// 写入数据到文件。文件不存在则创建，已存在则覆盖。
    ///
    /// - Parameters:
    ///   - path: 文件绝对路径。
    ///   - data: 要写入的数据。
    ///   - createIntermediate: 是否自动创建中间目录。默认 `true`。
    /// - Throws: ``FileSystemError``。
    static func writeFile(
        at path: String,
        data: Data,
        createIntermediate: Bool = true
    ) throws {
        guard !path.isEmpty else { throw FileSystemError.emptyPath }

        // Auto-create parent directories if requested
        if createIntermediate {
            let parentPath = (path as NSString).deletingLastPathComponent
            if !parentPath.isEmpty && parentPath != "/" {
                try? createDirectory(at: parentPath, withIntermediate: true)
            }
        }

        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, defaultFileMode)
        guard fd >= 0 else {
            throw FileSystemError.fromErrno(errno, path: path)
        }
        defer { close(fd) }

        // Write all data
        var bytesWritten = 0
        let totalBytes = data.count

        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let baseAddress = ptr.baseAddress else {
                throw FileSystemError.ioError(errno: EFAULT)
            }

            while bytesWritten < totalBytes {
                let remaining = totalBytes - bytesWritten
                let chunkSize = min(remaining, bufferSize)
                let written = write(fd, baseAddress.advanced(by: bytesWritten), chunkSize)

                if written < 0 {
                    if errno == EINTR { continue }
                    throw FileSystemError.fromErrno(errno, path: path)
                }
                bytesWritten += written
            }
        }
    }

    /// 删除文件。
    ///
    /// - Parameter path: 文件绝对路径。
    /// - Throws: ``FileSystemError``。
    static func deleteFile(at path: String) throws {
        guard !path.isEmpty else { throw FileSystemError.emptyPath }

        let result = unlink(path)
        if result != 0 {
            throw FileSystemError.fromErrno(errno, path: path)
        }
    }

    /// 检查路径是否存在（不区分文件/目录/符号链接）。
    ///
    /// - Parameter path: 绝对路径。
    /// - Returns: `true` 如果路径存在。
    static func fileExists(at path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return access(path, F_OK) == 0
    }

    /// 检查路径是否指向目录。
    ///
    /// - Parameter path: 绝对路径。
    /// - Returns: `true` 如果是目录。
    static func isDirectory(at path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: - Directory Operations

    /// 创建目录。
    ///
    /// - Parameters:
    ///   - path: 目录绝对路径。
    ///   - withIntermediate: 是否自动创建中间目录（类似 `mkdir -p`）。
    /// - Throws: ``FileSystemError``。
    static func createDirectory(
        at path: String,
        withIntermediate: Bool = true
    ) throws {
        guard !path.isEmpty else { throw FileSystemError.emptyPath }

        if withIntermediate {
            // Recursively create parent directories
            let components = (path as NSString).pathComponents
            var currentPath = ""

            for component in components {
                if component == "/" {
                    currentPath = "/"
                    continue
                }
                currentPath = (currentPath as NSString).appendingPathComponent(component)

                if fileExists(at: currentPath) {
                    if !isDirectory(at: currentPath) {
                        throw FileSystemError.notDirectory(path: currentPath)
                    }
                    continue
                }

                let result = mkdir(currentPath, defaultDirMode)
                if result != 0 {
                    throw FileSystemError.fromErrno(errno, path: currentPath)
                }
            }
        } else {
            let result = mkdir(path, defaultDirMode)
            if result != 0 {
                throw FileSystemError.fromErrno(errno, path: path)
            }
        }
    }

    /// 列出目录内容（仅文件名，不含 `.` 和 `..`）。
    ///
    /// - Parameter path: 目录绝对路径。
    /// - Returns: 文件名数组（未排序）。
    /// - Throws: ``FileSystemError``。
    static func listDirectory(at path: String) throws -> [String] {
        guard !path.isEmpty else { throw FileSystemError.emptyPath }

        guard let dir = opendir(path) else {
            throw FileSystemError.fromErrno(errno, path: path)
        }
        defer { closedir(dir) }

        var entries: [String] = []

        while true {
            // readdir is NOT thread-safe; but this function is called on a single thread
            guard let entry = readdir(dir) else { break }

            // d_name is a fixed-size C array of 256 chars; convert to String
            let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen)) {
                    String(cString: $0)
                }
            }

            // Skip . and ..
            if name != "." && name != ".." {
                entries.append(name)
            }
        }

        return entries
    }

    /// 递归删除目录及其所有内容。
    ///
    /// - Parameter path: 目录绝对路径。
    /// - Throws: ``FileSystemError``。
    static func deleteDirectory(at path: String) throws {
        guard !path.isEmpty else { throw FileSystemError.emptyPath }

        // Recursively delete children first
        let children = try listDirectory(at: path)
        for child in children {
            let childPath = (path as NSString).appendingPathComponent(child)
            if isDirectory(at: childPath) {
                try deleteDirectory(at: childPath)
            } else {
                try deleteFile(at: childPath)
            }
        }

        // Then remove the directory itself
        let result = rmdir(path)
        if result != 0 {
            throw FileSystemError.fromErrno(errno, path: path)
        }
    }

    // MARK: - Move / Copy

    /// 移动/重命名文件或目录。
    ///
    /// - Parameters:
    ///   - from: 源路径。
    ///   - to: 目标路径。
    /// - Throws: ``FileSystemError``。
    static func moveFile(from source: String, to destination: String) throws {
        guard !source.isEmpty, !destination.isEmpty else {
            throw FileSystemError.emptyPath
        }

        // Create destination parent if needed
        let destParent = (destination as NSString).deletingLastPathComponent
        if !destParent.isEmpty && destParent != "/" && !fileExists(at: destParent) {
            try createDirectory(at: destParent, withIntermediate: true)
        }

        let result = rename(source, destination)
        if result != 0 {
            throw FileSystemError.fromErrno(errno, path: source)
        }
    }

    /// 复制文件。
    ///
    /// 使用 `copyfile(3)` 系统调用（macOS/iOS 原生，高效）。
    ///
    /// - Parameters:
    ///   - from: 源路径。
    ///   - to: 目标路径。
    /// - Throws: ``FileSystemError``。
    static func copyFile(from source: String, to destination: String) throws {
        guard !source.isEmpty, !destination.isEmpty else {
            throw FileSystemError.emptyPath
        }

        // Create destination parent if needed
        let destParent = (destination as NSString).deletingLastPathComponent
        if !destParent.isEmpty && destParent != "/" && !fileExists(at: destParent) {
            try createDirectory(at: destParent, withIntermediate: true)
        }

        // Use copyfile(3) for efficient copying (handles CoW on APFS)
        let result = copyfile(source, destination, nil, UInt32(COPYFILE_ALL | COPYFILE_CLONE))
        if result != 0 {
            throw FileSystemError.fromErrno(errno, path: source)
        }
    }

    // MARK: - Attributes

    /// 获取路径的文件属性。
    ///
    /// - Parameter path: 文件或目录绝对路径。
    /// - Returns: ``FileAttributes``。
    /// - Throws: ``FileSystemError``。
    static func attributes(at path: String) throws -> FileAttributes {
        guard !path.isEmpty else { throw FileSystemError.emptyPath }

        var st = stat()
        let result = lstat(path, &st) // lstat to get symlink info
        if result != 0 {
            throw FileSystemError.fromErrno(errno, path: path)
        }

        let isSymlink = (st.st_mode & S_IFMT) == S_IFLNK
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR

        let modDate = Date(
            timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) +
                TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        let createDate = Date(
            timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec) +
                TimeInterval(st.st_birthtimespec.tv_nsec) / 1_000_000_000
        )

        return FileAttributes(
            size: st.st_size,
            modificationDate: modDate,
            creationDate: createDate,
            isDirectory: isDir,
            permissions: Int16(st.st_mode & 0o7777),
            isSymlink: isSymlink,
            linkCount: st.st_nlink,
            ownerUID: st.st_uid,
            ownerGID: st.st_gid
        )
    }

    // MARK: - Convenience Methods

    /// 将字符串写入文件（UTF-8 编码）。
    ///
    /// - Parameters:
    ///   - content: 要写入的字符串。
    ///   - path: 文件绝对路径。
    ///   - createIntermediate: 是否创建中间目录。
    /// - Throws: ``FileSystemError``。
    static func writeString(
        _ content: String,
        to path: String,
        createIntermediate: Bool = true
    ) throws {
        guard let data = content.data(using: .utf8) else {
            throw FileSystemError.ioError(errno: EINVAL)
        }
        try writeFile(at: path, data: data, createIntermediate: createIntermediate)
    }

    /// 读取文件为 UTF-8 字符串。
    ///
    /// - Parameter path: 文件绝对路径。
    /// - Returns: 文件内容字符串。
    /// - Throws: ``FileSystemError``。
    static func readString(at path: String) throws -> String {
        let data = try readFile(at: path)
        guard let string = String(data: data, encoding: .utf8) else {
            throw FileSystemError.systemError(
                errno: EILSEQ,
                message: "无法以 UTF-8 解码文件内容"
            )
        }
        return string
    }

    /// 获取文件大小（便捷方法）。
    ///
    /// - Parameter path: 文件绝对路径。
    /// - Returns: 文件大小（字节），路径不存在返回 nil。
    static func fileSize(at path: String) -> Int64? {
        guard let attrs = try? attributes(at: path) else { return nil }
        return attrs.size
    }

    /// 获取目录内容总大小（递归）。
    ///
    /// - Parameter path: 目录绝对路径。
    /// - Returns: 总大小（字节）。
    /// - Throws: ``FileSystemError``。
    static func directorySize(at path: String) throws -> Int64 {
        var total: Int64 = 0
        let children = try listDirectory(at: path)

        for child in children {
            let childPath = (path as NSString).appendingPathComponent(child)
            let attrs = try attributes(at: childPath)
            if attrs.isDirectory {
                total += try directorySize(at: childPath)
            } else {
                total += attrs.size
            }
        }

        return total
    }
}

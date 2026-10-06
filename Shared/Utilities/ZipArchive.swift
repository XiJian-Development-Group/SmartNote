import Foundation
import Compression

/// 跨平台 ZIP 归档读写。
///
/// macOS 侧沿用 `/usr/bin/ditto`（见 `BackupService`），行为与既有版本完全一致。
/// iOS 的 App 沙箱不允许派生进程（`Process` 不可用），因此这里用 Foundation +
/// `Compression` 直接读写 ZIP 容器，供 iOS 的备份/恢复与资料导入使用。
///
/// 只实现 ZIP 规范中实际会用到的子集：
/// - 方法 0（store）与方法 8（deflate）；
/// - 单个或多个磁盘条目；不支持符号链接与加密；
/// - 写入固定的时间戳，保证同样输入产生同样字节，便于校验备份。
enum ZipArchive {

    // MARK: - 错误

    enum ZipError: Error, LocalizedError {
        case notAZipFile
        case unsupportedFeature(String)
        case malformed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAZipFile: return "不是有效的 ZIP 文件"
            case .unsupportedFeature(let detail): return "不支持的 ZIP 特性：\(detail)"
            case .malformed(let detail): return "ZIP 结构损坏：\(detail)"
            case .writeFailed(let detail): return "ZIP 写入失败：\(detail)"
            }
        }
    }

    // MARK: - 写入

    /// 把 `sourceDirectory` 下的内容打包为 ZIP，返回归档数据。
    ///
    /// - Parameter includeRootName: 为 true 时保留源目录名本身作为顶层条目；
    ///   备份流程需要它，解压回来才和原目录结构一致。
    static func archive(directory sourceDirectory: URL, includeRootName: Bool = true) throws -> Data {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ZipError.malformed("源目录不存在：\(sourceDirectory.path)")
        }

        let rootName = sourceDirectory.lastPathComponent
        var entries: [(name: String, url: URL)] = []
        if includeRootName {
            entries.append((name: rootName + "/", url: sourceDirectory))
        }

        guard let walker = fm.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ZipError.malformed("无法枚举目录：\(sourceDirectory.path)")
        }

        let basePath = sourceDirectory.standardizedFileURL.path
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            guard values?.isRegularFile == true else { continue }

            // 条目名一律使用相对路径并以 "/" 分隔，遵循 ZIP 规范。
            let standardized = url.standardizedFileURL.path
            let relative = standardized == basePath
                ? rootName
                : relativePath(of: standardized, under: basePath, rootName: rootName)
            entries.append((name: relative, url: url))
        }

        // 按名称排序，使相同输入产生相同的归档字节。
        entries.sort { $0.name < $1.name }

        var output = Data()
        var centralDirectory = Data()
        var entryCount = 0

        // 固定 DOS 时间戳（1980-01-01 00:00:00），保证输出可复现。
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = 0x0021

        for entry in entries {
            let isDirectoryEntry = entry.name.hasSuffix("/")
            let payload: Data
            if isDirectoryEntry {
                payload = Data()
            } else {
                do {
                    payload = try Data(contentsOf: entry.url, options: .mappedIfSafe)
                } catch {
                    throw ZipError.writeFailed("无法读取 \(entry.url.path)：\(error.localizedDescription)")
                }
            }

            // 小文件直接 store，避免压缩开销大于收益；其余用 deflate。
            let (method, stored): (UInt16, Data) = payload.count < 128
                ? (0, payload)
                : (8, (try? deflate(payload)) ?? payload)

            let crc = CRC32.checksum(payload)
            let offset = UInt32(output.count)

            output.append(localHeader(name: entry.name, method: method, crc: crc,
                                     compressedSize: UInt32(stored.count),
                                     uncompressedSize: UInt32(payload.count),
                                     dosTime: dosTime, dosDate: dosDate))
            output.append(stored)

            centralDirectory.append(centralHeader(name: entry.name, method: method, crc: crc,
                                                  compressedSize: UInt32(stored.count),
                                                  uncompressedSize: UInt32(payload.count),
                                                  dosTime: dosTime, dosDate: dosDate,
                                                  localHeaderOffset: offset))
            entryCount += 1
        }

        guard entryCount > 0 else {
            throw ZipError.writeFailed("目录内没有可归档的文件")
        }

        let centralDirectoryOffset = UInt32(output.count)
        output.append(centralDirectory)

        // 结束记录：条目数集中放在 EOCD 里。
        var eocd = Data()
        eocd.zipAppendLE(UInt32(0x0605_4B50)) // 签名
        eocd.zipAppendLE(UInt16(0))          // 磁盘号
        eocd.zipAppendLE(UInt16(0))          // 中央目录起始磁盘号
        eocd.zipAppendLE(UInt16(entryCount))
        eocd.zipAppendLE(UInt16(entryCount))
        eocd.zipAppendLE(UInt32(centralDirectory.count))
        eocd.zipAppendLE(centralDirectoryOffset)
        eocd.zipAppendLE(UInt16(0))          // 注释长度
        output.append(eocd)

        return output
    }

    // MARK: - 解压

    /// 解压 ZIP 数据到 `destinationDirectory`。
    ///
    /// 逐条目解析中央目录，只写出普通文件与目录；对 `../`、绝对路径等
    /// 逃逸目标目录的条目直接报错，避免 Zip-Slip。
    @discardableResult
    static func extract(_ data: Data, into destinationDirectory: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let destinationPath = destinationDirectory.standardizedFileURL.path
        let eocd = try endOfCentralDirectoryOffset(in: data)
        let recordCount = Int(try data.zipReadLE16(at: eocd + 10))
        let directoryOffset = Int(try data.zipReadLE32(at: eocd + 16))

        var directoryCursor = directoryOffset
        var written = 0

        for _ in 0..<recordCount {
            try expectSignature(0x0201_4B50, at: directoryCursor, in: data)

            let method = try data.zipReadLE16(at: directoryCursor + 10)
            let crc = try data.zipReadLE32(at: directoryCursor + 16)
            let compressedSize = try Int(data.zipReadLE32(at: directoryCursor + 20))
            let uncompressedSize = try Int(data.zipReadLE32(at: directoryCursor + 24))
            let nameLength = try Int(data.zipReadLE16(at: directoryCursor + 28))
            let extraLength = try Int(data.zipReadLE16(at: directoryCursor + 30))
            let commentLength = try Int(data.zipReadLE16(at: directoryCursor + 32))
            let localHeaderOffset = try Int(data.zipReadLE32(at: directoryCursor + 42))

            let nameBytes = try data.subdata(in: directoryCursor + 46 ..< directoryCursor + 46 + nameLength)
            guard let name = String(data: nameBytes, encoding: .utf8) else {
                throw ZipError.malformed("条目名不是合法 UTF-8")
            }

            // 记录末尾占用字节，推进游标。
            directoryCursor += 46 + nameLength + extraLength + commentLength

            guard method == 0 || method == 8 else {
                throw ZipError.unsupportedFeature("压缩方法 \(method)")
            }

            let isDirectory = name.hasSuffix("/")
            guard !isDirectory else { continue }

            // 校验目标路径仍在 destinationDirectory 之内。
            let safeName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !safeName.isEmpty,
                  !safeName.split(separator: "/").contains("..") else {
                throw ZipError.malformed("非法条目路径：\(name)")
            }

            let target = destinationDirectory.appendingPathComponent(safeName)
            guard target.standardizedFileURL.path.hasPrefix(destinationPath + "/") else {
                throw ZipError.malformed("条目路径逃逸目标目录：\(name)")
            }

            // 解析本地文件头，跳过它自带的可变长字段。
            try expectSignature(0x0403_4B50, at: localHeaderOffset, in: data)
            let localNameLength = try Int(data.zipReadLE16(at: localHeaderOffset + 26))
            let localExtraLength = try Int(data.zipReadLE16(at: localHeaderOffset + 28))
            let payloadStart = localHeaderOffset + 30 + localNameLength + localExtraLength
            guard payloadStart + compressedSize <= data.count else {
                throw ZipError.malformed("条目数据越界：\(name)")
            }

            let raw = try data.subdata(in: payloadStart ..< payloadStart + compressedSize)
            let payload: Data
            switch method {
            case 0: payload = raw
            case 8: payload = try inflate(raw, expectedSize: uncompressedSize)
            default: throw ZipError.unsupportedFeature("压缩方法 \(method)")
            }

            guard payload.count == uncompressedSize else {
                throw ZipError.malformed("解压后大小不符：\(name)")
            }
            guard CRC32.checksum(payload) == crc else {
                throw ZipError.malformed("CRC 校验失败：\(name)")
            }

            try fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: target, options: .atomic)
            written += 1
        }

        return written
    }

    // MARK: - DEFLATE

    /// 原始 DEFLATE 压缩。`COMPRESSION_ZLIB` 不写入 zlib 头/校验，正好对应
    /// ZIP 方法 8 要求的裸 deflate 流。
    static func deflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        // deflate 最坏可能膨胀到原始大小加上少量开销，留出余量避免反复扩容。
        let capacity = data.count + (data.count / 16) + 64
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { raw -> Int in
            guard let destination = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                destination, capacity,
                data.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress! },
                data.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard written > 0 else {
            throw ZipError.writeFailed("deflate 压缩未产出数据")
        }
        output.removeSubrange(written ..< output.count)
        return output
    }

    /// 原始 DEFLATE 解压。
    static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        // 用归档声明的原始大小作为输出缓冲；这是 ZIP 里权威的尺寸字段。
        var output = Data(count: max(expectedSize, 1))
        let written = output.withUnsafeMutableBytes { raw -> Int in
            guard let destination = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                destination, max(expectedSize, 1),
                data.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress! },
                data.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard written == expectedSize else {
            throw ZipError.malformed("解压字节数不符（期望 \(expectedSize)，实际 \(written)）")
        }
        return written == output.count ? output : output.prefix(written)
    }

    // MARK: - ZIP 结构

    private static func endOfCentralDirectoryOffset(in data: Data) throws -> Int {
        // EOCD 长度 22 字节，加上最多 65535 字节的注释。
        let minimum = 22
        guard data.count >= minimum else { throw ZipError.notAZipFile }

        let searchFloor = max(0, data.count - minimum - 0xFFFF)
        var offset = data.count - minimum
        while offset >= searchFloor {
            if try data.zipReadLE32(at: offset) == 0x0605_4B50 { return offset }
            guard offset > searchFloor else { break }
            offset -= 1
        }
        throw ZipError.notAZipFile
    }

    private static func expectSignature(_ signature: UInt32, at offset: Int, in data: Data) throws {
        guard offset >= 0, offset + 4 <= data.count, try data.zipReadLE32(at: offset) == signature else {
            throw ZipError.malformed("记录签名不匹配，偏移 \(offset)")
        }
    }

    private static func localHeader(
        name: String, method: UInt16, crc: UInt32,
        compressedSize: UInt32, uncompressedSize: UInt32,
        dosTime: UInt16, dosDate: UInt16
    ) -> Data {
        var data = Data()
        data.zipAppendLE(UInt32(0x0403_4B50))   // 签名
        data.zipAppendLE(UInt16(20))             // 解压所需版本 2.0
        data.zipAppendLE(UInt16(0))              // 通用标志位
        data.zipAppendLE(method)
        data.zipAppendLE(dosTime)
        data.zipAppendLE(dosDate)
        data.zipAppendLE(crc)
        data.zipAppendLE(compressedSize)
        data.zipAppendLE(uncompressedSize)
        data.zipAppendLE(UInt16(name.utf8.count))
        data.zipAppendLE(UInt16(0))              // 额外字段长度
        data.append(contentsOf: Array(name.utf8))
        return data
    }

    private static func centralHeader(
        name: String, method: UInt16, crc: UInt32,
        compressedSize: UInt32, uncompressedSize: UInt32,
        dosTime: UInt16, dosDate: UInt16,
        localHeaderOffset: UInt32
    ) -> Data {
        var data = Data()
        data.zipAppendLE(UInt32(0x0201_4B50))   // 签名
        data.zipAppendLE(UInt16(0x031E))         // 创建方：Unix / 3.0
        data.zipAppendLE(UInt16(20))
        data.zipAppendLE(UInt16(0))
        data.zipAppendLE(method)
        data.zipAppendLE(dosTime)
        data.zipAppendLE(dosDate)
        data.zipAppendLE(crc)
        data.zipAppendLE(compressedSize)
        data.zipAppendLE(uncompressedSize)
        data.zipAppendLE(UInt16(name.utf8.count))
        data.zipAppendLE(UInt16(0))              // 额外字段长度
        data.zipAppendLE(UInt16(0))              // 注释长度
        data.zipAppendLE(UInt16(0))              // 起始磁盘号
        data.zipAppendLE(UInt16(0))              // 内部属性
        data.zipAppendLE(UInt32(0x81A4_0000))   // 外部属性：0644
        data.zipAppendLE(localHeaderOffset)
        data.append(contentsOf: Array(name.utf8))
        return data
    }

    private static func relativePath(of path: String, under base: String, rootName: String) -> String {
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return path }
        return rootName + "/" + String(path.dropFirst(prefix.count))
    }

    }

// MARK: - 小端读写

/// ZIP 的所有数值字段都是小端序。
private extension Data {
    mutating func zipAppendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        // 显式使用全局函数：在 `Data` 扩展内，无前缀的 `withUnsafeBytes`
        // 会解析到实例方法而非 Swift 的全局函数。
        Swift.withUnsafeBytes(of: &little) { buffer in
            append(contentsOf: buffer)
        }
    }

    func zipReadLE16(at offset: Int) throws -> UInt16 {
        try zipReadLE(at: offset, as: UInt16.self)
    }

    func zipReadLE32(at offset: Int) throws -> UInt32 {
        try zipReadLE(at: offset, as: UInt32.self)
    }

    /// 读取偏移处的小端定长整数。
    ///
    /// 逐字节组装，避免依赖 `UnsafeRawBufferPointer` 的指针算术；
    /// ZIP 头部字段都很小（<= 4 字节），逐字节读取的开销可以忽略。
    func zipReadLE<T: FixedWidthInteger>(at offset: Int, as type: T.Type) throws -> T {
        let byteCount = MemoryLayout<T>.size
        guard offset >= 0, offset + byteCount <= count else {
            throw ZipArchive.ZipError.malformed("读取越界，偏移 \(offset)")
        }

        var value: UInt64 = 0
        for index in 0..<byteCount {
            // 低位在前：第 0 个字节是最低有效字节。
            value |= UInt64(self[startIndex + offset + index]) << (8 * UInt64(index))
        }
        return T(truncatingIfNeeded: value)
    }
}

// MARK: - CRC32

/// ZIP 要求的 CRC-32（IEEE 802.3 多项式 0xEDB88320）。
///
/// Foundation 没有公开实现，因此这里用查表法一次性算出 256 项表。
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1 == 1) ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in raw {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
            return crc ^ 0xFFFF_FFFF
        }
    }
}

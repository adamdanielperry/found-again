import XCTest
@testable import DataRecoverCore

final class GuardAndPathTests: XCTestCase {
    func testDeviceFilterAllowsTheBuiltInSDReader() {
        let card = DeviceFacts(identifier: "disk4", wholeDisk: true, virtual: false, removableOrExternal: true, bus: "Secure Digital", internalDisk: false, startup: false)
        XCTAssertTrue(DeviceGuard.isRecoverable(card))
    }

    func testDeviceFilterAllowsACardInTheMacsOwnSDSlot() {
        // MacBook Pro SD slots report as internal, with removable media.
        let card = DeviceFacts(identifier: "disk4", wholeDisk: true, virtual: false, removableOrExternal: true, bus: "Secure Digital", internalDisk: true, startup: false)
        XCTAssertTrue(DeviceGuard.isRecoverable(card))
    }

    func testDeviceFilterAllowsAnExternalThunderboltDrive() {
        let drive = DeviceFacts(identifier: "disk6", wholeDisk: true, virtual: false, removableOrExternal: true, bus: "PCI-Express", internalDisk: false, startup: false)
        XCTAssertTrue(DeviceGuard.isRecoverable(drive))
    }

    func testDeviceFilterRejectsTheInternalSSD() {
        let disk = DeviceFacts(identifier: "disk0", wholeDisk: true, virtual: false, removableOrExternal: false, bus: "Apple Fabric", internalDisk: true, startup: false)
        XCTAssertFalse(DeviceGuard.isRecoverable(disk))
    }

    func testDeviceFilterRejectsTheStartupDiskEvenWhenExternal() {
        let disk = DeviceFacts(identifier: "disk8", wholeDisk: true, virtual: false, removableOrExternal: true, bus: "USB", internalDisk: false, startup: true)
        XCTAssertFalse(DeviceGuard.isRecoverable(disk))
    }

    func testDeviceFilterRejectsDiskImagesAndAPFSContainers() {
        let image = DeviceFacts(identifier: "disk12", wholeDisk: true, virtual: true, removableOrExternal: true, bus: "Disk Image", internalDisk: false, startup: false)
        XCTAssertFalse(DeviceGuard.isRecoverable(image))
        XCTAssertTrue(DeviceGuard.isRecoverable(image, allowDiskImages: true))
        let container = DeviceFacts(identifier: "disk7", wholeDisk: true, virtual: true, removableOrExternal: true, bus: "USB", internalDisk: false, startup: false)
        XCTAssertFalse(DeviceGuard.isRecoverable(container, allowDiskImages: true))
    }

    func testDiskIdentifierParsing() {
        XCTAssertEqual(DeviceGuard.diskIdentifier("/dev/rdisk4"), "disk4")
        XCTAssertEqual(DeviceGuard.diskIdentifier("/dev/disk10"), "disk10")
        XCTAssertEqual(DeviceGuard.diskIdentifier("disk4s1"), "disk4")
        XCTAssertEqual(DeviceGuard.diskIdentifier("/dev/sda"), nil)
        XCTAssertEqual(DeviceGuard.diskIdentifier("disk4; rm -rf /"), nil)
    }

    func testCameraFolderNames() {
        XCTAssertEqual(CameraFolders.brand(forFolder: "100_FUJI"), "Fujifilm")
        XCTAssertEqual(CameraFolders.brand(forFolder: "100CANON"), "Canon")
        XCTAssertEqual(CameraFolders.brand(forFolder: "101MSDCF"), "Sony")
        XCTAssertEqual(CameraFolders.brand(forFolder: "100NZ_8"), "Nikon")
        XCTAssertEqual(CameraFolders.brand(forFolder: "100GOPRO"), "GoPro")
        XCTAssertNil(CameraFolders.brand(forFolder: "Holiday"))
    }

    func testCategoriesFromExtensions() {
        XCTAssertEqual(FileTyping.category(forExtension: "CR3"), .raw)
        XCTAssertEqual(FileTyping.category(forExtension: "mts"), .video)
        XCTAssertEqual(FileTyping.category(forExtension: "docx"), .document)
        XCTAssertEqual(FileKind.cr3.category, .raw)
        XCTAssertEqual(FileKind.jpeg.fileExtension, "jpg")
    }

    func testJunkNamesAreSkipped() {
        XCTAssertTrue(FileTyping.skipFile("._DSCF0001.JPG"))
        XCTAssertTrue(FileTyping.skipFile(".DS_Store"))
        XCTAssertTrue(FileTyping.skipFile("Thumbs.db"))
        XCTAssertFalse(FileTyping.skipFile("DSCF0001.JPG"))
        XCTAssertFalse(FileTyping.skipDirectory(".Trashes"))
        XCTAssertTrue(FileTyping.skipDirectory(".Spotlight-V100"))
    }

    func testOutputPathDropsParentSegments() {
        XCTAssertEqual(OutputPath.relative(from: "../../etc/passwd"), "etc/passwd")
        XCTAssertEqual(OutputPath.relative(from: "DCIM/100_FUJI/DSCF0001.JPG"), "DCIM/100_FUJI/DSCF0001.JPG")
        XCTAssertEqual(OutputPath.relative(from: "name:with/slash"), "name_with/slash")
    }
}

final class FATLayoutTests: XCTestCase {
    func testDeletedFilesOnAHandBuiltFAT16Image() throws {
        let image = FAT16Sample.make()
        let reader = DataBlockReader(image.data)
        let result = try RecoveryEngine.scan(reader: reader, options: ScanOptions(deepScan: false, categories: [.photo]))
        let names = Set(result.files.map(\.name))
        XCTAssertEqual(names, Set(["Holiday Photo.JPG", "_RAG0001.JPG", "DSCF0007.JPG"]), "Found \(result.files.map(\.name))")

        let holiday = try XCTUnwrap(result.files.first { $0.name == "Holiday Photo.JPG" })
        XCTAssertEqual(holiday.confidence, .named)
        XCTAssertEqual(try RecoveryEngine.read(holiday, from: reader, maxBytes: 100), image.holiday)

        let frag = try XCTUnwrap(result.files.first { $0.name == "_RAG0001.JPG" })
        XCTAssertEqual(frag.confidence, .named)
        XCTAssertEqual(try RecoveryEngine.read(frag, from: reader, maxBytes: 1000), image.fragmented)
        XCTAssertTrue(frag.originalPath.isEmpty || !frag.originalPath.contains(".."))

        let fuji = try XCTUnwrap(result.files.first { $0.name == "DSCF0007.JPG" })
        XCTAssertEqual(fuji.confidence, .estimated)
        XCTAssertEqual(try RecoveryEngine.read(fuji, from: reader, maxBytes: 1000), image.fuji)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dr-fat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = folder.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ManifestStore.write(result, to: manifest)
        let loaded = try ManifestStore.read(from: manifest)
        let report = try PhotoRestore.save(loaded.files, from: reader, to: folder)
        XCTAssertEqual(report.failed, [])
        let restored = try Data(contentsOf: folder.appendingPathComponent("_RAG0001.JPG"))
        XCTAssertEqual(restored, image.fragmented)
        let sneaky = folder.appendingPathComponent("etc/passwd")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sneaky.path))
    }
}

final class CarveTests: XCTestCase {
    func testCarvedJPEGKeepsTheFujifilmFileName() throws {
        var jpeg = sampleJPEG(date: "2024:05:06 07:08:09")
        jpeg.insert(contentsOf: marker(0xFE, Data("DSCF0003.JPG".utf8)), at: 2)
        var disk = Data(count: jpeg.count + 2000)
        disk.replaceSubrange(512..<(512 + jpeg.count), with: jpeg)
        let result = try RecoveryEngine.scan(reader: DataBlockReader(disk), options: ScanOptions(deepScan: true))
        let file = try XCTUnwrap(result.files.first { $0.kind == .jpeg })
        XCTAssertEqual(file.name, "DSCF0003.JPG")
    }

    func testJPEGCarveRecoversTheOriginalBytesAndEXIFDate() throws {
        let jpeg = sampleJPEG(date: "2024:05:06 07:08:09")
        var disk = Data(count: 4096)
        disk.replaceSubrange(1024..<(1024 + jpeg.count), with: jpeg)
        let reader = DataBlockReader(disk)
        let result = try RecoveryEngine.scan(reader: reader, options: ScanOptions(deepScan: true))
        let carved = result.files.filter { $0.confidence == .carved && $0.kind == .jpeg }
        XCTAssertEqual(carved.count, 1)
        let file = try XCTUnwrap(carved.first)
        XCTAssertEqual(try RecoveryEngine.read(file, from: reader, maxBytes: jpeg.count + 10), jpeg)
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: try XCTUnwrap(file.modified))
        XCTAssertEqual(parts.year, 2024)
        XCTAssertEqual(parts.month, 5)
        XCTAssertEqual(parts.day, 6)
        XCTAssertEqual(parts.hour, 7)
        XCTAssertEqual(parts.minute, 8)
        XCTAssertEqual(parts.second, 9)
    }

    func testRealJPEGFromSipsIsCarvedWhole() throws {
        let jpeg = try sipsJPEG()
        var disk = Data(count: jpeg.count + 5000)
        disk.replaceSubrange(2048..<(2048 + jpeg.count), with: jpeg)
        let result = try RecoveryEngine.scan(reader: DataBlockReader(disk), options: ScanOptions(deepScan: true))
        let file = try XCTUnwrap(result.files.first { $0.kind == .jpeg })
        XCTAssertEqual(try RecoveryEngine.read(file, from: DataBlockReader(disk), maxBytes: jpeg.count + 20), jpeg)
    }

    func testRAFCarveUsesTheOffsetTable() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let raf = sampleRAF(jpeg: jpeg, raw: Data(repeating: 0xAB, count: 300))
        var disk = Data(count: raf.count + 100)
        disk.replaceSubrange(0..<raf.count, with: raf)
        let result = try RecoveryEngine.scan(reader: DataBlockReader(disk), options: ScanOptions(deepScan: true))
        let file = try XCTUnwrap(result.files.first { $0.kind == .raf })
        XCTAssertEqual(file.size, UInt64(raf.count))
    }

    func testMovieCarveWalksAtoms() throws {
        let movie = sampleMovie()
        var disk = Data(count: movie.count + 1100)
        disk.replaceSubrange(512..<(512 + movie.count), with: movie)
        let result = try RecoveryEngine.scan(reader: DataBlockReader(disk), options: ScanOptions(deepScan: true))
        let file = try XCTUnwrap(result.files.first { $0.kind == .mov })
        XCTAssertEqual(file.size, UInt64(movie.count))
    }
}

final class FailingMediaTests: XCTestCase {
    /// Behaves like a card with a bad patch: reads touching it fail.
    private final class BadPatchReader: BlockReader, @unchecked Sendable {
        let data: Data
        let bad: Range<UInt64>
        var size: UInt64 { UInt64(data.count) }

        init(data: Data, bad: Range<UInt64>) {
            self.data = data
            self.bad = bad
        }

        func read(at offset: UInt64, count: Int) throws -> Data {
            let end = offset + UInt64(count)
            if offset < bad.upperBound && end > bad.lowerBound {
                throw RecoverError.readFailed("I/O error")
            }
            return try DataBlockReader(data).read(at: offset, count: count)
        }
    }

    func testDiskCopyIsByteForByte() throws {
        var disk = Data(count: 3 * 1024 * 1024 + 4096)
        for index in stride(from: 0, to: disk.count, by: 7) { disk[index] = UInt8(index % 251) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dr-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("card.img")
        let result = try DiskImager.copy(DataBlockReader(disk), to: url)
        XCTAssertEqual(result.unreadable, 0)
        XCTAssertEqual(try Data(contentsOf: url), disk)
    }

    func testBadSectorsBecomeZerosAndTheRestSurvives() throws {
        var disk = Data(repeating: 0xAB, count: 64 * 1024)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        disk.replaceSubrange(0..<4, with: jpeg)
        let reader = BadPatchReader(data: disk, bad: 8192..<12288)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dr-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("card.img")
        let result = try DiskImager.copy(reader, to: url)
        XCTAssertEqual(result.unreadable, 4096)
        let copy = try Data(contentsOf: url)
        XCTAssertEqual(copy.count, disk.count)
        XCTAssertEqual(copy.subdata(in: 8192..<12288), Data(count: 4096))
        XCTAssertEqual(copy.subdata(in: 0..<8192), disk.subdata(in: 0..<8192))
        XCTAssertEqual(copy.subdata(in: 12288..<copy.count), disk.subdata(in: 12288..<disk.count))
        // A deep scan over the same bad patch finishes and reports what it couldn't read.
        let scan = try RecoveryEngine.scan(reader: reader, options: ScanOptions(deepScan: true))
        XCTAssertEqual(scan.unreadableBytes, 4096)
    }
}

final class CardImageTests: XCTestCase {
    func testExFATDeletionOnAPartitionedImage() throws {
        try assertCameraDeletion(filesystem: "ExFAT", megabytes: 48)
    }

    func testFAT32DeletionOnAPartitionedImage() throws {
        try assertCameraDeletion(filesystem: "FAT32", megabytes: 128)
    }

    func testExFATFindsThePhotoAfterTheFileNameIsErased() throws {
        let lab = FileManager.default.temporaryDirectory.appendingPathComponent("dr-wiped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: lab, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lab) }
        let image = lab.appendingPathComponent("card.dmg")
        let jpeg = try sipsJPEG()
        try Shell.run("/usr/bin/hdiutil", ["create", "-size", "32m", "-fs", "ExFAT", "-volname", "DRWIPE", "-type", "UDIF", image.path])
        let attached = AttachedDisk(image: image)
        defer { attached.detach() }
        try attached.attach()
        let mount = try XCTUnwrap(attached.mount)
        let folder = URL(fileURLWithPath: mount).appendingPathComponent("DCIM/100_FUJI", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try jpeg.write(to: folder.appendingPathComponent("DSCF0003.JPG"))
        try Shell.run("/bin/sync")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("DSCF0003.JPG"))
        try Shell.run("/bin/sync")
        attached.detach()

        var disk = try Data(contentsOf: image)
        let name = "DSCF0003.JPG".data(using: .utf16LittleEndian)!
        guard let nameAt = disk.range(of: name) else {
            XCTFail("The deleted file name is not in the directory")
            return
        }
        let wipeStart = max(0, nameAt.lowerBound - 80)
        let wipeEnd = min(disk.count, nameAt.upperBound + 32)
        disk.replaceSubrange(wipeStart..<wipeEnd, with: Data(count: wipeEnd - wipeStart))
        try disk.write(to: image)

        let reader = try FileBlockReader(path: image.path)
        let result = try RecoveryEngine.scan(reader: reader, options: ScanOptions(deepScan: false))
        let match = result.files.first { file in
            (try? RecoveryEngine.read(file, from: reader, maxBytes: jpeg.count + 8)) == jpeg
        }
        XCTAssertNotNil(match, "Found \(result.files.map { "\($0.name) \($0.confidence.rawValue)" })")
        XCTAssertEqual(match?.confidence, .carved)
        XCTAssertTrue(result.searchedContents)
    }

    private func assertCameraDeletion(filesystem: String, megabytes: Int) throws {
        let lab = FileManager.default.temporaryDirectory.appendingPathComponent("dr-\(filesystem)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: lab, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lab) }
        let volume = "DR\(filesystem.prefix(3))".uppercased()
        let image = lab.appendingPathComponent("card.dmg")
        let jpeg = try sipsJPEG()
        let large = patternedJPEG(count: 200_000)
        try jpeg.write(to: lab.appendingPathComponent("small.jpg"))
        try large.write(to: lab.appendingPathComponent("large.jpg"))
        try Data("hello".utf8).write(to: lab.appendingPathComponent("NOTES.TXT"))
        try Shell.run("/usr/bin/hdiutil", ["create", "-size", "\(megabytes)m", "-fs", filesystem, "-volname", volume, "-type", "UDIF", image.path])
        let attached = AttachedDisk(image: image)
        defer { attached.detach() }
        try attached.attach()
        let mount = try XCTUnwrap(attached.mount)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: mount).appendingPathComponent("DCIM/100_FUJI"), withIntermediateDirectories: true)
        let folder = URL(fileURLWithPath: mount).appendingPathComponent("DCIM/100_FUJI")
        try jpeg.write(to: folder.appendingPathComponent("DSCF0001.JPG"))
        try jpeg.write(to: folder.appendingPathComponent("DSCF0002.JPG"))
        try large.write(to: folder.appendingPathComponent("DSCF0099.JPG"))
        try jpeg.write(to: folder.appendingPathComponent("Holiday Photo.JPG"))
        try Data("hello".utf8).write(to: folder.appendingPathComponent("NOTES.TXT"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("DSCF0001.JPG"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("DSCF0099.JPG"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Holiday Photo.JPG"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("NOTES.TXT"))
        try Shell.run("/bin/sync")
        attached.detach()

        let reader = try FileBlockReader(path: image.path)
        let result = try RecoveryEngine.scan(reader: reader, options: ScanOptions(categories: [.photo, .raw, .video]))
        let names = Set(result.files.map { $0.name.lowercased() })
        XCTAssertTrue(names.contains("dscf0001.jpg"), "missing DSCF0001 in \(result.files.map(\.name)) fs=\(result.filesystem) warnings=\(result.warnings)")
        XCTAssertTrue(names.contains("dscf0099.jpg"), "missing large file in \(result.files.map(\.name))")
        XCTAssertTrue(names.contains("holiday photo.jpg"), "missing long name in \(result.files.map(\.name))")
        XCTAssertFalse(names.contains("dscf0002.jpg"))
        XCTAssertFalse(names.contains("notes.txt"))
        for file in result.files where file.name.lowercased().hasPrefix("dscf") || file.name.lowercased().hasPrefix("holiday") {
            XCTAssertTrue(file.originalPath.lowercased().contains("dcim/100_fuji"), file.originalPath)
        }
        let small = try XCTUnwrap(result.files.first { $0.name.lowercased() == "dscf0001.jpg" })
        XCTAssertEqual(try RecoveryEngine.read(small, from: reader, maxBytes: jpeg.count + 10), jpeg)
        let big = try XCTUnwrap(result.files.first { $0.name.lowercased() == "dscf0099.jpg" })
        XCTAssertEqual(try RecoveryEngine.read(big, from: reader, maxBytes: large.count + 10), large)
        XCTAssertEqual(result.filesystem.contains(filesystem == "ExFAT" ? "ExFAT" : "FAT32"), true)
    }
}

private enum FAT16Sample {
    struct Built {
        var data: Data
        var holiday: Data
        var fragmented: Data
        var fuji: Data
    }

    static func make() -> Built {
        let bytesPerSector = 512
        let reserved = 4
        let fatSectors = 20
        let fats = 2
        let rootEntries = 16
        let dataSectors = 5000
        let total = reserved + fats * fatSectors + 1 + dataSectors
        var disk = Data(count: total * bytesPerSector)

        func set16(_ offset: Int, _ value: UInt16) {
            disk[offset] = UInt8(value & 0xFF)
            disk[offset + 1] = UInt8(value >> 8)
        }
        func set32(_ offset: Int, _ value: UInt32) {
            disk[offset] = UInt8(value & 0xFF)
            disk[offset + 1] = UInt8((value >> 8) & 0xFF)
            disk[offset + 2] = UInt8((value >> 16) & 0xFF)
            disk[offset + 3] = UInt8((value >> 24) & 0xFF)
        }

        disk[0] = 0xEB
        disk[1] = 0x3C
        disk[2] = 0x90
        set16(11, 512)
        disk[13] = 1
        set16(14, UInt16(reserved))
        disk[16] = UInt8(fats)
        set16(17, UInt16(rootEntries))
        set16(19, UInt16(total))
        disk[21] = 0xF8
        set16(22, UInt16(fatSectors))
        disk[510] = 0x55
        disk[511] = 0xAA

        let fatBase = reserved * bytesPerSector
        func setFAT(_ cluster: Int, _ value: UInt16) {
            for copy in 0..<fats {
                let offset = fatBase + copy * fatSectors * bytesPerSector + cluster * 2
                set16(offset, value)
            }
        }
        setFAT(0, 0xFFF8)
        setFAT(1, 0xFFFF)
        setFAT(3, 0xFFFF)
        setFAT(4, 6)
        setFAT(6, 0xFFFF)
        setFAT(7, 0)
        setFAT(8, 0xFFFF)
        setFAT(9, 0)

        let root = fatBase + fats * fatSectors * bytesPerSector
        let dataBase = root + bytesPerSector
        func clusterOffset(_ cluster: Int) -> Int { dataBase + (cluster - 2) * bytesPerSector }

        let holiday = Data([0xFF, 0xD8, 0xFF, 0xD9, 0x11, 0x22, 0x33, 0x44])
        var fragmented = Data(count: 600)
        fragmented[0] = 0xFF
        fragmented[1] = 0xD8
        fragmented[2] = 0xFF
        for index in 3..<fragmented.count { fragmented[index] = UInt8(index & 0xFF) }
        let fuji = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x10]) + Data("FUJI-TEST".utf8)
        let kept = Data([0xFF, 0xD8, 0xFF, 0x00])
        let note = Data("hello".utf8)

        disk.replaceSubrange(clusterOffset(3)..<(clusterOffset(3) + holiday.count), with: holiday)
        disk.replaceSubrange(clusterOffset(4)..<(clusterOffset(4) + 512), with: fragmented.prefix(512))
        disk.replaceSubrange(clusterOffset(6)..<(clusterOffset(6) + 88), with: fragmented.suffix(88))
        disk.replaceSubrange(clusterOffset(7)..<(clusterOffset(7) + fuji.count), with: fuji)
        disk.replaceSubrange(clusterOffset(8)..<(clusterOffset(8) + kept.count), with: kept)
        disk.replaceSubrange(clusterOffset(9)..<(clusterOffset(9) + note.count), with: note)

        let shortHoliday = shortEntry(name: "HOLIDA~1", ext: "JPG", cluster: 3, size: holiday.count, deleted: true)
        let checksum = lfnChecksum(Array("HOLIDA~1JPG".utf8))
        var chars = Array("Holiday Photo.JPG".utf16)
        chars.append(0)
        let first = lfnEntry(units: Array(chars.prefix(13)), checksum: checksum)
        var secondUnits = Array(chars.dropFirst(13).prefix(13))
        while secondUnits.count < 13 { secondUnits.append(0xFFFF) }
        let second = lfnEntry(units: secondUnits, checksum: checksum)
        var entries = Data()
        entries.append(second)
        entries.append(first)
        entries.append(shortHoliday)
        entries.append(shortEntry(name: "FRAG0001", ext: "JPG", cluster: 4, size: fragmented.count, deleted: true))
        entries.append(shortEntry(name: "DSCF0007", ext: "JPG", cluster: 7, size: fuji.count, deleted: true))
        entries.append(shortEntry(name: "KEEP0001", ext: "JPG", cluster: 8, size: kept.count, deleted: false))
        entries.append(shortEntry(name: "NOTES", ext: "TXT", cluster: 9, size: note.count, deleted: true))
        disk.replaceSubrange(root..<(root + entries.count), with: entries)
        return Built(data: disk, holiday: holiday, fragmented: fragmented, fuji: fuji)
    }

    static func shortEntry(name: String, ext: String, cluster: UInt32, size: Int, deleted: Bool) -> Data {
        var entry = Data(count: 32)
        var stem = Array(name.utf8)
        while stem.count < 8 { stem.append(0x20) }
        var extensionBytes = Array(ext.utf8)
        while extensionBytes.count < 3 { extensionBytes.append(0x20) }
        for index in 0..<8 { entry[index] = stem[index] }
        for index in 0..<3 { entry[8 + index] = extensionBytes[index] }
        if deleted { entry[0] = 0xE5 }
        entry[11] = 0x20
        entry[26] = UInt8(cluster & 0xFF)
        entry[27] = UInt8((cluster >> 8) & 0xFF)
        let fileSize = UInt32(size)
        entry[28] = UInt8(fileSize & 0xFF)
        entry[29] = UInt8((fileSize >> 8) & 0xFF)
        entry[30] = UInt8((fileSize >> 16) & 0xFF)
        entry[31] = UInt8((fileSize >> 24) & 0xFF)
        return entry
    }

    static func lfnEntry(units: [UInt16], checksum: UInt8) -> Data {
        var entry = Data(count: 32)
        entry[0] = 0xE5
        entry[11] = 0x0F
        entry[13] = checksum
        let offsets = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        for (index, offset) in offsets.enumerated() where index < units.count {
            entry[offset] = UInt8(units[index] & 0xFF)
            entry[offset + 1] = UInt8(units[index] >> 8)
        }
        return entry
    }

    static func lfnChecksum(_ name: [UInt8]) -> UInt8 {
        var sum: UInt8 = 0
        for byte in name.prefix(11) {
            let carry: UInt8 = (sum & 1) == 1 ? 0x80 : 0
            sum = carry &+ (sum >> 1) &+ byte
        }
        return sum
    }
}

private func sampleJPEG(date: String) -> Data {
    let bytes = Array(date.utf8) + [0]
    var tiff = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])
    tiff.append(contentsOf: [1, 0])
    tiff.append(contentsOf: [0x32, 0x01])
    tiff.append(contentsOf: [2, 0])
    tiff.append(contentsOf: [20, 0, 0, 0])
    tiff.append(contentsOf: [26, 0, 0, 0])
    tiff.append(contentsOf: [0, 0, 0, 0])
    var string = Data(bytes)
    while string.count < 20 { string.append(0) }
    tiff.append(string)
    var app1 = Data("Exif\u{0}\u{0}".utf8)
    app1.append(tiff)
    var jpeg = Data([0xFF, 0xD8])
    jpeg.append(marker(0xE1, app1))
    jpeg.append(marker(0xC0, Data([8, 0, 1, 0, 1, 1, 1, 0x11, 0])))
    jpeg.append(marker(0xDA, Data([1, 1, 0, 0, 0x3F, 0])))
    jpeg.append(contentsOf: [0x00, 0xFF, 0x00, 0x7F])
    jpeg.append(contentsOf: [0xFF, 0xD9])
    return jpeg
}

private func marker(_ type: UInt8, _ payload: Data) -> Data {
    var data = Data([0xFF, type])
    let length = UInt16(payload.count + 2)
    data.append(UInt8(length >> 8))
    data.append(UInt8(length & 0xFF))
    data.append(payload)
    return data
}

private func sampleRAF(jpeg: Data, raw: Data) -> Data {
    var file = Data(count: 0x80)
    let magic = Array("FUJIFILMCCD-RAW ".utf8)
    for (index, byte) in magic.enumerated() { file[index] = byte }
    let version = Array("0201".utf8)
    for (index, byte) in version.enumerated() { file[0x10 + index] = byte }
    func set32(_ offset: Int, _ value: UInt32) {
        file[offset] = UInt8((value >> 24) & 0xFF)
        file[offset + 1] = UInt8((value >> 16) & 0xFF)
        file[offset + 2] = UInt8((value >> 8) & 0xFF)
        file[offset + 3] = UInt8(value & 0xFF)
    }
    let jpegOffset = 0x80
    let metaOffset = jpegOffset + jpeg.count
    let meta = Data([0, 0, 0, 0])
    let cfaOffset = metaOffset + meta.count
    set32(0x54, UInt32(jpegOffset))
    set32(0x58, UInt32(jpeg.count))
    set32(0x5C, UInt32(metaOffset))
    set32(0x60, UInt32(meta.count))
    set32(0x64, UInt32(cfaOffset))
    set32(0x68, UInt32(raw.count))
    file.append(jpeg)
    file.append(meta)
    file.append(raw)
    return file
}

private func sampleMovie() -> Data {
    func atom(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        let size = UInt32(8 + payload.count)
        data.append(UInt8((size >> 24) & 0xFF))
        data.append(UInt8((size >> 16) & 0xFF))
        data.append(UInt8((size >> 8) & 0xFF))
        data.append(UInt8(size & 0xFF))
        data.append(contentsOf: type.utf8)
        data.append(payload)
        return data
    }
    var brand = Data("qt  ".utf8)
    brand.append(contentsOf: [0, 0, 0, 0])
    brand.append(contentsOf: "qt  ".utf8)
    return atom("ftyp", brand) + atom("mdat", Data(repeating: 0x11, count: 9000))
}

private func patternedJPEG(count: Int) -> Data {
    var data = Data([0xFF, 0xD8, 0xFF, 0xE0])
    var value: UInt32 = 1
    while data.count < count {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
        value += 1
    }
    return data.prefix(count)
}

private func sipsJPEG() throws -> Data {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dr-jpeg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let ppm = folder.appendingPathComponent("tiny.ppm")
    let jpg = folder.appendingPathComponent("tiny.jpg")
    var pixels = Data()
    for _ in 0..<64 { pixels.append(contentsOf: [220, 40, 40]) }
    var ppmData = Data("P6 8 8 255\n".utf8)
    ppmData.append(pixels)
    try ppmData.write(to: ppm)
    try Shell.run("/usr/bin/sips", ["-s", "format", "jpeg", ppm.path, "--out", jpg.path])
    return try Data(contentsOf: jpg)
}

private enum Shell {
    @discardableResult
    static func run(_ program: String, _ arguments: [String] = []) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(domain: "shell", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(program) \(arguments.joined(separator: " "))\n\(text)\n\(err)",
            ])
        }
        return text + err
    }
}

private final class AttachedDisk {
    let image: URL
    var disk: String?
    var mount: String?

    init(image: URL) {
        self.image = image
    }

    func attach() throws {
        let output = try Shell.run("/usr/bin/hdiutil", ["attach", image.path])
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let node = fields.first, node.hasPrefix("/dev/disk") else { continue }
            if disk == nil && node.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil {
                disk = node
            }
            if let volume = fields.last, volume.hasPrefix("/Volumes/") {
                mount = volume
            }
        }
        if mount == nil {
            throw NSError(domain: "attach", code: 1, userInfo: [NSLocalizedDescriptionKey: output])
        }
    }

    func detach() {
        guard let disk else { return }
        _ = try? Shell.run("/usr/bin/hdiutil", ["detach", disk, "-force"])
        self.disk = nil
        mount = nil
    }
}

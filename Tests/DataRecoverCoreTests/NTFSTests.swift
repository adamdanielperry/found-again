import XCTest
@testable import DataRecoverCore

/// macOS can't create NTFS volumes, so these tests build one by hand: a boot sector, an MFT in two fragments
/// with fixups applied, $Bitmap, folders, a live file and a set of deleted files that each exercise one rule.
final class NTFSTests: XCTestCase {
    func testDeletedFilesKeepNamesFoldersDatesAndContents() throws {
        let sample = NTFSSample(shape: .large)
        let disk = sample.mbrDisk()
        try assertRecoversEverything(sample, disk: disk, partitionOffset: NTFSSample.partitionOffset)

        let result = try RecoveryEngine.scan(reader: DataBlockReader(disk), options: ScanOptions(deepScan: false))
        let holiday = try XCTUnwrap(result.files.first { $0.name == "holiday.jpg" })
        XCTAssertEqual(holiday.id, "ntfs-\(NTFSSample.partitionOffset)-27")
        XCTAssertEqual(holiday.modified, Date(timeIntervalSince1970: NTFSSample.holidayTime))
        XCTAssertEqual(holiday.kind, .jpeg)
        XCTAssertEqual(holiday.headerLooksValid, true)
        XCTAssertEqual(holiday.ranges.count, 2, "Two runs should give two ranges")
        let notes = try XCTUnwrap(result.files.first { $0.name == "notes.txt" })
        XCTAssertEqual(notes.modified, Date(timeIntervalSince1970: NTFSSample.notesTime))
        XCTAssertEqual(notes.category, .document)
    }

    func testRecordsThatStraddleMFTFragmentsWithSmallClustersOnGPT() throws {
        // 512-byte clusters and 1 KB records: record 26 (a file stored inside its record) starts in the first
        // MFT fragment and ends in the second, and its contents cross a fixed-up sector end.
        let sample = NTFSSample(shape: .small)
        try assertRecoversEverything(sample, disk: sample.gptDisk(), partitionOffset: NTFSSample.partitionOffset)
    }

    func testCategoryFilterKeepsOnlyPhotos() throws {
        let sample = NTFSSample(shape: .large)
        let result = try RecoveryEngine.scan(
            reader: DataBlockReader(sample.mbrDisk()),
            options: ScanOptions(deepScan: false, categories: [.photo])
        )
        XCTAssertEqual(Set(result.files.map(\.name)), ["holiday.jpg", "orphan.jpg", "partly.jpg", "Beach.jpg", "holes.jpg"])
    }

    func testLiveFilesAreNotReportedOrCarved() throws {
        let sample = NTFSSample(shape: .large)
        let disk = sample.mbrDisk()
        let reader = DataBlockReader(disk)
        let base = NTFSSample.partitionOffset
        let keep = base + UInt64(sample.blockOffset(100))
        let control = base + UInt64(sample.blockOffset(240))

        var found: [RecoverableFile] = []
        var used: [ByteRange] = []
        try NTFSScanner.scan(
            reader: reader,
            volume: FoundVolume(offset: base, kind: .ntfs),
            options: ScanOptions(deepScan: false),
            sink: &found,
            used: &used
        )
        let cover = RangeCover([], extra: used)
        XCTAssertTrue(cover.contains(keep), "The live file's first cluster should be skipped by the deep scan")
        XCTAssertTrue(cover.contains(keep + UInt64(sample.keep.count) - 1), "The live file's last byte should be skipped too")
        XCTAssertTrue(cover.contains(base + UInt64(sample.blockOffset(70))), "A live folder's index clusters are in use")
        XCTAssertTrue(cover.contains(base), "The boot sector is in use")
        for extent in sample.shape.mftExtents {
            XCTAssertTrue(cover.contains(base + UInt64(extent.lcn * sample.shape.clusterSize)), "The MFT is in use")
        }
        XCTAssertFalse(cover.contains(base + UInt64(sample.blockOffset(120))), "A deleted file's clusters are free space")
        XCTAssertFalse(cover.contains(control))

        let result = try RecoveryEngine.scan(reader: reader, options: ScanOptions(deepScan: true))
        XCTAssertFalse(result.files.contains { $0.name == "keep.jpg" })
        let carved = result.files.filter { $0.confidence == .carved }
        XCTAssertTrue(carved.contains { $0.ranges.first?.offset == control }, "The control JPEG in free space should be carved")
        XCTAssertFalse(carved.contains { ($0.ranges.first?.offset ?? 0) >= keep && ($0.ranges.first?.offset ?? 0) < keep + 8192 })
        XCTAssertEqual(result.filesystem, "NTFS")
    }

    func testTornRecordIsSkippedAndTheRestSurvive() throws {
        var sample = NTFSSample(shape: .large)
        sample.tear(record: 27)
        let result = try RecoveryEngine.scan(reader: DataBlockReader(sample.mbrDisk()), options: ScanOptions(deepScan: false))
        var expected = Set(NTFSSample.expected.keys)
        expected.remove("holiday.jpg")
        XCTAssertEqual(Set(result.files.map(\.name)), expected)
    }

    func testTornMFTRecordFallsBackToTheMirror() throws {
        var sample = NTFSSample(shape: .large)
        sample.tear(record: 0)
        try assertRecoversEverything(sample, disk: sample.mbrDisk(), partitionOffset: NTFSSample.partitionOffset)
    }

    func testMFTRunListContinuedInAnExtensionRecordOnABareVolume() throws {
        // A heavily fragmented MFT lists the rest of its runs in an extension record. Every user record here
        // sits in the second fragment, so nothing is found unless that record is followed.
        let sample = NTFSSample(shape: .large, mftInExtension: true)
        try assertRecoversEverything(sample, disk: sample.volume, partitionOffset: 0)
    }

    func testBootSectorChecks() throws {
        let good = NTFSSample(shape: .large).bootSector()
        let geometry = try XCTUnwrap(NTFSGeometry.parse(boot: good, at: 0))
        XCTAssertEqual(geometry.clusterSize, 4096)
        XCTAssertEqual(geometry.recordSize, 1024)
        XCTAssertEqual(geometry.totalClusters, UInt64(NTFSSample.totalSectors / 8))

        let small = try XCTUnwrap(NTFSGeometry.parse(boot: NTFSSample(shape: .small).bootSector(), at: 0))
        XCTAssertEqual(small.clusterSize, 512)
        XCTAssertEqual(small.recordSize, 1024, "A positive count means clusters per record")

        func variant(_ change: (inout Data) -> Void) -> NTFSGeometry? {
            var boot = good
            change(&boot)
            return NTFSGeometry.parse(boot: boot, at: 0)
        }
        // Clusters over 64 KB: 0xF4 is 2^12 sectors of 512 bytes, 2 MB.
        let huge = variant {
            $0[0x0D] = 0xF4
            $0.ntfsPut64(0x28, 1 << 30)
            $0.ntfsPut64(0x30, 4)
        }
        XCTAssertEqual(huge?.clusterSize, 2 * 1024 * 1024)
        let wide = variant {
            $0[0x0D] = 0xF8
            $0.ntfsPut64(0x30, 2)
        }
        XCTAssertEqual(wide?.clusterSize, 128 * 1024, "0xF8 means 2^8 sectors")
        XCTAssertNil(variant { $0[0x0D] = 0xF3 }, "4 MB clusters are beyond what NTFS allows")
        XCTAssertNil(variant { $0[0x0D] = 3 })
        XCTAssertNil(variant { $0[0x0D] = 0 })
        XCTAssertNil(variant { $0.ntfsPut16(0x0B, 256) })
        XCTAssertNil(variant { $0.ntfsPut16(0x0B, 8192) })
        XCTAssertNil(variant { $0.ntfsPut16(0x0B, 1536) })
        XCTAssertNil(variant { $0[0x40] = 0 })
        XCTAssertEqual(variant { $0[0x40] = 0xF4 }?.recordSize, 4096, "-12 means 4 KB records, as on 4K-sector drives")
        XCTAssertNil(variant { $0[0x40] = 0xE0 }, "-32 would be a 4 GB record")
        XCTAssertNil(variant { $0.ntfsPut64(0x30, 0) }, "The MFT can't start at cluster 0")
        XCTAssertNil(variant { $0.ntfsPut64(0x30, UInt64(NTFSSample.totalSectors)) }, "The MFT must be on the volume")
        XCTAssertNil(variant { $0.ntfsPut64(0x28, 0) })
        XCTAssertNil(variant { $0[3] = UInt8(ascii: "X") })
        XCTAssertNil(variant { $0[511] = 0 })
    }

    func testRunListDecoding() {
        // Examples from the Linux-NTFS documentation of data runs.
        func decode(_ bytes: [UInt8]) -> [NTFSRun]? {
            NTFSRunList.decode(Data(bytes), from: 0, to: bytes.count)
        }
        XCTAssertEqual(decode([0x21, 0x18, 0x34, 0x56, 0x00]), [NTFSRun(lcn: 0x5634, length: 0x18)])
        XCTAssertEqual(
            decode([0x31, 0x38, 0x73, 0x25, 0x34, 0x32, 0x14, 0x01, 0xE5, 0x11, 0x02, 0x31, 0x42, 0xAA, 0x00, 0x03, 0x00]),
            [
                NTFSRun(lcn: 0x342573, length: 0x38),
                NTFSRun(lcn: 0x363758, length: 0x114),
                NTFSRun(lcn: 0x393802, length: 0x42),
            ]
        )
        XCTAssertEqual(
            decode([0x11, 0x30, 0x60, 0x21, 0x10, 0x00, 0x01, 0x11, 0x20, 0xE0, 0x00]),
            [NTFSRun(lcn: 0x60, length: 0x30), NTFSRun(lcn: 0x160, length: 0x10), NTFSRun(lcn: 0x140, length: 0x20)],
            "A negative offset moves back from the previous run"
        )
        XCTAssertEqual(
            decode([0x11, 0x30, 0x20, 0x01, 0x60, 0x11, 0x10, 0x30, 0x00]),
            [NTFSRun(lcn: 0x20, length: 0x30), NTFSRun(lcn: nil, length: 0x60), NTFSRun(lcn: 0x50, length: 0x10)],
            "A sparse run has no offset, and the next run counts from the last real one"
        )
        XCTAssertNil(decode([0x11, 0x30, 0x80, 0x00]), "A run before cluster 0 is damage")
        XCTAssertNil(decode([0x21, 0x18, 0x34]), "A run cut short is damage")
        XCTAssertNil(decode([0x10, 0x00]), "A run needs a length")
        XCTAssertNil(decode([0x11, 0x00, 0x05, 0x00]), "A zero-length run is damage")
    }

    func testFileTimes() {
        XCTAssertEqual(Binary.fileTimeDate(132_539_328_000_000_000), Date(timeIntervalSince1970: 1_609_459_200))
        XCTAssertNil(Binary.fileTimeDate(0))
        XCTAssertNil(Binary.fileTimeDate(116_444_736_000_000_000), "1970 is before any of these drives existed")
    }

    func testRecycleBinPaths() {
        var info = Data(count: 0x18)
        info.ntfsPut64(0, 1)
        let units = Array("D:\\Holiday\\Day 1\\IMG_0001.JPG".utf16)
        for unit in units { info.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
        info.append(Data(count: 520 - units.count * 2))
        XCTAssertEqual(RecycleBin.originalPath(info), "Holiday/Day 1/IMG_0001.JPG")
        XCTAssertEqual(RecycleBin.split("Holiday/Day 1/IMG_0001.JPG").folder, "Holiday/Day 1")
        XCTAssertNil(RecycleBin.originalPath(Data([3, 0, 0, 0, 0, 0, 0, 0])))
    }

    // MARK: - Shared checks

    private func assertRecoversEverything(
        _ sample: NTFSSample,
        disk: Data,
        partitionOffset: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let reader = DataBlockReader(disk)
        let result = try RecoveryEngine.scan(reader: reader, options: ScanOptions(deepScan: false))
        XCTAssertEqual(result.filesystem, "NTFS", file: file, line: line)
        XCTAssertEqual(result.volumeCount, 1, file: file, line: line)
        XCTAssertEqual(result.warnings, [], file: file, line: line)
        XCTAssertEqual(
            Set(result.files.map(\.name)), Set(NTFSSample.expected.keys),
            "Found \(result.files.map(\.originalPath))", file: file, line: line
        )
        for (name, want) in NTFSSample.expected {
            guard let found = result.files.first(where: { $0.name == name }) else { continue }
            XCTAssertEqual(found.originalPath, want.path, file: file, line: line)
            XCTAssertEqual(found.confidence, want.confidence, name, file: file, line: line)
            XCTAssertEqual(found.complete, want.complete, name, file: file, line: line)
            XCTAssertTrue(found.id.hasPrefix("ntfs-\(partitionOffset)-"), found.id, file: file, line: line)
            let bytes = try XCTUnwrap(sample.recovered[name], name, file: file, line: line)
            XCTAssertEqual(found.size, UInt64(bytes.count), name, file: file, line: line)
            let read = try RecoveryEngine.read(found, from: reader, maxBytes: bytes.count + 100)
            XCTAssertEqual(read, bytes, "\(name) should come back byte for byte", file: file, line: line)
        }
    }
}

// MARK: - A hand-built NTFS volume

/// The cluster layout. File contents are placed in 4 KB blocks so the same files fit either cluster size.
private struct NTFSShape {
    var sectorsPerClusterByte: UInt8
    var clusterSize: Int
    var recordSizeByte: UInt8
    /// The MFT's fragments, in clusters: 48 records of 1 KB in all.
    var mftExtents: [(lcn: Int, count: Int)]

    /// 4 KB clusters and 1 KB records, stored as -10.
    static let large = NTFSShape(sectorsPerClusterByte: 8, clusterSize: 4096, recordSizeByte: 0xF6, mftExtents: [(16, 6), (40, 6)])
    /// 512-byte clusters and two clusters per record, split so record 26 straddles the fragments.
    static let small = NTFSShape(sectorsPerClusterByte: 1, clusterSize: 512, recordSizeByte: 2, mftExtents: [(128, 53), (320, 43)])
}

private struct NTFSSample {
    struct Want {
        var path: String
        var confidence: RecoveryConfidence
        var complete: Bool
    }

    static let block = 4096
    static let partitionLBA = 2048
    static let partitionOffset = UInt64(partitionLBA * 512)
    /// The partition is 2048 sectors. NTFS counts one fewer and keeps a backup boot sector in the last one.
    static let partitionSectors = 2048
    static let totalSectors = partitionSectors - 1
    static let recordSize = 1024
    static let recordCount = 48
    static let checkValue: UInt16 = 0x0102
    static let notesTime: TimeInterval = 1_609_556_645 // 2021-01-02 03:04:05 UTC
    static let holidayTime: TimeInterval = 1_686_832_496 // 2023-06-15 12:34:56 UTC

    static let expected: [String: Want] = [
        "notes.txt": Want(path: "Photos/notes.txt", confidence: .named, complete: true),
        "holiday.jpg": Want(path: "Photos/holiday.jpg", confidence: .named, complete: true),
        "letter.txt": Want(path: "Old/letter.txt", confidence: .named, complete: true),
        "orphan.jpg": Want(path: "Lost folders/Folder 31/orphan.jpg", confidence: .named, complete: true),
        "partly.jpg": Want(path: "Photos/partly.jpg", confidence: .estimated, complete: false),
        "Beach.jpg": Want(path: "Pictures/Beach.jpg", confidence: .named, complete: true),
        "report.pdf": Want(path: "Photos/report.pdf", confidence: .named, complete: true),
        "holes.jpg": Want(path: "Photos/holes.jpg", confidence: .named, complete: false),
    ]

    let shape: NTFSShape
    private(set) var volume: Data
    /// What each listed file should read back as.
    private(set) var recovered: [String: Data] = [:]
    let keep: Data
    private var allocated = Set<Int>()

    init(shape: NTFSShape, mftInExtension: Bool = false) {
        self.shape = shape
        volume = Data(count: Self.partitionSectors * 512)
        keep = Self.carvableJPEG(fill: 6000)
        build(mftInExtension: mftInExtension)
    }

    var totalClusters: Int { Self.totalSectors / (shape.clusterSize / 512) }
    func cluster(_ block: Int) -> Int { block * Self.block / shape.clusterSize }
    func clusters(_ blocks: Int) -> Int { blocks * Self.block / shape.clusterSize }
    func blockOffset(_ block: Int) -> Int { block * Self.block }

    // MARK: Disks

    func mbrDisk() -> Data {
        var disk = Data(count: Self.partitionLBA * 512)
        disk[446 + 4] = 0x07
        disk.ntfsPut32(446 + 8, UInt32(Self.partitionLBA))
        disk.ntfsPut32(446 + 12, UInt32(Self.partitionSectors))
        disk[510] = 0x55
        disk[511] = 0xAA
        disk.append(volume)
        return disk
    }

    func gptDisk() -> Data {
        var disk = Data(count: Self.partitionLBA * 512)
        disk[446 + 4] = 0xEE
        disk.ntfsPut32(446 + 8, 1)
        disk.ntfsPut32(446 + 12, 0xFFFF_FFFF)
        disk[510] = 0x55
        disk[511] = 0xAA
        disk.replaceSubrange(512..<520, with: Data("EFI PART".utf8))
        disk.ntfsPut32(512 + 8, 0x0001_0000)
        disk.ntfsPut32(512 + 12, 92)
        disk.ntfsPut64(512 + 72, 2)
        disk.ntfsPut32(512 + 80, 128)
        disk.ntfsPut32(512 + 84, 128)
        // Microsoft basic data partition type, EBD0A0A2-B9E5-4433-87C0-68B6B72699C7.
        let type: [UInt8] = [0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44, 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7]
        disk.replaceSubrange(1024..<1040, with: type)
        disk.ntfsPut64(1024 + 32, UInt64(Self.partitionLBA))
        disk.ntfsPut64(1024 + 40, UInt64(Self.partitionLBA + Self.partitionSectors - 1))
        disk.append(volume)
        return disk
    }

    func bootSector() -> Data {
        var boot = Data(count: 512)
        boot.replaceSubrange(0..<3, with: [0xEB, 0x52, 0x90])
        boot.replaceSubrange(3..<11, with: Data("NTFS    ".utf8))
        boot.ntfsPut16(0x0B, 512)
        boot[0x0D] = shape.sectorsPerClusterByte
        boot[0x15] = 0xF8
        boot.ntfsPut64(0x28, UInt64(Self.totalSectors))
        boot.ntfsPut64(0x30, UInt64(shape.mftExtents[0].lcn))
        boot.ntfsPut64(0x38, UInt64(cluster(8)))
        boot[0x40] = shape.recordSizeByte
        boot[0x44] = 1
        boot.ntfsPut64(0x48, 0x1234_5678_9ABC_DEF0)
        boot[510] = 0x55
        boot[511] = 0xAA
        return boot
    }

    /// Breaks the fixup check of one record: its second sector now ends in something other than the check value.
    mutating func tear(record number: Int) {
        let at = mftVolumeOffset(number * Self.recordSize + 1022)
        volume[at] = 0
        volume[at + 1] = 0
    }

    // MARK: Layout

    private mutating func build(mftInExtension: Bool) {
        let root = Self.reference(5, 5)
        let photos = Self.reference(24, 1)
        let time = Self.fileTime(1_700_000_000)

        mark(blocks: 0, count: 2)
        mark(blocks: 8, count: 1)
        for extent in shape.mftExtents {
            for lcn in extent.lcn..<(extent.lcn + extent.count) { allocated.insert(lcn) }
        }
        mark(blocks: 60, count: 1)
        mark(blocks: 70, count: 1)
        mark(blocks: 100, count: 2)

        // NTFS's own records.
        let mftSize = Self.recordCount * Self.recordSize
        let first = shape.mftExtents[0]
        if mftInExtension {
            let list = Attr.attributeList([(0x10, Self.reference(0, 1)), (0x30, Self.reference(0, 1)), (0x80, Self.reference(0, 1)), (0x80, Self.reference(16, 1))])
            put(0, sequence: 1, flags: 1, [Attr.standardInformation(time), list, Attr.fileName("$MFT", parent: root),
                Attr.nonResident(0x80, runs: [(first.lcn, first.count)], size: mftSize, clusterSize: shape.clusterSize)])
            let rest = Array(shape.mftExtents.dropFirst()).map { (Optional($0.lcn), $0.count) }
            put(16, sequence: 1, flags: 1, base: Self.reference(0, 1), [
                Attr.nonResident(0x80, runs: rest, size: 0, clusterSize: shape.clusterSize, firstVCN: first.count),
            ])
        } else {
            let runs = shape.mftExtents.map { (Optional($0.lcn), $0.count) }
            put(0, sequence: 1, flags: 1, [Attr.standardInformation(time), Attr.fileName("$MFT", parent: root),
                Attr.nonResident(0x80, runs: runs, size: mftSize, clusterSize: shape.clusterSize)])
        }
        put(1, sequence: 1, flags: 1, [Attr.standardInformation(time), Attr.fileName("$MFTMirr", parent: root), data(blocks: [(8, 1)], size: 4096)])
        put(5, sequence: 5, flags: 3, [Attr.standardInformation(time), Attr.fileName(".", parent: root)])
        let bitmapBytes = (totalClusters + 7) / 8
        put(6, sequence: 6, flags: 1, [Attr.standardInformation(time), Attr.fileName("$Bitmap", parent: root), data(blocks: [(60, 1)], size: bitmapBytes)])
        put(7, sequence: 7, flags: 1, [Attr.standardInformation(time), Attr.fileName("$Boot", parent: root), data(blocks: [(0, 2)], size: 8192)])

        // A live folder and a live photo: the photo must not be listed or carved.
        put(24, sequence: 1, flags: 3, [Attr.standardInformation(time), Attr.fileName("Photos", parent: root),
            Attr.nonResident(0xA0, name: "$I30", runs: [(cluster(70), clusters(1))], size: 4096, clusterSize: shape.clusterSize)])
        put(25, sequence: 1, flags: 1, [Attr.standardInformation(time), Attr.fileName("keep.jpg", parent: photos), data(blocks: [(100, 2)], size: keep.count)])
        write(keep, atBlock: 100)

        // A small file stored inside its record, crossing the first sector's fixed-up last two bytes.
        let notes = Data((0..<400).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
        put(26, sequence: 2, flags: 0, [Attr.standardInformation(Self.fileTime(Self.notesTime)), Attr.fileName("notes.txt", parent: photos), Attr.resident(0x80, notes)])
        recovered["notes.txt"] = notes

        // A deleted photo in two runs. Its DOS name comes first; the Win32 name should win.
        let holiday = Self.jpegLike(9192, seed: 1)
        put(27, sequence: 2, flags: 0, [
            Attr.standardInformation(Self.fileTime(Self.holidayTime)),
            Attr.fileName("HOLIDA~1.JPG", parent: photos, namespace: 2),
            Attr.fileName("holiday.jpg", parent: photos, namespace: 1),
            data(blocks: [(120, 2), (150, 1)], size: holiday.count),
        ])
        write(holiday.prefix(8192), atBlock: 120)
        write(holiday.suffix(from: 8192), atBlock: 150)
        recovered["holiday.jpg"] = holiday

        // A deleted folder (its sequence number moved on when it was freed) and a file inside it.
        put(28, sequence: 2, flags: 2, [Attr.standardInformation(time), Attr.fileName("Old", parent: root)])
        let letter = Data(String(repeating: "Dear Sam, the photos are on the drive. ", count: 40).utf8.prefix(1500))
        put(29, sequence: 2, flags: 0, [Attr.standardInformation(time), Attr.fileName("letter.txt", parent: Self.reference(28, 1)), data(blocks: [(160, 1)], size: letter.count)])
        write(letter, atBlock: 160)
        recovered["letter.txt"] = letter

        // A deleted file whose folder record now belongs to a different, live folder.
        let orphan = Self.jpegLike(2000, seed: 2)
        put(30, sequence: 2, flags: 0, [Attr.standardInformation(time), Attr.fileName("orphan.jpg", parent: Self.reference(31, 3)), data(blocks: [(170, 1)], size: orphan.count)])
        put(31, sequence: 4, flags: 3, [Attr.standardInformation(time), Attr.fileName("New Folder", parent: root)])
        write(orphan, atBlock: 170)
        recovered["orphan.jpg"] = orphan

        // Deleted files whose clusters a live file took over: all of them, or only the second run.
        put(32, sequence: 2, flags: 0, [Attr.standardInformation(time), Attr.fileName("gone.jpg", parent: photos), data(blocks: [(100, 1)], size: 3000)])
        let partly = Self.jpegLike(Self.block, seed: 3)
        put(33, sequence: 2, flags: 0, [Attr.standardInformation(time), Attr.fileName("partly.jpg", parent: photos), data(blocks: [(180, 1), (101, 1)], size: 6000)])
        write(partly, atBlock: 180)
        recovered["partly.jpg"] = partly + volume.subdata(in: blockOffset(101)..<(blockOffset(101) + 6000 - Self.block))

        // An emptied Recycle Bin: $R holds the contents, $I (stored in its record) the original path.
        put(34, sequence: 1, flags: 3, [Attr.standardInformation(time), Attr.fileName("$RECYCLE.BIN", parent: root)])
        put(35, sequence: 1, flags: 3, [Attr.standardInformation(time), Attr.fileName("S-1-5-21-1004336348-1177238915-682003330-1001", parent: Self.reference(34, 1))])
        let bin = Self.reference(35, 1)
        put(36, sequence: 2, flags: 0, [Attr.standardInformation(time), Attr.fileName("$IAB12CD.jpg", parent: bin), Attr.resident(0x80, Self.recycleInfo("E:\\Pictures\\Beach.jpg", size: 3000))])
        let beach = Self.jpegLike(3000, seed: 4)
        put(37, sequence: 2, flags: 0, [Attr.standardInformation(time), Attr.fileName("$RAB12CD.jpg", parent: bin), data(blocks: [(190, 1)], size: beach.count)])
        write(beach, atBlock: 190)
        recovered["Beach.jpg"] = beach

        // A deleted file whose cluster list is in a freed extension record, found through its attribute list.
        let report = Data("%PDF-1.4\n".utf8) + Self.filler(5000 - 9, seed: 5)
        let list = Attr.attributeList([(0x10, Self.reference(38, 1)), (0x30, Self.reference(38, 1)), (0x80, Self.reference(39, 1))])
        put(38, sequence: 2, flags: 0, [Attr.standardInformation(time), list, Attr.fileName("report.pdf", parent: photos)])
        put(39, sequence: 2, flags: 0, base: Self.reference(38, 1), [data(blocks: [(200, 2)], size: report.count)])
        write(report, atBlock: 200)
        recovered["report.pdf"] = report

        // NTFS's own files are never listed.
        put(40, sequence: 2, flags: 0, [Attr.standardInformation(time), Attr.fileName("$Secret.dat", parent: root), data(blocks: [(220, 1)], size: 100)])
        write(Self.jpegLike(100, seed: 6), atBlock: 220)

        // A sparse file: only the part before the hole can be recovered.
        let holes = Self.jpegLike(Self.block, seed: 7)
        put(41, sequence: 2, flags: 0, [Attr.standardInformation(time), Attr.fileName("holes.jpg", parent: photos),
            Attr.nonResident(0x80, runs: [(cluster(230), clusters(1)), (nil, clusters(1)), (cluster(231), clusters(1))], size: 3 * Self.block, clusterSize: shape.clusterSize)])
        write(holes, atBlock: 230)
        write(Self.jpegLike(Self.block, seed: 8), atBlock: 231)
        recovered["holes.jpg"] = holes

        // A compressed file can't be copied out cluster by cluster.
        put(42, sequence: 2, flags: 0, [Attr.standardInformation(time), Attr.fileName("packed.jpg", parent: photos),
            Attr.nonResident(0x80, runs: [(cluster(235), clusters(1))], size: 3000, clusterSize: shape.clusterSize, flags: 0x0001)])
        write(Self.jpegLike(3000, seed: 9), atBlock: 235)

        // Files under System Volume Information are Windows housekeeping.
        put(43, sequence: 1, flags: 3, [Attr.standardInformation(time), Attr.fileName("System Volume Information", parent: root)])
        put(44, sequence: 2, flags: 0, [Attr.standardInformation(time), Attr.fileName("hidden.jpg", parent: Self.reference(43, 1)), data(blocks: [(245, 1)], size: 2000)])
        write(Self.jpegLike(2000, seed: 10), atBlock: 245)

        // A real photo in free space with no record: the deep scan should find this one.
        write(Self.carvableJPEG(fill: 1000), atBlock: 240)

        var bitmap = Data(count: bitmapBytes)
        for lcn in allocated where lcn < totalClusters {
            bitmap[lcn / 8] |= UInt8(1 << (lcn % 8))
        }
        write(bitmap, atBlock: 60)

        let boot = bootSector()
        volume.replaceSubrange(0..<512, with: boot)
        volume.replaceSubrange((Self.totalSectors * 512)..<(Self.partitionSectors * 512), with: boot)
    }

    private mutating func mark(blocks start: Int, count: Int) {
        for lcn in cluster(start)..<cluster(start + count) { allocated.insert(lcn) }
    }

    private mutating func write(_ bytes: Data, atBlock block: Int) {
        let start = blockOffset(block)
        volume.replaceSubrange(start..<(start + bytes.count), with: bytes)
    }

    private func data(blocks: [(Int, Int)], size: Int) -> Data {
        let runs = blocks.map { (Optional(cluster($0.0)), clusters($0.1)) }
        return Attr.nonResident(0x80, runs: runs, size: size, clusterSize: shape.clusterSize)
    }

    /// Writes a record into the MFT (and record 0 into the mirror too), with fixups applied as NTFS does.
    private mutating func put(_ number: Int, sequence: UInt16, flags: UInt16, base: UInt64 = 0, _ attributes: [Data]) {
        let stored = Self.protect(Self.record(number: number, sequence: sequence, flags: flags, base: base, attributes: attributes))
        for half in 0..<2 {
            let at = mftVolumeOffset(number * Self.recordSize + half * 512)
            volume.replaceSubrange(at..<(at + 512), with: stored.subdata(in: (half * 512)..<((half + 1) * 512)))
        }
        if number == 0 {
            let mirror = blockOffset(8)
            volume.replaceSubrange(mirror..<(mirror + Self.recordSize), with: stored)
        }
    }

    private func mftVolumeOffset(_ mftByte: Int) -> Int {
        var vcn = mftByte / shape.clusterSize
        for extent in shape.mftExtents {
            if vcn < extent.count {
                return (extent.lcn + vcn) * shape.clusterSize + mftByte % shape.clusterSize
            }
            vcn -= extent.count
        }
        preconditionFailure("Record outside the MFT")
    }

    // MARK: Records and attributes

    static func reference(_ record: UInt64, _ sequence: UInt16) -> UInt64 {
        UInt64(sequence) << 48 | record
    }

    static func fileTime(_ unix: TimeInterval) -> UInt64 {
        (UInt64(unix) + 11_644_473_600) * 10_000_000
    }

    static func record(number: Int, sequence: UInt16, flags: UInt16, base: UInt64, attributes: [Data]) -> Data {
        var record = Data(count: recordSize)
        record.replaceSubrange(0..<4, with: Data("FILE".utf8))
        record.ntfsPut16(0x04, 0x30)
        record.ntfsPut16(0x06, 3)
        record.ntfsPut16(0x10, sequence)
        record.ntfsPut16(0x12, 1)
        record.ntfsPut16(0x14, 0x38)
        record.ntfsPut16(0x16, flags)
        var offset = 0x38
        for attribute in attributes {
            record.replaceSubrange(offset..<(offset + attribute.count), with: attribute)
            offset += attribute.count
        }
        record.ntfsPut32(offset, 0xFFFF_FFFF)
        offset += 8
        precondition(offset <= recordSize, "Record \(number) is too full")
        record.ntfsPut32(0x18, UInt32(offset))
        record.ntfsPut32(0x1C, UInt32(recordSize))
        record.ntfsPut64(0x20, base)
        record.ntfsPut16(0x28, UInt16(attributes.count))
        record.ntfsPut32(0x2C, UInt32(number))
        return record
    }

    /// Moves the last two bytes of each sector into the update sequence array and stamps the check value there.
    static func protect(_ record: Data) -> Data {
        var stored = record
        stored.ntfsPut16(0x30, checkValue)
        for sector in 1...2 {
            let tail = sector * 512 - 2
            stored[0x30 + sector * 2] = stored[tail]
            stored[0x30 + sector * 2 + 1] = stored[tail + 1]
            stored.ntfsPut16(tail, checkValue)
        }
        return stored
    }

    static func recycleInfo(_ path: String, size: UInt64) -> Data {
        var info = Data(count: 0x1C)
        info.ntfsPut64(0, 2)
        info.ntfsPut64(8, size)
        info.ntfsPut64(0x10, fileTime(1_700_000_000))
        let units = Array(path.utf16) + [0]
        info.ntfsPut32(0x18, UInt32(units.count))
        for unit in units { info.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
        return info
    }

    /// Starts like a JPEG, then filler. Enough for the header check; never a whole photo.
    static func jpegLike(_ count: Int, seed: UInt32) -> Data {
        Data([0xFF, 0xD8, 0xFF, 0xE0]) + filler(count - 4, seed: seed)
    }

    static func filler(_ count: Int, seed: UInt32) -> Data {
        var bytes = Data(capacity: count)
        var state = seed &* 2_654_435_761 &+ 1
        while bytes.count < count {
            state = state &* 1_103_515_245 &+ 12345
            bytes.append(UInt8(truncatingIfNeeded: state >> 16))
        }
        return bytes
    }

    /// A tiny photo the JPEG carver accepts: frame header, scan header, scan data, end marker.
    static func carvableJPEG(fill: Int) -> Data {
        func marker(_ type: UInt8, _ payload: [UInt8]) -> Data {
            Data([0xFF, type, 0, UInt8(payload.count + 2)] + payload)
        }
        var jpeg = Data([0xFF, 0xD8])
        jpeg.append(marker(0xC0, [8, 0, 1, 0, 1, 1, 1, 0x11, 0]))
        jpeg.append(marker(0xDA, [1, 1, 0, 0, 0x3F, 0]))
        jpeg.append(contentsOf: (0..<fill).map { UInt8($0 % 200 + 1) })
        jpeg.append(contentsOf: [0xFF, 0xD9])
        return jpeg
    }
}

/// Attribute encoders for the hand-built records.
private enum Attr {
    static func resident(_ type: UInt32, _ value: Data, name: String = "") -> Data {
        let nameUnits = Array(name.utf16)
        let valueOffset = align(0x18 + nameUnits.count * 2)
        var attribute = Data(count: align(valueOffset + value.count))
        attribute.ntfsPut32(0, type)
        attribute.ntfsPut32(4, UInt32(attribute.count))
        attribute[9] = UInt8(nameUnits.count)
        attribute.ntfsPut16(0x0A, 0x18)
        attribute.ntfsPut32(0x10, UInt32(value.count))
        attribute.ntfsPut16(0x14, UInt16(valueOffset))
        for (index, unit) in nameUnits.enumerated() { attribute.ntfsPut16(0x18 + index * 2, unit) }
        attribute.replaceSubrange(valueOffset..<(valueOffset + value.count), with: value)
        return attribute
    }

    static func nonResident(
        _ type: UInt32,
        name: String = "",
        runs: [(Int?, Int)],
        size: Int,
        clusterSize: Int,
        firstVCN: Int = 0,
        flags: UInt16 = 0
    ) -> Data {
        let nameUnits = Array(name.utf16)
        let runOffset = align(0x40 + nameUnits.count * 2)
        let encoded = encode(runs)
        let clusters = runs.reduce(0) { $0 + $1.1 }
        var attribute = Data(count: align(runOffset + encoded.count))
        attribute.ntfsPut32(0, type)
        attribute.ntfsPut32(4, UInt32(attribute.count))
        attribute[8] = 1
        attribute[9] = UInt8(nameUnits.count)
        attribute.ntfsPut16(0x0A, 0x40)
        attribute.ntfsPut16(0x0C, flags)
        attribute.ntfsPut64(0x10, UInt64(firstVCN))
        attribute.ntfsPut64(0x18, UInt64(firstVCN + clusters - 1))
        attribute.ntfsPut16(0x20, UInt16(runOffset))
        if firstVCN == 0 {
            attribute.ntfsPut64(0x28, UInt64(clusters * clusterSize))
            attribute.ntfsPut64(0x30, UInt64(size))
            attribute.ntfsPut64(0x38, UInt64(size))
        }
        for (index, unit) in nameUnits.enumerated() { attribute.ntfsPut16(0x40 + index * 2, unit) }
        attribute.replaceSubrange(runOffset..<(runOffset + encoded.count), with: encoded)
        return attribute
    }

    static func standardInformation(_ modified: UInt64) -> Data {
        var value = Data(count: 0x48)
        value.ntfsPut64(0x00, modified)
        value.ntfsPut64(0x08, modified)
        value.ntfsPut64(0x10, modified)
        value.ntfsPut64(0x18, modified)
        value.ntfsPut32(0x20, 0x20)
        return resident(0x10, value)
    }

    static func fileName(_ name: String, parent: UInt64, namespace: UInt8 = 3) -> Data {
        let units = Array(name.utf16)
        var value = Data(count: 0x42 + units.count * 2)
        value.ntfsPut64(0, parent)
        value[0x40] = UInt8(units.count)
        value[0x41] = namespace
        for (index, unit) in units.enumerated() { value.ntfsPut16(0x42 + index * 2, unit) }
        return resident(0x30, value)
    }

    static func attributeList(_ entries: [(type: UInt32, reference: UInt64)]) -> Data {
        var value = Data()
        for entry in entries {
            var item = Data(count: 0x20)
            item.ntfsPut32(0, entry.type)
            item.ntfsPut16(4, 0x20)
            item[7] = 0x1A
            item.ntfsPut64(0x10, entry.reference)
            value.append(item)
        }
        return resident(0x20, value)
    }

    /// Packs runs the way NTFS does: lengths and offsets in as few bytes as fit, offsets relative to the last real run.
    static func encode(_ runs: [(Int?, Int)]) -> Data {
        var out = Data()
        var previous = 0
        for (lcn, length) in runs {
            let lengthBytes = minimalSigned(Int64(length))
            if let lcn {
                let offsetBytes = minimalSigned(Int64(lcn - previous))
                previous = lcn
                out.append(UInt8(offsetBytes.count << 4 | lengthBytes.count))
                out.append(contentsOf: lengthBytes)
                out.append(contentsOf: offsetBytes)
            } else {
                out.append(UInt8(lengthBytes.count))
                out.append(contentsOf: lengthBytes)
            }
        }
        out.append(0)
        return out
    }

    private static func minimalSigned(_ value: Int64) -> [UInt8] {
        var bytes: [UInt8] = []
        var rest = value
        repeat {
            let byte = UInt8(truncatingIfNeeded: rest)
            bytes.append(byte)
            rest >>= 8
            if (rest == 0 && byte & 0x80 == 0) || (rest == -1 && byte & 0x80 != 0) { break }
        } while true
        return bytes
    }

    private static func align(_ value: Int) -> Int { (value + 7) & ~7 }
}

fileprivate extension Data {
    mutating func ntfsPut16(_ offset: Int, _ value: UInt16) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8(value >> 8)
    }

    mutating func ntfsPut32(_ offset: Int, _ value: UInt32) {
        for index in 0..<4 { self[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xFF) }
    }

    mutating func ntfsPut64(_ offset: Int, _ value: UInt64) {
        for index in 0..<8 { self[offset + index] = UInt8((value >> (8 * UInt64(index))) & 0xFF) }
    }
}

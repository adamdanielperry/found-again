import CoreGraphics
import XCTest
@testable import DataRecoverCore

/// Each format is placed on a sector boundary inside blank space, found by the deep scan,
/// measured to the exact byte and read back unchanged.
final class FormatCarveTests: XCTestCase {
    // MARK: TIFF and camera raw

    func testTIFFFromSips() throws {
        let tiff = try Fixtures.sips("tiff")
        try assertCarved(tiff, kind: .tiff)
    }

    func testNEFWithSubIFDsAndEXIF() throws {
        let raw = try RawSamples.nef()
        let file = try assertCarved(raw.data, kind: .nef)
        XCTAssertEqual(file.device, "NIKON D850")
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour], from: try XCTUnwrap(file.modified))
        XCTAssertEqual(parts.year, 2023)
        XCTAssertEqual(parts.month, 11)
        XCTAssertEqual(parts.day, 2)
        XCTAssertEqual(parts.hour, 14)
    }

    func testCR2IsToldApartByItsHeader() throws {
        let writer = TIFFWriter(header: [0x49, 0x49, 0x2A, 0x00, 0, 0, 0, 0, 0x43, 0x52, 2, 0, 0, 0, 0, 0])
        let preview = try Fixtures.jpeg()
        let previewAt = writer.append(preview)
        let sensor = writer.append(Fixtures.noise(9000, seed: 3))
        let rawIFD = writer.writeIFD([
            writer.short(0x0103, [6]),
            writer.long(0x0111, [sensor]),
            writer.long(0x0117, [9000]),
        ]).offset
        let ifd0 = writer.writeIFD([
            writer.long(0x0100, [8]), writer.long(0x0101, [8]), writer.short(0x0103, [6]),
            writer.ascii(0x010F, "Canon"), writer.ascii(0x0110, "Canon EOS 5D Mark IV"),
            writer.long(0x0111, [previewAt]), writer.long(0x0117, [UInt32(preview.count)]),
        ], next: rawIFD).offset
        writer.setFirstIFD(ifd0)
        let file = try assertCarved(writer.data, kind: .cr2)
        XCTAssertEqual(file.device, "Canon EOS 5D Mark IV")
    }

    func testDNGWithTiles() throws {
        let writer = TIFFWriter(header: [0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 0])
        let tiles = (0..<4).map { writer.append(Fixtures.noise(1000 + $0 * 10, seed: UInt32($0))) }
        let ifd0 = writer.writeIFD([
            writer.long(0x0100, [64]), writer.long(0x0101, [64]), writer.short(0x0106, [32803]),
            writer.ascii(0x010F, "Leica Camera AG"),
            writer.long(0x0144, tiles), writer.long(0x0145, (0..<4).map { UInt32(1000 + $0 * 10) }),
            TIFFEntry(tag: 0xC612, type: 1, count: 4, payload: Data([1, 4, 0, 0])),
        ]).offset
        writer.setFirstIFD(ifd0)
        try assertCarved(writer.data, kind: .dng)
    }

    func testORF() throws {
        let writer = TIFFWriter(header: Array("IIRO".utf8) + [0, 0, 0, 0])
        let sensor = writer.append(Fixtures.noise(12_345, seed: 9))
        let ifd0 = writer.writeIFD([
            writer.long(0x0100, [40]), writer.long(0x0101, [30]), writer.short(0x0106, [32803]),
            writer.ascii(0x010F, "OM Digital Solutions"), writer.long(0x0111, [sensor]), writer.long(0x0117, [12_345]),
        ]).offset
        writer.setFirstIFD(ifd0)
        try assertCarved(writer.data, kind: .orf)
    }

    func testRW2WithItsSensorLengthLeftOutRunsToTheNextBlankSector() throws {
        // 112 x 64 pixels in Panasonic's 14-pixels-per-16-bytes packing is 8192 bytes.
        let preview = try Fixtures.jpeg()
        let writer = TIFFWriter(header: [0x49, 0x49, 0x55, 0x00, 0, 0, 0, 0])
        let previewAt = writer.append(preview)
        let ifd = writer.writeIFD([
            writer.short(0x0002, [112]), writer.short(0x0003, [64]), writer.short(0x000A, [12]), writer.short(0x002D, [4]),
            TIFFEntry(tag: 0x002E, type: 7, count: UInt32(preview.count), payload: Data(), pointer: previewAt),
            writer.ascii(0x010F, "Panasonic"), writer.long(0x0111, [0]), writer.long(0x0118, [0]),
        ])
        writer.setFirstIFD(ifd.offset)
        let sensor = writer.append(Fixtures.noise(8192, seed: 5))
        writer.patch32(at: try XCTUnwrap(ifd.fields[0x0111]), sensor)
        writer.patch32(at: try XCTUnwrap(ifd.fields[0x0118]), sensor)
        let raw = writer.data
        let (result, reader) = try scan(raw, at: 2048)
        let file = try XCTUnwrap(result.files.first { $0.ranges.first?.offset == 2048 })
        XCTAssertEqual(file.kind, .rw2)
        // The length is only known to the sector, so up to 511 bytes of blank space come along.
        XCTAssertEqual(file.size, (UInt64(raw.count) + 511) / 512 * 512)
        XCTAssertEqual(try RecoveryEngine.read(file, from: reader, maxBytes: raw.count), raw)

        let thumbnail = try XCTUnwrap(Previews.imageData(for: file, reader: reader))
        XCTAssertEqual(thumbnail, preview)
    }

    func testTIFFWhoseImageRunsPastTheDiskIsNotReported() throws {
        let raw = try RawSamples.nef().data
        let cut = raw.prefix(raw.count - 2000)
        var disk = Data(count: 1024)
        disk.append(cut)
        let result = try RecoveryEngine.scan(reader: DataBlockReader(disk), options: ScanOptions(deepScan: true))
        XCTAssertFalse(result.files.contains { $0.ranges.first?.offset == 1024 }, "\(result.files.map(\.kind))")
    }

    func testTIFFHeaderOverRandomBytesIsNotReported() throws {
        var bogus = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0, 0, 0])
        bogus.append(Fixtures.noise(4000, seed: 77))
        try assertNotCarved(bogus)
    }

    // MARK: PNG and GIF

    func testPNGFromSips() throws {
        try assertCarved(try Fixtures.sips("png"), kind: .png)
    }

    func testTruncatedPNGIsNotReported() throws {
        let png = try Fixtures.sips("png")
        try assertNotCarved(png.prefix(png.count - 12))
    }

    func testGIFFromSips() throws {
        try assertCarved(try Fixtures.sips("gif"), kind: .gif)
    }

    func testTruncatedGIFIsNotReported() throws {
        let gif = try Fixtures.sips("gif")
        try assertNotCarved(gif.prefix(gif.count - 40))
    }

    // MARK: RIFF

    func testWAVFromAfconvert() throws {
        try assertCarved(try Fixtures.audio(format: "WAVE", data: "LEI16", ext: "wav"), kind: .wav)
    }

    func testAVIWithAnOpenDMLExtension() throws {
        let avi = RIFFSamples.avi(extended: true)
        try assertCarved(avi, kind: .avi)
    }

    func testWebPWithAnOddSizedChunk() throws {
        try assertCarved(RIFFSamples.webp(), kind: .webp)
    }

    func testRIFFHeaderOverRandomBytesIsNotReported() throws {
        var bogus = Data("RIFF".utf8)
        bogus.append(contentsOf: [0x00, 0x10, 0x00, 0x00])
        bogus.append(Data("WAVEfmt ".utf8))
        bogus.append(Fixtures.noise(5000, seed: 11))
        try assertNotCarved(bogus)
    }

    func testWAVWhoseSizeOverstatesItsChunksIsNotReported() throws {
        var wav = try Fixtures.audio(format: "WAVE", data: "LEI16", ext: "wav")
        let declared = UInt32(wav.count - 8 + 4096)
        wav.replaceSubrange(4..<8, with: Fixtures.le32(declared))
        try assertNotCarved(wav)
    }

    // MARK: PDF

    func testPDFFromCoreGraphics() throws {
        let pdf = try PDFSamples.quartz()
        try assertCarved(pdf, kind: .pdf)
    }

    func testPDFWithAnIncrementalUpdateIsKeptWhole() throws {
        let pdf = PDFSamples.incremental()
        let file = try assertCarved(pdf, kind: .pdf)
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: try XCTUnwrap(file.modified))
        XCTAssertEqual(parts.year, 2024)
        XCTAssertEqual(parts.hour, 7)
    }

    func testPDFEndsAtItsMarkerWhenOldDocumentBytesFollow() throws {
        let pdf = try PDFSamples.quartz()
        // Slack space after a file often holds an older document's bytes, mid-object.
        let leftover = Data("ream\nendstream\nendobj\n7 0 obj\n<< /Type /Page >>\nendobj\nstartxref\n50\n%%EOF\n".utf8)
        let (result, reader) = try scan(pdf + leftover, at: 1024)
        let file = try XCTUnwrap(result.files.first { $0.ranges.first?.offset == 1024 })
        XCTAssertEqual(file.size, UInt64(pdf.count))
        XCTAssertEqual(try RecoveryEngine.read(file, from: reader, maxBytes: pdf.count + 100), pdf)
    }

    func testPDFWithoutAnEndMarkerIsNotReported() throws {
        try assertNotCarved(Data(PDFSamples.body().utf8))
        // "%%EOF" inside a stream, without startxref before it, is not an ending.
        try assertNotCarved(Data((PDFSamples.body() + "4 0 obj\n<< /Length 20 >>\nstream\nxx %%EOF\nendstream\n").utf8))
    }

    // MARK: ZIP family

    func testZIPFromTheZipTool() throws {
        let zip = try ZIPSamples.make(files: ["notes.txt": Data("hello hello hello".utf8), "folder/data.bin": Fixtures.noise(3000, seed: 1)], tool: .zip)
        try assertCarved(zip, kind: .zip)
    }

    func testZIPWithDataDescriptorsFromDitto() throws {
        let zip = try ZIPSamples.make(files: ["a.txt": Data(repeating: 0x41, count: 5000), "b.bin": Fixtures.noise(3000, seed: 2)], tool: .ditto)
        try assertCarved(zip, kind: .zip)
    }

    func testZIP64EndRecords() throws {
        let zip = try ZIPSamples.make(files: ["a.txt": Data(repeating: 0x41, count: 5000), "b.bin": Fixtures.noise(3000, seed: 2)], tool: .zip64)
        try assertCarved(zip, kind: .zip)
    }

    func testZIPWithABlockBeforeItsCentralDirectoryIsFoundByItsEndRecord() throws {
        var zip = try ZIPSamples.make(files: ["a.txt": Data(repeating: 0x41, count: 5000), "b.bin": Fixtures.noise(3000, seed: 2)], tool: .zip)
        // Like an Android signing block: bytes the entry walk doesn't understand, with the end record adjusted to match.
        let end = zip.count - 22
        let cdOffset = Int(UInt32(zip[end + 16]) | UInt32(zip[end + 17]) << 8 | UInt32(zip[end + 18]) << 16 | UInt32(zip[end + 19]) << 24)
        let block = Data("APK Sig Block 42".utf8) + Fixtures.noise(200, seed: 6)
        zip.insert(contentsOf: block, at: cdOffset)
        zip.replaceSubrange((end + block.count + 16)..<(end + block.count + 20), with: Fixtures.le32(UInt32(cdOffset + block.count)))
        try assertCarved(zip, kind: .zip)
    }

    func testDOCXFromTextutil() throws {
        try assertCarved(try Fixtures.textutil("docx"), kind: .docx)
    }

    func testXLSXAndPPTXAreToldApartByTheirFolders() throws {
        let xlsx = try ZIPSamples.make(files: ["[Content_Types].xml": Data("<Types/>".utf8), "xl/workbook.xml": Data("<workbook/>".utf8)], tool: .zip)
        try assertCarved(xlsx, kind: .xlsx)
        let pptx = try ZIPSamples.make(files: ["[Content_Types].xml": Data("<Types/>".utf8), "ppt/presentation.xml": Data("<p/>".utf8)], tool: .zip)
        try assertCarved(pptx, kind: .pptx)
    }

    func testEPUBIsRecognizedByItsMimetypeEntry() throws {
        let epub = try ZIPSamples.epub()
        try assertCarved(epub, kind: .epub)
    }

    func testIWorkDocuments() throws {
        let keynote = try ZIPSamples.make(files: ["Index/Document.iwa": Fixtures.noise(300, seed: 1), "Index/Slide-1.iwa": Fixtures.noise(200, seed: 2)], tool: .zip)
        try assertCarved(keynote, kind: .keynote)
        let numbers = try ZIPSamples.make(files: ["Index/Document.iwa": Fixtures.noise(300, seed: 1), "Index/CalculationEngine.iwa": Fixtures.noise(200, seed: 2)], tool: .zip)
        try assertCarved(numbers, kind: .numbers)
        let pages = try ZIPSamples.make(files: ["Index/Document.iwa": Fixtures.noise(300, seed: 1), "Metadata/Properties.plist": Data("<plist/>".utf8)], tool: .zip)
        try assertCarved(pages, kind: .pages)
    }

    func testZIPCutBeforeItsEndRecordIsNotReported() throws {
        let zip = try ZIPSamples.make(files: ["a.txt": Data(repeating: 0x41, count: 5000), "b.bin": Fixtures.noise(3000, seed: 2)], tool: .ditto)
        try assertNotCarved(zip.prefix(zip.count - 30))
        let plain = try ZIPSamples.make(files: ["a.txt": Data(repeating: 0x41, count: 5000)], tool: .zip)
        try assertNotCarved(plain.prefix(plain.count - 30))
    }

    // MARK: OLE2

    func testDOCFromTextutil() throws {
        try assertCarved(try Fixtures.textutil("doc"), kind: .doc)
    }

    func testXLSAndPPTAreToldApartByTheirStreams() throws {
        try assertCarved(OLESamples.make(stream: "Workbook"), kind: .xls)
        try assertCarved(OLESamples.make(stream: "PowerPoint Document"), kind: .ppt)
    }

    func testOtherCompoundFilesAreNotReported() throws {
        try assertNotCarved(OLESamples.make(stream: "__substg1.0_0037001F"))
    }

    // MARK: Audio

    func testMP3WithID3TagsKeepsTheSongName() throws {
        let mp3 = MP3Samples.make(frames: 20)
        let file = try assertCarved(mp3, kind: .mp3)
        XCTAssertEqual(file.name, "Test Artist - Test Title.mp3")
    }

    func testID3TagWithTooFewFramesIsNotReported() throws {
        try assertNotCarved(MP3Samples.make(frames: 4))
    }

    func testFLACFromAfconvert() throws {
        let flac = try Fixtures.audio(format: "flac", data: "flac", ext: "flac")
        let file = try assertCarved(flac, kind: .flac)
        XCTAssertTrue(file.complete)
    }

    func testFLACCutInTheLastFrameKeepsTheWholeFrames() throws {
        let flac = try Fixtures.audio(format: "flac", data: "flac", ext: "flac")
        let cut = flac.prefix(flac.count - 100)
        let (result, _) = try scan(Data(cut), at: 1024)
        let file = try XCTUnwrap(result.files.first { $0.ranges.first?.offset == 1024 })
        XCTAssertEqual(file.kind, .flac)
        XCTAssertFalse(file.complete)
        XCTAssertLessThan(file.size, UInt64(cut.count))
        XCTAssertGreaterThan(file.size, UInt64(cut.count / 2))
    }

    // MARK: Matroska

    func testWebMWithAKnownSegmentSize() throws {
        let file = try assertCarved(MatroskaSamples.make(docType: "webm", unknownSizes: false), kind: .webm)
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: try XCTUnwrap(file.modified))
        XCTAssertEqual(parts.year, 2022)
    }

    func testLiveRecordingWithUnknownSizesIsWalked() throws {
        try assertCarved(MatroskaSamples.make(docType: "matroska", unknownSizes: true), kind: .mkv)
    }

    func testMatroskaWithAnUnknownDocTypeIsNotReported() throws {
        try assertNotCarved(MatroskaSamples.make(docType: "nonsense", unknownSizes: false))
    }

    // MARK: PSD and BMP

    func testPSDFromSips() throws {
        try assertCarved(try Fixtures.sips("psd"), kind: .psd)
    }

    func testPSDRunningPastTheDiskIsNotReported() throws {
        // Nothing inside a PSD marks its end, so a cut is only visible when the image would run off the disk.
        let psd = try Fixtures.sips("psd")
        var disk = Data(count: 1024)
        disk.append(psd.prefix(psd.count - 100))
        let result = try RecoveryEngine.scan(reader: DataBlockReader(disk), options: ScanOptions(deepScan: true))
        XCTAssertTrue(result.files.isEmpty, "\(result.files.map(\.kind))")
    }

    func testBMPFromSips() throws {
        try assertCarved(try Fixtures.sips("bmp"), kind: .bmp)
    }

    func testBMPrefixOverRandomBytesIsNotReported() throws {
        for seed in UInt32(1)...20 {
            var bogus = Data("BM".utf8)
            bogus.append(Fixtures.noise(3000, seed: seed))
            try assertNotCarved(bogus)
        }
        // A real header whose size field is far larger than its pixels.
        var bmp = try Fixtures.sips("bmp")
        bmp.replaceSubrange(2..<6, with: Fixtures.le32(UInt32(bmp.count + 50_000)))
        try assertNotCarved(bmp)
    }

    // MARK: Several files

    func testLeadByteTableOnlyHoldsEachCarversOwnFirstBytes() {
        // Each carver declares its first bytes; a sector starting with anything else is skipped with one lookup.
        let busy = (0..<256).filter { !Registry.byLeadByte[$0].isEmpty }
        XCTAssertLessThan(busy.count, 20)
        XCTAssertTrue(Registry.byLeadByte[0x89].contains { $0 is PNGCarver })
        XCTAssertFalse(Registry.byLeadByte[0x89].contains { $0 is JPEGCarver })
    }

    func testFilesBackToBackAreAllFound() throws {
        let png = try Fixtures.sips("png")
        let gif = try Fixtures.sips("gif")
        let pdf = try PDFSamples.quartz()
        let second = (1024 + png.count + 511) / 512 * 512
        let third = (second + gif.count + 511) / 512 * 512
        var disk = Data(count: third + pdf.count + 4096)
        disk.replaceSubrange(1024..<(1024 + png.count), with: png)
        disk.replaceSubrange(second..<(second + gif.count), with: gif)
        disk.replaceSubrange(third..<(third + pdf.count), with: pdf)
        let result = try RecoveryEngine.scan(reader: DataBlockReader(disk), options: ScanOptions(deepScan: true))
        let found = result.files.map { "\($0.kind.rawValue)@\($0.ranges[0].offset)" }
        XCTAssertEqual(found, ["png@1024", "gif@\(second)", "pdf@\(third)"])
    }

    func testTwoPDFsInARowStayApart() throws {
        let first = PDFSamples.incremental()
        let second = try PDFSamples.quartz()
        let next = (512 + first.count + 511) / 512 * 512
        var disk = Data(count: next + second.count + 2048)
        disk.replaceSubrange(512..<(512 + first.count), with: first)
        disk.replaceSubrange(next..<(next + second.count), with: second)
        let result = try RecoveryEngine.scan(reader: DataBlockReader(disk), options: ScanOptions(deepScan: true))
        XCTAssertEqual(result.files.map(\.size), [UInt64(first.count), UInt64(second.count)])
    }
}

final class PreviewTests: XCTestCase {
    func testJPEGPreviewIsTheFileStart() throws {
        let jpeg = try Fixtures.jpeg()
        let (result, reader) = try scan(jpeg, at: 1024)
        let file = try XCTUnwrap(result.files.first)
        XCTAssertEqual(Previews.imageData(for: file, reader: reader), jpeg)
    }

    func testPNGPreviewIsTheWholeFile() throws {
        let png = try Fixtures.sips("png")
        let (result, reader) = try scan(png, at: 1024)
        let file = try XCTUnwrap(result.files.first)
        XCTAssertEqual(Previews.imageData(for: file, reader: reader), png)
        XCTAssertNil(Previews.imageData(for: file, reader: reader, maxBytes: 10))
    }

    func testNEFPreviewIsItsLargestEmbeddedJPEG() throws {
        let raw = try RawSamples.nef()
        let (result, reader) = try scan(raw.data, at: 1536)
        let file = try XCTUnwrap(result.files.first { $0.kind == .nef })
        XCTAssertEqual(Previews.imageData(for: file, reader: reader), raw.preview)
    }

    func testRAFPreviewComesFromTheHeaderTable() throws {
        let jpeg = try Fixtures.jpeg()
        var raf = Data(count: 0x80)
        raf.replaceSubrange(0..<16, with: Data("FUJIFILMCCD-RAW ".utf8))
        let sensor = Fixtures.noise(4000, seed: 4)
        let fields: [(Int, Int)] = [(0x54, 0x80), (0x58, jpeg.count), (0x5C, 0x80 + jpeg.count), (0x60, 0), (0x64, 0x80 + jpeg.count), (0x68, sensor.count)]
        for (offset, value) in fields {
            raf.replaceSubrange(offset..<(offset + 4), with: Fixtures.be32(UInt32(value)))
        }
        raf.append(jpeg)
        raf.append(sensor)
        let (result, reader) = try scan(raf, at: 0)
        let file = try XCTUnwrap(result.files.first { $0.kind == .raf })
        XCTAssertEqual(Previews.imageData(for: file, reader: reader), jpeg)
    }

    func testKindsWithoutPicturesHaveNoPreview() throws {
        let pdf = try PDFSamples.quartz()
        let (result, reader) = try scan(pdf, at: 1024)
        let file = try XCTUnwrap(result.files.first)
        XCTAssertNil(Previews.imageData(for: file, reader: reader))
    }
}

// MARK: - Helpers

/// Places `data` at `offset` in blank space and scans it.
private func scan(_ data: Data, at offset: Int) throws -> (ScanResult, DataBlockReader) {
    var disk = Data(count: offset + data.count + 4096)
    disk.replaceSubrange(offset..<(offset + data.count), with: data)
    let reader = DataBlockReader(disk)
    return (try RecoveryEngine.scan(reader: reader, options: ScanOptions(deepScan: true)), reader)
}

@discardableResult
private func assertCarved(_ data: Data, kind: FileKind, at offset: Int = 1024, file: StaticString = #filePath, line: UInt = #line) throws -> RecoverableFile {
    let (result, reader) = try scan(data, at: offset)
    let found = try XCTUnwrap(result.files.first { $0.ranges.first?.offset == UInt64(offset) },
                              "nothing found at \(offset); found \(result.files.map { "\($0.kind)@\($0.ranges[0].offset)" })", file: file, line: line)
    XCTAssertEqual(found.kind, kind, file: file, line: line)
    XCTAssertEqual(found.size, UInt64(data.count), file: file, line: line)
    XCTAssertEqual(found.confidence, .carved, file: file, line: line)
    XCTAssertEqual(try RecoveryEngine.read(found, from: reader, maxBytes: data.count + 100), data, file: file, line: line)
    return found
}

private func assertNotCarved(_ data: Data, at offset: Int = 1024, file: StaticString = #filePath, line: UInt = #line) throws {
    let (result, _) = try scan(data, at: offset)
    let found = result.files.filter { $0.ranges.first?.offset == UInt64(offset) }
    XCTAssertTrue(found.isEmpty, "unexpectedly found \(found.map { "\($0.kind) \($0.size)" })", file: file, line: line)
}

private enum Fixtures {
    /// Deterministic bytes that look like compressed data.
    static func noise(_ count: Int, seed: UInt32) -> Data {
        var state = seed &* 2_654_435_761 | 1
        var data = Data(capacity: count)
        for _ in 0..<count {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            data.append(UInt8(truncatingIfNeeded: state))
        }
        return data
    }

    static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }

    static func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dr-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A small picture written by macOS's own image tools.
    static func sips(_ format: String) throws -> Data {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ppm = folder.appendingPathComponent("in.ppm")
        let out = folder.appendingPathComponent("out.\(format)")
        var image = Data("P6 37 23 255\n".utf8)
        for y in 0..<23 {
            for x in 0..<(37 * 3) { image.append(UInt8((x * 7 + y * 3) & 0xFF)) }
        }
        try image.write(to: ppm)
        try Tool.run("/usr/bin/sips", ["-s", "format", format, ppm.path, "--out", out.path])
        return try Data(contentsOf: out)
    }

    static func jpeg() throws -> Data {
        try sips("jpeg")
    }

    /// One second of a tone, converted by afconvert.
    static func audio(format: String, data: String, ext: String) throws -> Data {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tone.wav")
        let out = folder.appendingPathComponent("out.\(ext)")
        var samples = Data()
        for index in 0..<44_100 {
            let value = Int16(8000 * sin(Double(index) * 0.05) + 300 * sin(Double(index) * 0.31))
            samples.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init))
        }
        var wav = Data("RIFF".utf8) + le32(UInt32(36 + samples.count)) + Data("WAVEfmt ".utf8)
        wav += le32(16) + Data([1, 0, 1, 0]) + le32(44_100) + le32(88_200) + Data([2, 0, 16, 0])
        wav += Data("data".utf8) + le32(UInt32(samples.count)) + samples
        try wav.write(to: source)
        try Tool.run("/usr/bin/afconvert", ["-f", format, "-d", data, source.path, out.path])
        return try Data(contentsOf: out)
    }

    static func textutil(_ format: String) throws -> Data {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("in.txt")
        let out = folder.appendingPathComponent("out.\(format)")
        try Data(String(repeating: "Recovered words. ", count: 50).utf8).write(to: text)
        try Tool.run("/usr/bin/textutil", ["-convert", format, text.path, "-output", out.path])
        return try Data(contentsOf: out)
    }
}

private enum Tool {
    @discardableResult
    static func run(_ program: String, _ arguments: [String], in directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "tool", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(program) \(arguments.joined(separator: " "))\n\(text)",
            ])
        }
        return text
    }
}

// MARK: TIFF building

private struct TIFFEntry {
    var tag: UInt16
    var type: UInt16
    var count: UInt32
    /// Value bytes in the file's byte order. Values over four bytes are stored elsewhere.
    var payload: Data
    /// For values already in the file, where they are.
    var pointer: UInt32?
}

private final class TIFFWriter {
    let little: Bool
    private(set) var data: Data

    init(header: [UInt8]) {
        little = header[0] == 0x49
        data = Data(header)
    }

    func u16(_ value: UInt16) -> Data {
        little ? Data([UInt8(value & 0xFF), UInt8(value >> 8)]) : Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    func u32(_ value: UInt32) -> Data {
        little ? Fixtures.le32(value) : Fixtures.be32(value)
    }

    func short(_ tag: UInt16, _ values: [UInt16]) -> TIFFEntry {
        TIFFEntry(tag: tag, type: 3, count: UInt32(values.count), payload: values.reduce(Data()) { $0 + u16($1) })
    }

    func long(_ tag: UInt16, _ values: [UInt32]) -> TIFFEntry {
        TIFFEntry(tag: tag, type: 4, count: UInt32(values.count), payload: values.reduce(Data()) { $0 + u32($1) })
    }

    func ascii(_ tag: UInt16, _ text: String) -> TIFFEntry {
        let bytes = Data(text.utf8) + Data([0])
        return TIFFEntry(tag: tag, type: 2, count: UInt32(bytes.count), payload: bytes)
    }

    /// Appends bytes on an even offset and returns where they went.
    @discardableResult
    func append(_ blob: Data) -> UInt32 {
        if data.count % 2 == 1 { data.append(0) }
        let at = UInt32(data.count)
        data.append(blob)
        return at
    }

    /// Writes a directory after its out-of-line values. Returns its offset and where each entry's value field is.
    func writeIFD(_ entries: [TIFFEntry], next: UInt32 = 0) -> (offset: UInt32, fields: [UInt16: Int]) {
        var fields: [(TIFFEntry, Data)] = []
        for entry in entries.sorted(by: { $0.tag < $1.tag }) {
            if let pointer = entry.pointer {
                fields.append((entry, u32(pointer)))
            } else if entry.payload.count <= 4 {
                fields.append((entry, entry.payload + Data(count: 4 - entry.payload.count)))
            } else {
                fields.append((entry, u32(append(entry.payload))))
            }
        }
        if data.count % 2 == 1 { data.append(0) }
        let offset = UInt32(data.count)
        var positions: [UInt16: Int] = [:]
        data.append(u16(UInt16(fields.count)))
        for (entry, field) in fields {
            data.append(u16(entry.tag))
            data.append(u16(entry.type))
            data.append(u32(entry.count))
            positions[entry.tag] = data.count
            data.append(field)
        }
        data.append(u32(next))
        return (offset, positions)
    }

    func setFirstIFD(_ offset: UInt32) {
        patch32(at: 4, offset)
    }

    func patch32(at position: Int, _ value: UInt32) {
        data.replaceSubrange(position..<(position + 4), with: u32(value))
    }
}

private enum RawSamples {
    struct Sample {
        var data: Data
        var preview: Data
    }

    /// A NEF laid out like Nikon's: a small IFD0, a preview SubIFD, a sensor SubIFD and an EXIF directory.
    static func nef() throws -> Sample {
        let preview = try Fixtures.jpeg()
        let writer = TIFFWriter(header: [0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 0])
        let thumbnail = writer.append(Fixtures.noise(600, seed: 21))
        let previewAt = writer.append(preview)
        let sensor = writer.append(Fixtures.noise(20_000, seed: 22))
        let previewIFD = writer.writeIFD([
            writer.long(0x00FE, [1]), writer.short(0x0103, [6]),
            writer.long(0x0201, [previewAt]), writer.long(0x0202, [UInt32(preview.count)]),
        ]).offset
        let sensorIFD = writer.writeIFD([
            writer.long(0x00FE, [0]), writer.long(0x0100, [100]), writer.long(0x0101, [100]), writer.short(0x0103, [34713]),
            writer.short(0x0106, [32803]), writer.long(0x0111, [sensor]), writer.long(0x0117, [20_000]),
        ]).offset
        let exifIFD = writer.writeIFD([
            writer.ascii(0x9003, "2023:11:02 14:15:16"),
            TIFFEntry(tag: 0x927C, type: 7, count: 40, payload: Fixtures.noise(40, seed: 23)),
        ]).offset
        let ifd0 = writer.writeIFD([
            writer.long(0x00FE, [1]), writer.long(0x0100, [16]), writer.long(0x0101, [16]), writer.short(0x0103, [1]),
            writer.ascii(0x010F, "NIKON CORPORATION"), writer.ascii(0x0110, "NIKON D850"),
            writer.long(0x0111, [thumbnail]), writer.long(0x0117, [600]),
            writer.long(0x014A, [previewIFD, sensorIFD]), writer.long(0x8769, [exifIFD]),
        ]).offset
        writer.setFirstIFD(ifd0)
        return Sample(data: writer.data, preview: preview)
    }
}

// MARK: Other builders

private enum RIFFSamples {
    static func chunk(_ id: String, _ payload: Data) -> Data {
        var data = Data(id.utf8) + Fixtures.le32(UInt32(payload.count)) + payload
        if payload.count % 2 == 1 { data.append(0) }
        return data
    }

    static func riff(_ form: String, _ chunks: Data) -> Data {
        Data("RIFF".utf8) + Fixtures.le32(UInt32(4 + chunks.count)) + Data(form.utf8) + chunks
    }

    static func avi(extended: Bool) -> Data {
        let header = chunk("LIST", Data("hdrl".utf8) + chunk("avih", Data(count: 56)) + chunk("LIST", Data("strl".utf8) + chunk("strh", Data(count: 56))))
        let frames = chunk("00dc", Fixtures.noise(4001, seed: 1)) + chunk("00dc", Fixtures.noise(3000, seed: 2))
        let movie = chunk("LIST", Data("movi".utf8) + frames)
        let index = chunk("idx1", Data(count: 32))
        var avi = riff("AVI ", header + movie + index)
        if extended {
            avi += riff("AVIX", chunk("LIST", Data("movi".utf8) + chunk("00dc", Fixtures.noise(5000, seed: 3))))
        }
        return avi
    }

    static func webp() -> Data {
        riff("WEBP", chunk("VP8L", Data([0x2F]) + Fixtures.noise(12, seed: 4)) + chunk("EXIF", Data("II*\u{0}".utf8) + Data(count: 8)))
    }
}

private enum PDFSamples {
    static func quartz() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 120)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 100, height: 60))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static func body() -> String {
        "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n"
    }

    /// A document saved once, then edited in place: two sections, each ending with "%%EOF".
    static func incremental() -> Data {
        var text = body()
        let firstXref = text.utf8.count
        text += "xref\n0 3\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \ntrailer\n<< /Size 3 /Root 1 0 R >>\nstartxref\n\(firstXref)\n%%EOF\n"
        text += "3 0 obj\n<< /ModDate (D:20240506070809Z) /Producer (Test) >>\nendobj\n"
        let secondXref = text.utf8.count
        text += "xref\n0 1\n0000000000 65535 f \n3 1\n0000000200 00000 n \ntrailer\n<< /Size 4 /Root 1 0 R /Info 3 0 R /Prev \(firstXref) >>\nstartxref\n\(secondXref)\n%%EOF\n"
        return Data(text.utf8)
    }
}

private enum ZIPSamples {
    enum Maker {
        case zip
        /// Info-ZIP forced to write ZIP64 sizes and end records.
        case zip64
        case ditto
    }

    static func make(files: [String: Data], tool: Maker) throws -> Data {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let content = folder.appendingPathComponent("content", isDirectory: true)
        for (name, data) in files {
            let url = content.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let out = folder.appendingPathComponent("out.zip")
        switch tool {
        case .zip:
            try Tool.run("/usr/bin/zip", ["-qrX", out.path, "."], in: content)
        case .zip64:
            try Tool.run("/usr/bin/zip", ["-qrX", "-fz", out.path, "."], in: content)
        case .ditto:
            try Tool.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", content.path, out.path])
        }
        return try Data(contentsOf: out)
    }

    /// The mimetype entry must come first and be stored uncompressed.
    static func epub() throws -> Data {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("application/epub+zip".utf8).write(to: folder.appendingPathComponent("mimetype"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try Data("<container/>".utf8).write(to: folder.appendingPathComponent("META-INF/container.xml"))
        let out = folder.appendingPathComponent("book.epub")
        try Tool.run("/usr/bin/zip", ["-qX0", out.path, "mimetype"], in: folder)
        try Tool.run("/usr/bin/zip", ["-qrX", out.path, "META-INF"], in: folder)
        return try Data(contentsOf: out)
    }
}

private enum OLESamples {
    /// A version 3 compound file: header, one allocation-table sector, one directory sector and an 8-sector stream.
    static func make(stream name: String) -> Data {
        var header = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 16)
        header += Data([0x3E, 0x00, 0x03, 0x00, 0xFE, 0xFF, 0x09, 0x00, 0x06, 0x00]) + Data(count: 6)
        header += Fixtures.le32(0) + Fixtures.le32(1) + Fixtures.le32(1) + Fixtures.le32(0) + Fixtures.le32(4096)
        header += Fixtures.le32(0xFFFF_FFFE) + Fixtures.le32(0) + Fixtures.le32(0xFFFF_FFFE) + Fixtures.le32(0)
        header += Fixtures.le32(0)
        for _ in 1..<109 { header += Fixtures.le32(0xFFFF_FFFF) }

        var fat = Fixtures.le32(0xFFFF_FFFD) + Fixtures.le32(0xFFFF_FFFE)
        for sector in UInt32(2)..<9 { fat += Fixtures.le32(sector + 1) }
        fat += Fixtures.le32(0xFFFF_FFFE)
        while fat.count < 512 { fat += Fixtures.le32(0xFFFF_FFFF) }

        func entry(_ name: String, type: UInt8, start: UInt32, size: UInt32) -> Data {
            var record = Data(count: 128)
            let units = Array(name.utf16) + [0]
            for (index, unit) in units.enumerated() {
                record[index * 2] = UInt8(unit & 0xFF)
                record[index * 2 + 1] = UInt8(unit >> 8)
            }
            record[64] = UInt8(units.count * 2)
            record[66] = type
            for index in 68..<80 { record[index] = 0xFF }
            record.replaceSubrange(116..<120, with: Fixtures.le32(start))
            record.replaceSubrange(120..<124, with: Fixtures.le32(size))
            return record
        }
        var directory = entry("Root Entry", type: 5, start: 0xFFFF_FFFE, size: 0)
        directory += entry(name, type: 2, start: 2, size: 4096)
        directory += Data(count: 256)
        return header + fat + directory + Fixtures.noise(4096, seed: 8)
    }
}

private enum MP3Samples {
    static func make(frames: Int) -> Data {
        func textFrame(_ id: String, _ text: String) -> Data {
            let body = Data([0]) + Data(text.utf8)
            return Data(id.utf8) + Fixtures.be32(UInt32(body.count)) + Data([0, 0]) + body
        }
        let frameData = textFrame("TIT2", "Test Title") + textFrame("TPE1", "Test Artist") + Data(count: 64)
        let size = frameData.count
        let syncsafe = Data([UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)])
        var mp3 = Data("ID3".utf8) + Data([3, 0, 0]) + syncsafe + frameData
        // MPEG-1 layer III, 128 kbit/s, 44.1 kHz: 417 bytes a frame, or 418 with padding.
        for index in 0..<frames {
            let padded = index % 3 == 1
            mp3 += Data([0xFF, 0xFB, padded ? 0x92 : 0x90, 0x64])
            mp3 += Fixtures.noise(padded ? 414 : 413, seed: UInt32(index + 1)).map { $0 == 0xFF ? 0xFE : $0 }
        }
        mp3 += Data("TAG".utf8) + Data(count: 125)
        return mp3
    }
}

private enum MatroskaSamples {
    static func element(_ id: [UInt8], _ payload: Data, unknownSize: Bool = false) -> Data {
        var size = Data([0x01])
        if unknownSize {
            size += Data(repeating: 0xFF, count: 7)
        } else {
            let length = UInt64(payload.count)
            for shift in stride(from: 48, through: 0, by: -8) { size.append(UInt8((length >> UInt64(shift)) & 0xFF)) }
        }
        return Data(id) + size + payload
    }

    static func make(docType: String, unknownSizes: Bool) -> Data {
        let header = element([0x1A, 0x45, 0xDF, 0xA3],
                             element([0x42, 0x86], Data([1])) + element([0x42, 0xF7], Data([1])) + element([0x42, 0xF2], Data([4]))
                                 + element([0x42, 0xF3], Data([8])) + element([0x42, 0x82], Data(docType.utf8))
                                 + element([0x42, 0x87], Data([4])) + element([0x42, 0x85], Data([2])))
        // 2022-03-04 05:06:07 UTC, in nanoseconds since 2001.
        let nanoseconds = UInt64(Date(timeIntervalSince1970: 1_646_370_367).timeIntervalSinceReferenceDate) * 1_000_000_000
        var date = Data()
        for shift in stride(from: 56, through: 0, by: -8) { date.append(UInt8((nanoseconds >> UInt64(shift)) & 0xFF)) }
        let info = element([0x15, 0x49, 0xA9, 0x66], element([0x2A, 0xD7, 0xB1], Data([0x0F, 0x42, 0x40])) + element([0x44, 0x61], date))
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], element([0xAE], element([0xD7], Data([1])) + element([0x83], Data([1])) + element([0x86], Data("V_VP8".utf8))))
        var clusters = Data()
        for index in 0..<3 {
            let blocks = element([0xE7], Data([UInt8(index)])) + element([0xA3], Fixtures.noise(700 + index, seed: UInt32(index)))
                + element([0xA3], Fixtures.noise(300, seed: UInt32(index + 10)))
            clusters += element([0x1F, 0x43, 0xB6, 0x75], blocks, unknownSize: unknownSizes)
        }
        let segment = element([0x18, 0x53, 0x80, 0x67], info + tracks + clusters, unknownSize: unknownSizes)
        return header + segment
    }
}

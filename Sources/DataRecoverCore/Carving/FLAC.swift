import Foundation

/// FLAC: "fLaC", metadata blocks, then audio frames. Frames don't record their length, so each next frame is found
/// by its sync code, a header checksum and the frame number it must carry. The last frame is decoded to find its end.
struct FLACCarver: FormatCarver {
    static let maxSize: UInt64 = 1024 * 1024 * 1024

    var leadBytes: [UInt8]? { [0x66] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        // STREAMINFO always comes first and is always 34 bytes.
        guard head.count >= 22, head.starts(with: "fLaC"), head[4] & 0x7F == 0, head[5] == 0, head[6] == 0, head[7] == 34 else { return nil }
        let minBlock = head.u16be(8)
        let maxBlock = head.u16be(10)
        let sampleRate = (UInt32(head[18]) << 12) | (UInt32(head[19]) << 4) | (UInt32(head[20]) >> 4)
        guard minBlock >= 16, maxBlock >= minBlock, sampleRate > 0, sampleRate <= 655_350 else { return nil }
        return .flac
    }

    func carve(_ reader: BlockReader, at start: UInt64, kind: FileKind) throws -> Carved? {
        let end = min(reader.size, start + Self.maxSize)
        let bytes = ByteWindow(reader: reader, end: end)
        guard let info = bytes.bytes(at: start + 8, count: 34), info.count == 34 else { return nil }
        let stream = StreamInfo(info)

        var position = start + 4
        var blocks = 0
        while true {
            guard blocks < 1000, let header = bytes.u32be(at: position) else { return nil }
            let type = (header >> 24) & 0x7F
            guard type <= 6, blocks > 0 || type == 0 else { return nil }
            position += 4 + UInt64(header & 0xFF_FFFF)
            blocks += 1
            if header & 0x8000_0000 != 0 { break }
        }

        guard let first = FrameHeader.parse(bytes, at: position, stream: stream), first.number == 0 else { return nil }
        let variable = first.variable
        var current = first
        var currentStart = position
        var samples: UInt64 = 0
        var frames = 0
        while true {
            let next = variable ? current.number + UInt64(current.blockSize) : current.number + 1
            let reach = stream.maxFrame > 0
                ? UInt64(stream.maxFrame) + 16
                : UInt64(current.blockSize) * UInt64(stream.channels) * UInt64(stream.bitsPerSample / 8 + 1) + 1024
            guard let (nextStart, nextHeader) = Self.findFrame(bytes, after: currentStart, before: min(end, currentStart + reach + 16),
                                                             number: next, variable: variable, stream: stream)
            else { break }
            samples += UInt64(current.blockSize)
            frames += 1
            currentStart = nextStart
            current = nextHeader
        }

        // The last frame: decode it to find where it ends, and check its checksum.
        var complete = stream.totalSamples == 0 || samples + UInt64(current.blockSize) >= stream.totalSamples
        let size: UInt64
        if let length = Self.decodedLength(bytes, at: currentStart, header: current) {
            size = currentStart + UInt64(length) - start
            frames += 1
        } else {
            // It was cut off part way; keep the frames before it.
            size = currentStart - start
            complete = false
        }
        guard frames > 0 else { return nil }
        return Carved(kind: .flac, size: size, complete: complete)
    }

    private static func findFrame(_ bytes: ByteWindow, after frameStart: UInt64, before limit: UInt64, number: UInt64, variable: Bool,
                                  stream: StreamInfo) -> (UInt64, FrameHeader)? {
        var position = frameStart + 4
        let second: UInt8 = variable ? 0xF9 : 0xF8
        while position < limit, let sync = bytes.nextFF(from: position), sync < limit {
            if bytes.byte(at: sync + 1) == second, let header = FrameHeader.parse(bytes, at: sync, stream: stream),
               header.number == number {
                return (sync, header)
            }
            position = sync + 1
        }
        return nil
    }

    /// The fields of STREAMINFO the frame walk needs. Zero means "not recorded" for the frame size and sample count.
    struct StreamInfo {
        var maxFrame: UInt32
        var channels: Int
        var bitsPerSample: Int
        var totalSamples: UInt64

        init(_ data: Data) {
            maxFrame = (UInt32(data[7]) << 16) | (UInt32(data[8]) << 8) | UInt32(data[9])
            channels = Int((data[12] >> 1) & 0x07) + 1
            bitsPerSample = Int(((data[12] & 1) << 4) | (data[13] >> 4)) + 1
            totalSamples = (UInt64(data[13] & 0x0F) << 32) | (UInt64(data[14]) << 24) | (UInt64(data[15]) << 16) | (UInt64(data[16]) << 8) | UInt64(data[17])
        }
    }

    struct FrameHeader {
        var variable: Bool
        var blockSize: Int
        var channelAssignment: Int
        var bitsPerSample: Int
        /// Frame number for fixed-size blocks, first sample number for variable ones.
        var number: UInt64
        var length: Int

        static func parse(_ bytes: ByteWindow, at offset: UInt64, stream: StreamInfo) -> FrameHeader? {
            guard offset < bytes.end, let raw = bytes.bytes(at: offset, count: Int(min(16, bytes.end - offset))),
                  raw.count >= 6, raw[0] == 0xFF, raw[1] & 0xFE == 0xF8
            else { return nil }
            let blockCode = Int(raw[2] >> 4)
            let rateCode = Int(raw[2] & 0x0F)
            let assignment = Int(raw[3] >> 4)
            let sizeCode = Int((raw[3] >> 1) & 0x07)
            guard blockCode != 0, rateCode != 15, assignment <= 10, sizeCode != 3, raw[3] & 1 == 0 else { return nil }
            // The frame or sample number, in UTF-8's variable-length coding.
            var index = 4
            let lead = raw[index]
            var extra = 0
            var number: UInt64
            switch lead {
            case 0x00...0x7F: number = UInt64(lead)
            case 0xC0...0xDF: number = UInt64(lead & 0x1F); extra = 1
            case 0xE0...0xEF: number = UInt64(lead & 0x0F); extra = 2
            case 0xF0...0xF7: number = UInt64(lead & 0x07); extra = 3
            case 0xF8...0xFB: number = UInt64(lead & 0x03); extra = 4
            case 0xFC...0xFD: number = UInt64(lead & 0x01); extra = 5
            case 0xFE: number = 0; extra = 6
            default: return nil
            }
            index += 1
            guard index + extra < raw.count else { return nil }
            for _ in 0..<extra {
                guard raw[index] & 0xC0 == 0x80 else { return nil }
                number = (number << 6) | UInt64(raw[index] & 0x3F)
                index += 1
            }
            var blockSize: Int
            switch blockCode {
            case 1: blockSize = 192
            case 2...5: blockSize = 576 << (blockCode - 2)
            case 6:
                guard index < raw.count else { return nil }
                blockSize = Int(raw[index]) + 1
                index += 1
            case 7:
                guard index + 1 < raw.count else { return nil }
                blockSize = (Int(raw[index]) << 8 | Int(raw[index + 1])) + 1
                index += 2
            default: blockSize = 256 << (blockCode - 8)
            }
            switch rateCode {
            case 12: index += 1
            case 13, 14: index += 2
            default: break
            }
            guard index < raw.count, CRC.crc8(raw.prefix(index)) == raw[index] else { return nil }
            let sizes = [stream.bitsPerSample, 8, 12, 0, 16, 20, 24, 32]
            return FrameHeader(variable: raw[1] == 0xF9, blockSize: blockSize, channelAssignment: assignment,
                               bitsPerSample: sizes[sizeCode], number: number, length: index + 1)
        }
    }

    /// Decodes a frame's subframes to find where it ends, and checks its CRC-16. Nil when it doesn't add up.
    private static func decodedLength(_ bytes: ByteWindow, at offset: UInt64, header: FrameHeader) -> Int? {
        let channels = header.channelAssignment < 8 ? header.channelAssignment + 1 : 2
        let worst = header.length + channels * header.blockSize * (header.bitsPerSample + 1) / 8 + channels * 64 + 2
        let available = Int(min(UInt64(worst), bytes.end - offset))
        guard available > header.length, let data = bytes.bytes(at: offset, count: available) else { return nil }
        let frame = [UInt8](data)
        var bits = BitReader(frame, bit: header.length * 8)
        for channel in 0..<channels {
            var sampleBits = header.bitsPerSample
            // Stereo decorrelation stores the side channel with one extra bit.
            switch (header.channelAssignment, channel) {
            case (8, 1), (9, 0), (10, 1): sampleBits += 1
            default: break
            }
            guard bits.skipSubframe(sampleBits: sampleBits, blockSize: header.blockSize) else { return nil }
        }
        let end = (bits.bit + 7) / 8
        guard end + 2 <= frame.count else { return nil }
        let stored = UInt16(frame[end]) << 8 | UInt16(frame[end + 1])
        guard CRC.crc16(frame[0..<end]) == stored else { return nil }
        return end + 2
    }

    /// Reads a FLAC bit stream, most significant bit first.
    struct BitReader {
        let bytes: [UInt8]
        var bit: Int

        init(_ bytes: [UInt8], bit: Int) {
            self.bytes = bytes
            self.bit = bit
        }

        mutating func read(_ count: Int) -> UInt32? {
            guard count <= 32, bit + count <= bytes.count * 8 else { return nil }
            var value: UInt32 = 0
            for _ in 0..<count {
                let byte = bytes[bit >> 3]
                value = (value << 1) | UInt32((byte >> (7 - UInt8(bit & 7))) & 1)
                bit += 1
            }
            return value
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, bit + count <= bytes.count * 8 else { return false }
            bit += count
            return true
        }

        /// Counts zero bits up to the next one bit, and steps past it.
        mutating func unary() -> Int? {
            var zeros = 0
            while bit < bytes.count * 8 {
                let byte = bytes[bit >> 3]
                let remaining = byte << UInt8(bit & 7)
                if remaining == 0 {
                    let step = 8 - (bit & 7)
                    zeros += step
                    bit += step
                    continue
                }
                let leading = remaining.leadingZeroBitCount
                zeros += leading
                bit += leading + 1
                return zeros
            }
            return nil
        }

        mutating func skipSubframe(sampleBits: Int, blockSize: Int) -> Bool {
            guard let padding = read(1), padding == 0, let type = read(6), let wastedFlag = read(1) else { return false }
            var bitsPerSample = sampleBits
            if wastedFlag == 1 {
                guard let wasted = unary() else { return false }
                bitsPerSample -= wasted + 1
                guard bitsPerSample > 0 else { return false }
            }
            switch type {
            case 0:
                return skip(bitsPerSample)
            case 1:
                return skip(bitsPerSample * blockSize)
            case 8...12:
                let order = Int(type & 0x07)
                guard order <= blockSize, skip(order * bitsPerSample) else { return false }
                return skipResidual(order: order, blockSize: blockSize)
            case 32...63:
                let order = Int(type & 0x1F) + 1
                guard order <= blockSize, skip(order * bitsPerSample), let precision = read(4), precision != 15,
                      skip(5), skip(order * (Int(precision) + 1))
                else { return false }
                return skipResidual(order: order, blockSize: blockSize)
            default:
                return false
            }
        }

        private mutating func skipResidual(order: Int, blockSize: Int) -> Bool {
            guard let method = read(2), method <= 1, let partitionOrder = read(4) else { return false }
            let parameterBits = method == 0 ? 4 : 5
            let escape: UInt32 = method == 0 ? 15 : 31
            let partitions = 1 << Int(partitionOrder)
            guard blockSize % partitions == 0, blockSize / partitions >= order else { return false }
            for partition in 0..<partitions {
                let count = blockSize / partitions - (partition == 0 ? order : 0)
                guard let parameter = read(parameterBits) else { return false }
                if parameter == escape {
                    guard let width = read(5), skip(count * Int(width)) else { return false }
                } else {
                    for _ in 0..<count {
                        guard unary() != nil, skip(Int(parameter)) else { return false }
                    }
                }
            }
            return true
        }
    }
}

/// Checksums used by FLAC frames.
enum CRC {
    private static let table8: [UInt8] = (0..<256).map { index -> UInt8 in
        var value = UInt8(index)
        for _ in 0..<8 { value = value & 0x80 != 0 ? (value << 1) ^ 0x07 : value << 1 }
        return value
    }

    private static let table16: [UInt16] = (0..<256).map { index -> UInt16 in
        var value = UInt16(index) << 8
        for _ in 0..<8 { value = value & 0x8000 != 0 ? (value << 1) ^ 0x8005 : value << 1 }
        return value
    }

    static func crc8<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        var crc: UInt8 = 0
        for byte in bytes { crc = table8[Int(crc ^ byte)] }
        return crc
    }

    static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes { crc = (crc << 8) ^ table16[Int((crc >> 8) ^ UInt16(byte))] }
        return crc
    }
}

import Foundation

enum Binary {
    static func u16le(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    static func u32le(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    static func u64le(_ data: Data, _ offset: Int) -> UInt64? {
        guard let low = u32le(data, offset), let high = u32le(data, offset + 4) else { return nil }
        return UInt64(low) | (UInt64(high) << 32)
    }

    static func u16be(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    static func u32be(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    static func u64be(_ data: Data, _ offset: Int) -> UInt64? {
        guard let high = u32be(data, offset), let low = u32be(data, offset + 4) else { return nil }
        return (UInt64(high) << 32) | UInt64(low)
    }

    static func fatDate(time: UInt16, date: UInt16) -> Date? {
        let second = Int(time & 0x1F) * 2
        let minute = Int((time >> 5) & 0x3F)
        let hour = Int((time >> 11) & 0x1F)
        let day = Int(date & 0x1F)
        let month = Int((date >> 5) & 0x0F)
        let year = Int((date >> 9) & 0x7F) + 1980
        return makeDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    static func exfatDate(_ value: UInt32) -> Date? {
        let second = Int(value & 0x1F) * 2
        let minute = Int((value >> 5) & 0x3F)
        let hour = Int((value >> 11) & 0x1F)
        let day = Int((value >> 16) & 0x1F)
        let month = Int((value >> 21) & 0x0F)
        let year = Int((value >> 25) & 0x7F) + 1980
        return makeDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    /// Windows FILETIME: 100-nanosecond ticks since 1 January 1601, UTC. Zero, or a date outside the years
    /// the other file systems accept, means the field is unset or junk.
    static func fileTimeDate(_ ticks: UInt64) -> Date? {
        guard ticks > 0 else { return nil }
        let seconds = Int64(ticks / 10_000_000) - 11_644_473_600
        guard seconds >= 315_532_800, seconds < 4_102_444_800 else { return nil }
        let fraction = Double(ticks % 10_000_000) / 10_000_000
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    static func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date? {
        guard (1980...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        guard (0...23).contains(hour), (0...59).contains(minute), (0...58).contains(second) else { return nil }
        var parts = DateComponents()
        parts.calendar = Calendar(identifier: .gregorian)
        parts.timeZone = TimeZone.current
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        parts.second = second
        return parts.date
    }
}

enum ClusterMap {
    static func ranges(
        clusters: [UInt32],
        byteCount: UInt64,
        clusterSize: UInt64,
        offsetOf: (UInt32) -> UInt64
    ) -> [ByteRange] {
        guard !clusters.isEmpty, byteCount > 0, clusterSize > 0 else { return [] }
        var runs: [(UInt32, UInt32)] = []
        var start = clusters[0]
        var length: UInt32 = 1
        for cluster in clusters.dropFirst() {
            if cluster == start &+ length {
                length &+= 1
            } else {
                runs.append((start, length))
                start = cluster
                length = 1
            }
        }
        runs.append((start, length))

        var left = byteCount
        var ranges: [ByteRange] = []
        for (runStart, runLength) in runs {
            if left == 0 { break }
            let bytes = UInt64(runLength) * clusterSize
            let take = min(bytes, left)
            ranges.append(ByteRange(offset: offsetOf(runStart), length: take))
            left -= take
        }
        return ranges
    }
}

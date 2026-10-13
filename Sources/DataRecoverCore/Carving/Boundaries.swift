import Foundation

/// For data that doesn't record its own length: where the next thing on the disk begins.
enum Boundaries {
    /// The first sector boundary at or after `from` (and before `limit`) where the sector is all zeros
    /// or another file starts. High-entropy data such as compressed audio or sensor data never fills
    /// a whole sector with zeros, and files always start on a sector boundary.
    static func nextFileOrBlank(_ reader: BlockReader, from: UInt64, before limit: UInt64) -> UInt64? {
        let sector = Carver.sector
        var position = (from + sector - 1) / sector * sector
        let stop = min(limit, reader.size)
        let chunk = 1024 * 1024
        while position + sector <= stop {
            let count = Int(min(UInt64(chunk), (stop - position) / sector * sector))
            guard count > 0, let data = try? reader.read(at: position, count: count), data.count == count else { return nil }
            let hit: Int? = data.withUnsafeBytes { raw in
                var local = 0
                while local + Int(sector) <= raw.count {
                    let block = UnsafeRawBufferPointer(rebasing: raw[local..<(local + Int(sector))])
                    if isBlank(block) { return local }
                    let head = UnsafeRawBufferPointer(rebasing: block[0..<Signatures.headLength])
                    if Signatures.carver(for: head) != nil { return local }
                    local += Int(sector)
                }
                return nil
            }
            if let hit { return position + UInt64(hit) }
            position += UInt64(count)
        }
        return nil
    }

    static func isBlank(_ bytes: UnsafeRawBufferPointer) -> Bool {
        // Checks eight bytes at a time; data that isn't blank fails on the first word.
        let words = bytes.count / 8
        for index in 0..<words where bytes.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self) != 0 {
            return false
        }
        for index in (words * 8)..<bytes.count where bytes[index] != 0 {
            return false
        }
        return true
    }
}

// Makes camera-like JPEGs with EXIF dates and a camera model, for testing and screenshots.
//   swift scripts/dev/make-photos.swift <output-folder> <count> <make> <model> [source-folder]
// Sources default to the macOS desktop pictures. With a source folder (e.g. real holiday photos), they're used in name order.
// PER_DAY (default 4) photos are spread over each day of a trip starting START (default 2026-08-14), and each file's
// modification date matches its EXIF date so a card shows them on the right days.
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1], isDirectory: true)
let count = Int(args[2]) ?? 12
let make = args.count > 3 ? args[3] : "Canon"
let model = args.count > 4 ? args[4] : "Canon EOS R6"
let sourceFolder = args.count > 5 ? URL(fileURLWithPath: args[5], isDirectory: true) : URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
let environment = ProcessInfo.processInfo.environment
let perDay = Int(environment["PER_DAY"] ?? "") ?? 4

let sources = try FileManager.default.contentsOfDirectory(atPath: sourceFolder.path)
    .filter { ["heic", "jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }
    .sorted()
    .map { sourceFolder.appendingPathComponent($0) }
guard !sources.isEmpty else { fatalError("no source images in \(sourceFolder.path)") }
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let formatter = DateFormatter()
formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
let startFormatter = DateFormatter()
startFormatter.dateFormat = "yyyy-MM-dd HH:mm"
let start = startFormatter.date(from: environment["START"] ?? "2026-08-14 10:12") ?? Date(timeIntervalSince1970: 1_786_700_000)
// Gaps between shots in a day, in minutes: a morning walk, lunch, the afternoon, the evening.
let gaps = [0, 47, 163, 251, 389, 412, 498, 530]

for index in 0..<count {
    let source = sources[index % sources.count]
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil) else { continue }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2400, kCGImageSourceCreateThumbnailWithTransform: true]
    guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else { continue }
    let day = index / perDay
    let shot = index % perDay
    let date = start.addingTimeInterval(Double(day) * 86_400 + Double(gaps[shot % gaps.count]) * 60 + Double((index * 37) % 50))
    let url = out.appendingPathComponent(String(format: "IMG_%04d.JPG", 4100 + index + 1))
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.88,
        kCGImageDestinationEmbedThumbnail: true,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: make, kCGImagePropertyTIFFModel: model, kCGImagePropertyTIFFDateTime: formatter.string(from: date)],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: formatter.string(from: date)],
    ]
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    CGImageDestinationFinalize(dest)
    try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
}
print("made \(count) photos in \(out.path)")

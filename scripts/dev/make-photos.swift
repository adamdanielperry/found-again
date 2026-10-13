// Makes camera-like JPEGs with EXIF dates and a camera model, for testing.
// swift scripts/dev/make-photos.swift <output-folder> <count> <make> <model>
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1], isDirectory: true)
let count = Int(args[2]) ?? 12
let make = args.count > 3 ? args[3] : "Canon"
let model = args.count > 4 ? args[4] : "Canon EOS R6"
let sources = try FileManager.default.contentsOfDirectory(atPath: "/System/Library/Desktop Pictures")
    .filter { $0.hasSuffix(".heic") }.sorted()
    .map { URL(fileURLWithPath: "/System/Library/Desktop Pictures").appendingPathComponent($0) }
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let formatter = DateFormatter()
formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
let start = Date(timeIntervalSince1970: 1_717_200_000)
for index in 0..<count {
    let source = sources[index % sources.count]
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil) else { continue }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2400 + (index % 4) * 400, kCGImageSourceCreateThumbnailWithTransform: true]
    guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else { continue }
    let date = start.addingTimeInterval(Double(index / 8) * 86_400 + Double(index % 8) * 1_800)
    let url = out.appendingPathComponent(String(format: "IMG_%04d.JPG", index + 1))
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.85,
        kCGImageDestinationEmbedThumbnail: true,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: make, kCGImagePropertyTIFFModel: model, kCGImagePropertyTIFFDateTime: formatter.string(from: date)],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: formatter.string(from: date)],
    ]
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    CGImageDestinationFinalize(dest)
}
print("made \(count) photos in \(out.path)")

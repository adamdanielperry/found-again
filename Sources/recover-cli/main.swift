import DataRecoverCore
import Foundation

// Developer tool: scans a disk image and prints what the app would find.
//   swift run recover-cli <image> [--quick] [--save <folder>]
let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first else {
    print("usage: recover-cli <disk image> [--quick] [--save <folder>]")
    exit(2)
}
let quick = args.contains("--quick")
let saveFolder = args.firstIndex(of: "--save").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }

do {
    let reader = try FileBlockReader(path: path)
    let started = Date()
    var lastPrint = Date.distantPast
    let options = ScanOptions(deepScan: !quick, progress: { progress in
        guard Date().timeIntervalSince(lastPrint) > 1 else { return }
        lastPrint = Date()
        if let fraction = progress.fraction {
            FileHandle.standardError.write("\r\(progress.phase.rawValue) \(Int(fraction * 100))% found \(progress.found)   ".data(using: .utf8)!)
        }
    })
    let result = try RecoveryEngine.scan(reader: reader, options: options)
    let seconds = Date().timeIntervalSince(started)
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    print("filesystem: \(result.filesystem)  files: \(result.files.count)  time: \(String(format: "%.2f", seconds))s  rate: \(ByteText.string(UInt64(Double(reader.size) / max(seconds, 0.001))))/s")
    for warning in result.warnings { print("warning: \(warning)") }
    let formatter = ISO8601DateFormatter()
    for file in result.files {
        let date = file.modified.map { formatter.string(from: $0) } ?? "-"
        print("\(file.confidence.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(file.kind.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(file.quality.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(String(file.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(date)  \(file.originalPath)  \(file.device ?? "")")
    }
    if let saveFolder {
        let report = try PhotoRestore.save(result.files, from: reader, to: URL(fileURLWithPath: saveFolder, isDirectory: true))
        print("saved \(report.saved.count), failed \(report.failed.count)")
        for failure in report.failed { print("  \(failure)") }
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}

import Foundation

public struct DeviceFacts: Equatable {
    public var identifier: String
    public var wholeDisk: Bool
    public var virtual: Bool
    public var removableOrExternal: Bool
    public var bus: String
    public var internalDisk: Bool
    public var startup: Bool

    public init(
        identifier: String,
        wholeDisk: Bool,
        virtual: Bool,
        removableOrExternal: Bool,
        bus: String,
        internalDisk: Bool,
        startup: Bool
    ) {
        self.identifier = identifier
        self.wholeDisk = wholeDisk
        self.virtual = virtual
        self.removableOrExternal = removableOrExternal
        self.bus = bus
        self.internalDisk = internalDisk
        self.startup = startup
    }
}

public enum DeviceGuard {
    /// Only whole, physical disks that are external or removable. Never this Mac's own drive, the startup disk,
    /// a disk image, or an APFS container. A MacBook's built-in SD slot counts as internal but holds removable
    /// media, so cards in it are allowed.
    public static func isRecoverable(_ facts: DeviceFacts, allowDiskImages: Bool = false) -> Bool {
        let idOK = facts.identifier.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil
        guard idOK, facts.wholeDisk, !facts.startup else { return false }
        if facts.internalDisk && !facts.removableOrExternal { return false }
        if facts.virtual {
            return allowDiskImages && facts.bus.lowercased() == "disk image"
        }
        let bus = facts.bus.lowercased()
        let externalBus = bus.contains("usb") || bus.contains("secure digital") || bus.contains("thunderbolt")
            || bus.contains("firewire") || bus.contains("sata") || bus.contains("pci")
        return facts.removableOrExternal || externalBus
    }

    public static func diskIdentifier(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [#"^/dev/rdisk([0-9]+)$"#, #"^/dev/disk([0-9]+)$"#, #"^disk([0-9]+)$"#, #"^disk([0-9]+)s[0-9]+$"#]
        for pattern in patterns where trimmed.range(of: pattern, options: .regularExpression) != nil {
            guard let digits = trimmed.range(of: #"disk([0-9]+)"#, options: .regularExpression) else { return nil }
            let text = trimmed[digits].dropFirst(4)
            return "disk" + text
        }
        return nil
    }
}

public struct Device: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case memoryCard
        case usbDrive
        case externalDrive
        case diskImage
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var size: UInt64
    public var blockSize: Int
    public var filesystems: [String]
    public var mountPoints: [String]
    public var partitionIDs: [String]
    /// "Fujifilm X-T5" or "Canon", when the card still has the camera's folders.
    public var camera: String?
    public var media: String
    public var solidState: Bool

    public var rawNode: String { "/dev/r\(id)" }
    public var isMounted: Bool { !mountPoints.isEmpty }

    /// "128 GB · ExFAT"
    public var detail: String {
        var parts = [ByteText.string(size)]
        if let system = filesystems.first { parts.append(system) }
        return parts.joined(separator: " · ")
    }
}

public enum DeviceCatalog {
    /// Attached disk images to list as if they were cards, for testing: RECOVER_ALLOW_DISK_IMAGES=disk12,disk13
    static var allowedDiskImages: Set<String> {
        let value = ProcessInfo.processInfo.environment["RECOVER_ALLOW_DISK_IMAGES"] ?? ""
        return Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    public static func devices() throws -> [Device] {
        let listed = try plist(arguments: ["list", "-plist"])
        let startup = startupIdentifiers()
        let disks = (listed["WholeDisks"] as? [String] ?? []).filter {
            $0.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil
        }
        let layouts = listed["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        var found: [Device] = []
        for disk in disks {
            guard let info = try? plist(arguments: ["info", "-plist", disk]) else { continue }
            let facts = DeviceFacts(
                identifier: disk,
                wholeDisk: bool(info["WholeDisk"]) ?? false,
                virtual: (info["VirtualOrPhysical"] as? String) == "Virtual",
                removableOrExternal: bool(info["RemovableMediaOrExternalDevice"]) ?? (bool(info["Removable"]) ?? false),
                bus: info["BusProtocol"] as? String ?? "",
                internalDisk: bool(info["Internal"]) ?? false,
                startup: startup.contains(disk)
            )
            guard DeviceGuard.isRecoverable(facts, allowDiskImages: allowedDiskImages.contains(disk)) else { continue }
            let layout = layouts.first { ($0["DeviceIdentifier"] as? String) == disk }
            found.append(device(id: disk, info: info, layout: layout))
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func device(identifier: String) throws -> Device {
        guard let id = DeviceGuard.diskIdentifier(identifier) else {
            throw RecoverError.unsafeDevice("That isn't a disk this app can read.")
        }
        guard let match = try devices().first(where: { $0.id == id }) else {
            throw RecoverError.unsafeDevice("Only external drives and memory cards can be scanned, not this Mac's own drive.")
        }
        return match
    }

    /// Unmounts every volume so macOS stops writing to the disk while it's read. Returns true when something was unmounted.
    public static func unmount(_ device: Device) throws -> Bool {
        let mounted = device.mountPoints.contains { FileManager.default.fileExists(atPath: $0) }
        guard mounted else { return false }
        if run(["unmountDisk", device.id]) || run(["unmountDisk", "force", device.id]) {
            return true
        }
        throw RecoverError.message("The disk is in use. Quit any app that's showing files from it, then try again.")
    }

    public static func mount(_ device: Device) {
        run(["mountDisk", device.id])
    }

    public static func eject(_ device: Device) -> Bool {
        run(["eject", device.id])
    }

    /// True when the folder lives on the disk being recovered, including inside an APFS container on it.
    public static func destination(_ directory: URL, isOn device: Device) -> Bool {
        var path = directory.resolvingSymlinksInPath().standardizedFileURL.path
        if path == "/dev" || path.hasPrefix("/dev/") { return true }
        for mount in device.mountPoints where !mount.isEmpty {
            if path == mount || path.hasPrefix(mount + "/") { return true }
        }
        // The folder may not exist yet. Ask about the nearest one that does.
        while !FileManager.default.fileExists(atPath: path), path != "/" {
            path = (path as NSString).deletingLastPathComponent
        }
        guard let info = try? plist(arguments: ["info", "-plist", path]) else { return false }
        var parents = Set<String>()
        if let parent = info["ParentWholeDisk"] as? String { parents.insert(parent) }
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]] {
            for store in stores {
                if let id = store["DeviceIdentifier"] as? String, let whole = DeviceGuard.diskIdentifier(id) {
                    parents.insert(whole)
                }
            }
        }
        if let container = info["APFSContainerReference"] as? String,
           let containerInfo = try? plist(arguments: ["info", "-plist", container]),
           let stores = containerInfo["APFSPhysicalStores"] as? [[String: Any]] {
            for store in stores {
                if let id = store["DeviceIdentifier"] as? String, let whole = DeviceGuard.diskIdentifier(id) {
                    parents.insert(whole)
                }
            }
        }
        return parents.contains(device.id)
    }

    private static func device(id: String, info: [String: Any], layout: [String: Any]?) -> Device {
        let partitions = layout?["Partitions"] as? [[String: Any]] ?? []
        var names: [String] = []
        var systems: [String] = []
        var mounts: [String] = []
        var ids: [String] = []
        for partition in partitions {
            guard let partID = partition["DeviceIdentifier"] as? String else { continue }
            ids.append(partID)
            if let mount = partition["MountPoint"] as? String, !mount.isEmpty {
                mounts.append(mount)
            }
            if let volume = partition["VolumeName"] as? String, !volume.isEmpty, volume != "Untitled", volume != "NO NAME" {
                names.append(volume)
            }
            let content = partition["Content"] as? String ?? ""
            if content == "EFI" || content == "Apple_Boot" { continue }
            if content == "Apple_APFS" {
                systems.append("APFS")
            } else if let partInfo = try? plist(arguments: ["info", "-plist", partID]),
                      let system = friendlyFilesystem(partInfo["FilesystemUserVisibleName"] as? String ?? partInfo["FilesystemName"] as? String ?? "") {
                systems.append(system)
            }
        }
        // A card formatted without a partition table is one volume on the whole disk.
        if partitions.isEmpty {
            if let system = friendlyFilesystem(info["FilesystemUserVisibleName"] as? String ?? "") { systems.append(system) }
            if let mount = info["MountPoint"] as? String, !mount.isEmpty { mounts.append(mount) }
            if let volume = info["VolumeName"] as? String, !volume.isEmpty { names.append(volume) }
        }
        let media = (info["MediaName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let bus = (info["BusProtocol"] as? String ?? "").lowercased()
        let camera = CameraFolders.identify(mounts: mounts)
        let kind = classify(bus: bus, media: media, removable: bool(info["RemovableMedia"]) ?? false, camera: camera != nil, virtual: (info["VirtualOrPhysical"] as? String) == "Virtual")
        let size = u64(info["Size"]) ?? u64(info["TotalSize"]) ?? 0
        let title: String
        if let camera, let brand = camera.brand {
            title = camera.model.map { "\(brand) \($0)" } ?? "\(brand) card"
        } else if let name = names.first {
            title = name
        } else if !media.isEmpty, !media.lowercased().contains("media") {
            title = media
        } else {
            title = kind == .memoryCard ? "Memory card" : "External drive"
        }
        return Device(
            id: id,
            name: title,
            kind: kind,
            size: size,
            blockSize: max(Int(u64(info["DeviceBlockSize"]) ?? 512), 512),
            filesystems: systems.uniqued(),
            mountPoints: mounts,
            partitionIDs: ids,
            camera: camera?.brand,
            media: media,
            solidState: bool(info["SolidState"]) ?? false
        )
    }

    private static func classify(bus: String, media: String, removable: Bool, camera: Bool, virtual: Bool) -> Device.Kind {
        // Camera folders mean a camera card, even when it's an attached image of one.
        if bus.contains("secure digital") || camera { return .memoryCard }
        if virtual { return .diskImage }
        let lower = media.lowercased()
        let cardWords = ["sd", "card", "reader", "sdxc", "sdhc", "microsd", "cfexpress", "compactflash", "xqd", "multi-card"]
        if cardWords.contains(where: { lower.contains($0) }) { return .memoryCard }
        if removable { return .usbDrive }
        return .externalDrive
    }

    /// diskutil's long names, shortened for display.
    static func friendlyFilesystem(_ name: String) -> String? {
        let lower = name.lowercased()
        if lower.isEmpty { return nil }
        if lower.contains("exfat") { return "ExFAT" }
        if lower.contains("fat32") { return "FAT32" }
        if lower.contains("fat16") { return "FAT16" }
        if lower.contains("fat12") { return "FAT12" }
        if lower.contains("ntfs") { return "NTFS" }
        if lower.contains("apfs") { return "APFS" }
        if lower.contains("mac os extended") || lower.contains("hfs") { return "Mac OS Extended" }
        return nil
    }

    private static func startupIdentifiers() -> Set<String> {
        var ids = Set<String>()
        guard let info = try? plist(arguments: ["info", "-plist", "/"]) else { return ids }
        for key in ["ParentWholeDisk", "DeviceIdentifier"] {
            if let value = info[key] as? String, let whole = DeviceGuard.diskIdentifier(value) {
                ids.insert(whole)
            }
        }
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]] {
            for store in stores {
                if let value = store["DeviceIdentifier"] as? String, let whole = DeviceGuard.diskIdentifier(value) {
                    ids.insert(whole)
                }
            }
        }
        return ids
    }

    @discardableResult
    static func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func plist(arguments: [String]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RecoverError.message("diskutil couldn't describe \(arguments.last ?? "the disk").")
        }
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return object as? [String: Any] ?? [:]
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func u64(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int { return UInt64(value) }
        if let value = value as? NSNumber { return value.uint64Value }
        return nil
    }
}

/// Recognizes the camera from the folders it leaves on a card, such as DCIM/100_FUJI or DCIM/100CANON.
enum CameraFolders {
    struct Match {
        var brand: String?
        var model: String?
    }

    static func identify(mounts: [String]) -> Match? {
        let files = FileManager.default
        for mount in mounts where !mount.isEmpty {
            let dcim = (mount as NSString).appendingPathComponent("DCIM")
            guard let folders = try? files.contentsOfDirectory(atPath: dcim) else { continue }
            var match = Match()
            for folder in folders {
                if let brand = brand(forFolder: folder) {
                    match.brand = brand
                    break
                }
            }
            // Fujifilm cameras keep a firmware folder named after the model.
            let upd = (mount as NSString).appendingPathComponent("UPD")
            if let names = try? files.contentsOfDirectory(atPath: upd),
               let model = names.first(where: { !$0.hasPrefix(".") && $0 != "Icon\r" }) {
                match.brand = "Fujifilm"
                match.model = model
            }
            if match.brand == nil, files.fileExists(atPath: (mount as NSString).appendingPathComponent("PRIVATE/M4ROOT")) {
                match.brand = "Sony"
            }
            return match
        }
        return nil
    }

    static func brand(forFolder folder: String) -> String? {
        let upper = folder.uppercased()
        guard upper.count >= 5, upper.prefix(3).allSatisfy(\.isNumber) else { return nil }
        let tag = upper.dropFirst(3)
        let table: [(String, String)] = [
            ("_FUJI", "Fujifilm"), ("CANON", "Canon"), ("EOS", "Canon"), ("NIKON", "Nikon"), ("ND", "Nikon"), ("NZ_", "Nikon"),
            ("NCD", "Nikon"), ("MSDCF", "Sony"), ("OLYMP", "Olympus"), ("OMSYS", "OM System"), ("_PANA", "Panasonic"),
            ("LUMIX", "Panasonic"), ("GOPRO", "GoPro"), ("MEDIA", "DJI"), ("RICOH", "Ricoh"), ("_PENT", "Pentax"),
            ("PENTX", "Pentax"), ("LEICA", "Leica"), ("SIGMA", "Sigma"), ("HASBL", "Hasselblad"), ("INSTA", "Insta360"),
        ]
        for (prefix, brand) in table where tag.hasPrefix(prefix) {
            return brand
        }
        return nil
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

import Foundation

public struct DeviceFacts: Equatable {
    public var identifier: String
    public var wholeDisk: Bool
    public var virtual: Bool
    public var removable: Bool
    public var ejectable: Bool
    public var bus: String
    public var internalMedia: Bool
    public var startup: Bool

    public init(
        identifier: String,
        wholeDisk: Bool,
        virtual: Bool,
        removable: Bool,
        ejectable: Bool,
        bus: String,
        internalMedia: Bool,
        startup: Bool
    ) {
        self.identifier = identifier
        self.wholeDisk = wholeDisk
        self.virtual = virtual
        self.removable = removable
        self.ejectable = ejectable
        self.bus = bus
        self.internalMedia = internalMedia
        self.startup = startup
    }
}

public enum DeviceGuard {
    public static func isMemoryCard(_ facts: DeviceFacts) -> Bool {
        let idOK = facts.identifier.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil
        if !idOK || !facts.wholeDisk || facts.virtual || facts.internalMedia || facts.startup {
            return false
        }
        let bus = facts.bus.lowercased()
        let cardBus = bus.contains("usb") || bus.contains("sd") || bus.contains("secure digital")
        return facts.removable || facts.ejectable || cardBus
    }

    public static func diskIdentifier(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [#"^/dev/rdisk([0-9]+)$"#, #"^/dev/disk([0-9]+)$"#, #"^disk([0-9]+)$"#]
        for pattern in patterns {
            if let match = trimmed.range(of: pattern, options: .regularExpression) {
                let text = String(trimmed[match])
                if let digits = text.range(of: #"[0-9]+$"#, options: .regularExpression) {
                    return "disk" + String(text[digits])
                }
            }
        }
        return nil
    }
}

public struct MemoryCard: Identifiable, Equatable {
    public var id: String
    public var deviceNode: String
    public var name: String
    public var summary: String
    public var size: UInt64
    public var blockSize: Int
    public var mountPoints: [String]
    public var partitionIDs: [String]
    public var isCamera: Bool

    public init(
        id: String,
        deviceNode: String,
        name: String,
        summary: String,
        size: UInt64,
        blockSize: Int,
        mountPoints: [String],
        partitionIDs: [String],
        isCamera: Bool
    ) {
        self.id = id
        self.deviceNode = deviceNode
        self.name = name
        self.summary = summary
        self.size = size
        self.blockSize = blockSize
        self.mountPoints = mountPoints
        self.partitionIDs = partitionIDs
        self.isCamera = isCamera
    }
}

public enum DiskCatalog {
    public static func cards() throws -> [MemoryCard] {
        let listed = try plist(arguments: ["list", "-plist"])
        let startup = startupIdentifiers()
        let disks = (listed["AllDisks"] as? [String] ?? []).filter {
            $0.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil
        }
        var cards: [MemoryCard] = []
        for disk in disks {
            guard let info = try? plist(arguments: ["info", "-plist", disk]) else { continue }
            let facts = DeviceFacts(
                identifier: disk,
                wholeDisk: bool(info["WholeDisk"]) ?? false,
                virtual: (info["VirtualOrPhysical"] as? String) == "Virtual",
                removable: (bool(info["Removable"]) ?? false) || (bool(info["RemovableMedia"]) ?? false),
                ejectable: bool(info["Ejectable"]) ?? false,
                bus: info["BusProtocol"] as? String ?? "",
                internalMedia: bool(info["OSInternalMedia"]) ?? false,
                startup: startup.contains(disk)
            )
            guard DeviceGuard.isMemoryCard(facts) else { continue }
            cards.append(try card(id: disk, info: info))
        }
        return cards.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Unmounts mounted partitions so the raw card can be read without macOS writing to it. Returns the ids to mount again.
    public static func unmount(_ partitionIDs: [String]) throws -> [String] {
        var mounted: [String] = []
        for id in partitionIDs {
            let info = try plist(arguments: ["info", "-plist", id])
            let mount = info["MountPoint"] as? String ?? ""
            if mount.isEmpty { continue }
            mounted.append(id)
            if !run(["unmount", id]) && !run(["unmount", "force", id]) {
                mountBack(mounted)
                throw RecoverError.message("The card is in use. Close any Finder windows showing it, then try again.")
            }
        }
        return mounted
    }

    public static func mountBack(_ partitionIDs: [String]) {
        for id in partitionIDs {
            _ = run(["mount", id])
        }
    }

    public static func destinationIsOnCard(_ directory: URL, cardID: String, mounts: [String]) -> Bool {
        let path = directory.resolvingSymlinksInPath().standardizedFileURL.path
        if path == "/dev" || path.hasPrefix("/dev/") { return true }
        for mount in mounts where !mount.isEmpty {
            if path == mount || path.hasPrefix(mount + "/") { return true }
        }
        if let info = try? plist(arguments: ["info", "-plist", path]),
           let parent = info["ParentWholeDisk"] as? String,
           parent == cardID {
            return true
        }
        return false
    }

    @discardableResult
    static func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    public static func requireCard(identifier: String) throws -> MemoryCard {
        guard let id = DeviceGuard.diskIdentifier(identifier) else {
            throw RecoverError.unsafeDevice("That is not a memory card.")
        }
        let matches = try cards().filter { $0.id == id }
        guard let card = matches.first else {
            throw RecoverError.unsafeDevice("DataRecover only reads removable memory cards, not this Mac's internal disk.")
        }
        return card
    }

    private static func card(id: String, info: [String: Any]) throws -> MemoryCard {
        let list = try plist(arguments: ["list", "-plist", id])
        var partitions: [[String: Any]] = []
        if let whole = (list["AllDisksAndPartitions"] as? [[String: Any]])?.first {
            partitions = whole["Partitions"] as? [[String: Any]] ?? []
        }
        var names: [String] = []
        var systems: [String] = []
        var mounts: [String] = []
        var ids: [String] = []
        var camera: String?
        for partition in partitions {
            guard let partID = partition["DeviceIdentifier"] as? String else { continue }
            ids.append(partID)
            if let mount = partition["MountPoint"] as? String, !mount.isEmpty {
                mounts.append(mount)
            }
            if let partInfo = try? plist(arguments: ["info", "-plist", partID]) {
                if let volume = partInfo["VolumeName"] as? String, !volume.isEmpty, volume != "Untitled" {
                    names.append(volume)
                }
                if let system = partInfo["FilesystemUserVisibleName"] as? String, !system.isEmpty {
                    systems.append(system)
                } else if let system = partInfo["FilesystemName"] as? String, !system.isEmpty {
                    systems.append(system)
                }
                if let mount = partInfo["MountPoint"] as? String, !mount.isEmpty, !mounts.contains(mount) {
                    mounts.append(mount)
                }
                if camera == nil {
                    camera = cameraModel(mounts: [partInfo["MountPoint"] as? String ?? ""])
                }
            }
        }
        if camera == nil {
            camera = cameraModel(mounts: mounts)
        }
        let media = info["MediaName"] as? String ?? ""
        let title = camera ?? names.first ?? (media.isEmpty ? "Memory card" : media)
        let size = u64(info["Size"]) ?? 0
        let block = Int(u64(info["DeviceBlockSize"]) ?? 512)
        var detail = [ByteText.string(size)]
        if let system = systems.first { detail.append(system) }
        if !media.isEmpty && media != title { detail.append(media) }
        detail.append(id)
        return MemoryCard(
            id: id,
            deviceNode: "/dev/\(id)",
            name: title,
            summary: detail.joined(separator: " · "),
            size: size,
            blockSize: max(block, 512),
            mountPoints: mounts,
            partitionIDs: ids,
            isCamera: camera != nil || mounts.contains { FileManager.default.fileExists(atPath: $0 + "/DCIM") }
        )
    }

    private static func cameraModel(mounts: [String]) -> String? {
        for mount in mounts where !mount.isEmpty {
            let folder = (mount as NSString).appendingPathComponent("UPD")
            if let names = try? FileManager.default.contentsOfDirectory(atPath: folder) {
                if let model = names.first(where: { !$0.hasPrefix(".") && $0 != "Icon\r" }) {
                    return "Fujifilm \(model)"
                }
            }
        }
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

    static func plist(arguments: [String]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw RecoverError.message(text.isEmpty ? "diskutil failed." : text.trimmingCharacters(in: .whitespacesAndNewlines))
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

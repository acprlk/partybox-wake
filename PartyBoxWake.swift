import CoreBluetooth
import Darwin
import Foundation

// JBL's vendor service exposes a command characteristic and a separate reply channel.
let control = CBUUID(string: "65786365-6C70-6F69-6E74-2E636F6D0000")
let replies = CBUUID(string: "65786365-6C70-6F69-6E74-2E636F6D0001")
let commands = CBUUID(string: "65786365-6C70-6F69-6E74-2E636F6D0002")
let wake = Data([0xAA, 0x03, 0x01, 0x05])

// Resolve symlinks so a launcher can run the executable from any working directory.
let configFile = Bundle.main.executableURL!.resolvingSymlinksInPath()
    .deletingLastPathComponent().appendingPathComponent("partybox-wake.config")

let usage = """
Usage
  partybox-wake                Wake the configured default speaker
  partybox-wake --wake-last    Wake the speaker from the last successful request
  partybox-wake --list         Show nearby Bluetooth LE names and UUIDs
  partybox-wake --id UUID      Wake a specific entry and record success in history
  partybox-wake --save UUID [NAME]
                               Set the default UUID and optional exact Bluetooth name
  partybox-wake --help         Show this help

Config file: \(configFile.path)
"""

/// Report a CLI or filesystem error on stderr and return the given status to the shell.
func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

struct SpeakerTarget {
    let id: UUID
    let name: String?
}

enum SpeakerSlot: String {
    case preferred = "default"
    case lastWake = "last_wake"

    var uuidKey: String { rawValue + "_uuid" }
    var nameKey: String { rawValue + "_name" }
}

/// Keep original lines so updating one speaker preserves comments and the other speaker.
struct Configuration {
    private var lines: [String]
    private var positions: [String: Int] = [:]

    /// Read the file beside the executable. A missing file behaves like an empty template.
    init() {
        let text: String
        do {
            text = try String(contentsOf: configFile, encoding: .utf8)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            text = ""
        } catch {
            fail("Could not read \(configFile.path): \(error.localizedDescription)")
        }
        lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let separator = trimmed.firstIndex(of: "=") else {
                fail("Expected key=value in \(configFile.lastPathComponent) on line \(index + 1).")
            }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, positions[key] == nil else {
                fail("Empty or duplicate config key on line \(index + 1).")
            }
            positions[key] = index
        }
    }

    /// Split at the first equals sign so names can contain spaces, equals signs, and hashes.
    private func value(for key: String) -> String {
        guard let index = positions[key], let separator = lines[index].firstIndex(of: "=") else { return "" }
        return lines[index].suffix(from: lines[index].index(after: separator)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve a default or historical selection and explain how to populate an empty slot.
    func target(for slot: SpeakerSlot) -> SpeakerTarget {
        let raw = value(for: slot.uuidKey)
        if raw.isEmpty {
            fail(slot == .lastWake ? "No successful wake recorded. Wake a speaker with --id UUID or your saved default first."
                                   : "No default speaker saved. Run --list, then --save UUID [NAME].")
        }
        guard let id = UUID(uuidString: raw) else { fail("Invalid UUID in \(slot.uuidKey) in \(configFile.path).") }
        let name = value(for: slot.nameKey)
        return SpeakerTarget(id: id, name: name.isEmpty ? nil : name)
    }

    /// Replace existing entries in place or append missing keys to a hand-written config.
    private mutating func set(_ key: String, to value: String) {
        let line = "\(key)=\(value)"
        if let index = positions[key] {
            lines[index] = line
        } else {
            positions[key] = lines.count
            lines.append(line)
        }
    }

    /// Lock the read-modify-write cycle so concurrent wakes and saves keep both selections.
    static func store(_ target: SpeakerTarget, in slot: SpeakerSlot) {
        // Atomic replacement changes the config inode. A separate lock stays stable across writes.
        let lock = open(configFile.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { fail("Cannot open config lock: \(String(cString: strerror(errno)))") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { fail("Cannot lock config: \(String(cString: strerror(errno)))") }
        var config = Configuration()
        config.set(slot.uuidKey, to: target.id.uuidString)
        config.set(slot.nameKey, to: target.name ?? "")
        do {
            try (config.lines.joined(separator: "\n") + "\n").write(to: configFile, atomically: true, encoding: .utf8)
        } catch {
            fail("Could not save \(configFile.path): \(error.localizedDescription)")
        }
    }
}

/// Parse the CLI before starting Bluetooth. Only --list returns a nil discovery target.
func selectedSpeaker(arguments: [String]) -> SpeakerTarget? {
    if arguments == ["--help"] || arguments == ["-h"] {
        print(usage)
        exit(0)
    }
    if arguments == ["--list"] { return nil }
    if arguments.isEmpty { return Configuration().target(for: .preferred) }
    if arguments == ["--wake-last"] { return Configuration().target(for: .lastWake) }
    guard arguments.count >= 2, let id = UUID(uuidString: arguments[1]) else { fail(usage, code: 64) }
    if arguments[0] == "--id", arguments.count == 2 { return SpeakerTarget(id: id, name: nil) }
    guard arguments[0] == "--save", arguments.count <= 3 else { fail(usage, code: 64) }
    var name: String?
    if arguments.count == 3 {
        let input = arguments[2].trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty, input.rangeOfCharacter(from: .newlines) == nil else {
            fail("The optional Bluetooth name must fit on one nonempty line.", code: 64)
        }
        name = input
    }
    Configuration.store(SpeakerTarget(id: id, name: name), in: .preferred)
    print("Saved default speaker \(id) to \(configFile.path)")
    exit(0)
}

final class PartyBox: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let target: SpeakerTarget?
    var central: CBCentralManager!

    private var speaker: CBPeripheral?
    private var writer: CBCharacteristic?
    private var seen = [UUID: String]()
    private var nameMatches = [UUID: CBPeripheral]()
    private var sent = false
    private var writeAccepted = false
    private var receivedDeviceInfo = false
    private var acknowledged = false
    private let start = ProcessInfo.processInfo.systemUptime

    /// Prepare a wake session, or a discovery-only session when the target is nil.
    init(target: SpeakerTarget?) {
        self.target = target
        super.init()
    }

    /// Prefix progress messages with elapsed time and flush them for interactive use.
    func log(_ message: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print(String(format: "[%5.1fs] ", elapsed) + message)
        fflush(stdout)
    }

    /// Release the Bluetooth connection or stop scanning before returning a shell status.
    func finish(_ message: String, code: Int32) -> Never {
        log(message)
        if central?.isScanning == true { central.stopScan() }
        if let speaker { central.cancelPeripheralConnection(speaker) }
        exit(code)
    }

    /// Classify the collected Bluetooth replies and persist history only on protocol-level success.
    func reportOutcome(_ reason: String) -> Never {
        if target == nil {
            finish("\(reason) Bluetooth discovery did not finish.", code: 1)
        }
        if !sent {
            finish("\(reason) No wake request was sent. Run --list to check which entries are visible.", code: 1)
        }
        // Record the peripheral that actually replied. A name fallback can select a new UUID.
        if let speaker, acknowledged || (writeAccepted && receivedDeviceInfo) {
            let name = target?.name ?? speaker.name
            let singleLineName = name.flatMap { $0.rangeOfCharacter(from: .newlines) == nil ? $0 : nil }
            Configuration.store(SpeakerTarget(id: speaker.identifier, name: singleLineName), in: .lastWake)
        }
        if acknowledged {
            finish("\(reason) Speaker acknowledged the request. Check the power light to confirm wake.", code: 0)
        }
        if writeAccepted && receivedDeviceInfo {
            finish("\(reason) Bluetooth write accepted and speaker settings received. Check the power light to confirm wake.", code: 0)
        }
        finish("\(reason) No JBL acknowledgement of the wake request was observed.", code: 2)
    }

    /// Wait for the adapter, then scan or connect directly to a cached UUID.
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard speaker == nil, !central.isScanning else { return }
            if let target, target.name == nil, let known = central.retrievePeripherals(withIdentifiers: [target.id]).first {
                connect(known)
                return
            }
            log("Scanning for nearby Bluetooth LE devices for 15 seconds…")
            central.scanForPeripherals(withServices: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.scanFinished() }
        case .unauthorized: finish("Bluetooth access denied. Check System Settings → Privacy & Security → Bluetooth.", code: 1)
        case .poweredOff: finish("Turn Bluetooth on in System Settings and run again.", code: 1)
        case .unsupported: finish("This process cannot access a Bluetooth LE adapter.", code: 1)
        default: break
        }
    }

    /// Collect discovery results, prefer the requested UUID, and keep exact name matches for fallback.
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        if let target {
            guard speaker == nil else { return }
            if peripheral.identifier == target.id { connect(peripheral) }
            else if let savedName = target.name, name == savedName { nameMatches[peripheral.identifier] = peripheral }
            return
        }
        // A later advertisement may supply a name for a previously unnamed entry.
        let displayName = name ?? seen[peripheral.identifier] ?? "(unnamed)"
        if seen.updateValue(displayName, forKey: peripheral.identifier) != displayName {
            log("\(peripheral.identifier)  \(displayName)")
        }
    }

    /// Resolve an unambiguous name match after the scan, or finish a discovery-only run.
    private func scanFinished() {
        guard speaker == nil else { return }
        guard let target else { finish("Scan complete. Devices found: \(seen.count).", code: 0) }
        if nameMatches.count == 1, let match = nameMatches.values.first {
            log("Saved UUID was absent. Using the only visible entry named \(target.name ?? "").")
            connect(match)
            return
        }
        if nameMatches.count > 1 {
            let ids = nameMatches.keys.map(\.uuidString).sorted().joined(separator: "\n")
            finish("Several entries match the saved name. Test your speaker with --id before saving a new UUID.\n\(ids)", code: 1)
        }
        if let known = central.retrievePeripherals(withIdentifiers: [target.id]).first {
            connect(known)
            return
        }
        finish("Saved entry unavailable. Run --list to see entries visible to this Mac.", code: 1)
    }

    /// Stop the scan and retain the selected peripheral while macOS connects.
    func connect(_ peripheral: CBPeripheral) {
        central.stopScan()
        speaker = peripheral
        peripheral.delegate = self
        log("Opening a Bluetooth LE connection to \(peripheral.name ?? "selected speaker") (\(peripheral.identifier))…")
        central.connect(peripheral)
    }

    /// Once connected, ask for the JBL control service.
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected. Looking up the JBL control service.")
        peripheral.discoverServices([control])
    }

    /// Report a connection failure before any wake request could be sent.
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish("Connection failed. \(error?.localizedDescription ?? "No reason supplied.")", code: 1)
    }

    /// Use replies already received to decide the result if the speaker disconnects early.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        reportOutcome("Disconnected. \(error?.localizedDescription ?? "")")
    }

    /// Find the control service and request its command and reply characteristics.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { finish(error.localizedDescription, code: 1) }
        guard let service = peripheral.services?.first(where: { $0.uuid == control }) else {
            finish("This Bluetooth entry does not expose the JBL control service.", code: 1)
        }
        peripheral.discoverCharacteristics([commands, replies], for: service)
    }

    /// Choose the writable endpoint and start listening before sending the wake request.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { finish(error.localizedDescription, code: 1) }
        let characteristics = service.characteristics ?? []
        guard let tx = characteristics.first(where: { $0.uuid == commands && $0.properties.contains(.write) }) else {
            finish("The expected JBL write characteristic is unavailable.", code: 1)
        }
        writer = tx
        if let rx = characteristics.first(where: { $0.uuid == replies && $0.properties.contains(.notify) }) {
            peripheral.setNotifyValue(true, for: rx)
            // A slow or unsupported subscription must not consume the short connection window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if !self.sent { self.log("Reply subscription is pending."); self.sendWake(peripheral) }
            }
        } else {
            log("Reply notifications unavailable.")
            sendWake(peripheral)
        }
    }

    /// Send the pending request when macOS finishes setting up reply notifications.
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log("Reply subscription failed: \(error.localizedDescription)") }
        else if characteristic.isNotifying { log("Listening for JBL replies.") }
        sendWake(peripheral)
    }

    /// Send at most one wake request and give the speaker ten seconds to reply.
    func sendWake(_ peripheral: CBPeripheral) {
        guard !sent, let writer else { return }
        sent = true
        log("Sending AA 03 01 05.")
        peripheral.writeValue(wake, for: writer, type: .withResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.reportOutcome("Reply window ended.") }
    }

    /// Record the Bluetooth write result while waiting for the speaker's own response.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { finish("Bluetooth write failed: \(error.localizedDescription)", code: 1) }
        writeAccepted = true
        log("Bluetooth write accepted. Waiting for a JBL reply.")
    }

    /// Recognize JBL settings replies, acknowledgements, and explicit command rejections.
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log("Reply error: \(error.localizedDescription)"); return }
        guard characteristic.uuid == replies, let value = characteristic.value else { return }
        let bytes = Array(value)
        guard bytes.count >= 3, bytes[0] == 0xAA else { return }
        log(String(format: "JBL reply 0x%02X (%d bytes).", bytes[1], bytes.count))
        // The Encore 2 also returns settings (opcode 0x12) after a successful wake.
        // An explicit ACK echoes the power opcode, 0x03, followed by its status byte.
        if sent, bytes[1] == 0x12, bytes.count == Int(bytes[2]) + 3 { receivedDeviceInfo = true }
        if sent, bytes.count == 5, bytes.prefix(4).elementsEqual([0xAA, 0, 2, 3]) {
            if bytes[4] != 0 { finish("The speaker returned status \(bytes[4]) for the power request.", code: 2) }
            acknowledged = true
        }
    }
}

let client = PartyBox(target: selectedSpeaker(arguments: Array(CommandLine.arguments.dropFirst())))
client.central = CBCentralManager(delegate: client, queue: .main)
DispatchQueue.main.asyncAfter(deadline: .now() + 55) { client.reportOutcome("Bluetooth session timed out.") }
RunLoop.main.run()

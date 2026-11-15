import CoreAudio
import Foundation
import IOBluetooth

/// Find the speaker's Classic address in a complete JBL device-info reply (tag 0x37).
/// CoreBluetooth's peripheral UUID identifies a different, low-energy connection.
func classicAddress(in bytes: [UInt8]) -> String? {
    guard bytes.count >= 4, bytes.starts(with: [0xAA, 0x12]),
          bytes.count == 3 + Int(bytes[2]), bytes[3] == 0 else { return nil }
    var offset = 4
    while offset + 2 <= bytes.count {
        let tag = bytes[offset]
        let length = Int(bytes[offset + 1])
        offset += 2
        guard offset + length <= bytes.count else { return nil }
        if tag == 0x37, length == 6 {
            let address = bytes[offset..<(offset + length)]
            guard !address.allSatisfy({ $0 == 0 }), !address.allSatisfy({ $0 == 0xff }) else { return nil }
            return address.map { String(format: "%02X", $0) }.joined(separator: "-")
        }
        offset += length
    }
    return nil
}

/// Compare the addresses used by IOBluetooth and the Bluetooth audio driver's device UIDs.
private func compactAddress(_ value: String) -> String {
    value.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").lowercased()
}

/// Convert a Classic Bluetooth address to six bytes for comparison with an advertisement.
func addressBytes(_ text: String) -> Data? {
    let parts = text.split(whereSeparator: { $0 == "-" || $0 == ":" })
    let bytes = parts.compactMap { UInt8($0, radix: 16) }
    guard parts.count == 6, parts.allSatisfy({ $0.count == 2 }), bytes.count == 6,
          !bytes.allSatisfy({ $0 == 0 }), !bytes.allSatisfy({ $0 == 0xff }) else { return nil }
    return Data(bytes)
}

/// The Encore 2 advertises its Classic address in the payload following company ID 0x0ECB.
func advertisesPairedAddress(_ address: Data, in manufacturerData: Data) -> Bool {
    guard manufacturerData.starts(with: [0xcb, 0x0e]), address.count == 6 else { return false }
    let payload = manufacturerData.dropFirst(2)
    return payload.range(of: address) != nil || payload.range(of: Data(address.reversed())) != nil
}

/// Return the UInt32 entries of a Core Audio property (IDs, streams, or a scalar value).
private func integers(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [UInt32] {
    var property = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr,
          size > 0, Int(size).isMultiple(of: MemoryLayout<UInt32>.stride) else { return [] }
    var values = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.stride)
    let status = values.withUnsafeMutableBytes { buffer in
        AudioObjectGetPropertyData(object, &property, 0, nil, &size, buffer.baseAddress!)
    }
    return status == noErr ? Array(values.prefix(Int(size) / MemoryLayout<UInt32>.stride)) : []
}

/// Read a retained name or UID supplied by Core Audio.
private func audioString(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout.size(ofValue: value))
    guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

/// Track the specific paired audio device independently of the BLE control connection.
struct BluetoothAudio {
    let device: IOBluetoothDevice
    private let uniqueName: String?

    /// Prefer the speaker-reported address. Use an exact paired name only when it identifies one device.
    init(address: String?, names: [String]) throws {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let matches = paired.filter { candidate in
            if let address { return candidate.addressString.map(compactAddress) == compactAddress(address) }
            return candidate.name.map(names.contains) == true
        }
        guard matches.count == 1, let match = matches.first else {
            let detail = matches.isEmpty
                ? "Pair this speaker in System Settings → Bluetooth, then try again."
                : "Several paired speakers match. Give this speaker a unique Bluetooth name."
            throw NSError(domain: "PartyBoxAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        device = match
        let sameName = paired.filter { $0.name == match.name }
        uniqueName = sameName.count == 1 ? match.name : nil
    }

    /// Check for a live Bluetooth output with streams. A baseband link alone cannot play music.
    func isAvailableForOutput() -> Bool {
        guard device.isConnected() else { return false }
        let system = AudioObjectID(kAudioObjectSystemObject)
        for id in integers(system, kAudioHardwarePropertyDevices) {
            let transport = integers(id, kAudioDevicePropertyTransportType).first
            guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                  integers(id, kAudioDevicePropertyDeviceIsAlive).first == 1,
                  !integers(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty else { continue }
            if let address = device.addressString, !address.isEmpty, let uid = audioString(id, kAudioDevicePropertyDeviceUID),
               compactAddress(uid).contains(compactAddress(address)) { return true }
            if let uniqueName, audioString(id, kAudioObjectPropertyName) == uniqueName { return true }
        }
        return false
    }

    /// Build the audio reconnect command using this Mac’s Classic Bluetooth address.
    static func reconnectPacket() -> Data? {
        guard let text = IOBluetoothHostController.default()?.addressAsString(),
              let bytes = addressBytes(text) else { return nil }
        return Data([0xAA, 0x84, 0x06]) + bytes
    }

    /// Give the speaker time to reconnect, then initiate a paired Classic connection from macOS.
    /// Called on a worker queue because openConnection and the startup waits are synchronous.
    func waitForOutput() -> Bool {
        for second in 0..<25 {
            if isAvailableForOutput() { return true }
            if (second == 4 || second == 12), !device.isConnected() {
                // Page timeout is in 0.625 ms units. Limit each attempt to about five seconds.
                _ = device.openConnection(nil, withPageTimeout: 0x2000, authenticationRequired: true)
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return isAvailableForOutput()
    }
}

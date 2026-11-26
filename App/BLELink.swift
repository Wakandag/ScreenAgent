import Foundation
import CoreBluetooth

/// BLE transport for the board's app service (...0000): plain command lines out,
/// replies / status JSON / H.264 chunks in. Security is the iPhone's own bonded
/// LE link to the board, so there is no in-app pairing or session handshake.
final class BLELink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "6E400001-A9E8-4B1B-9C39-6D6F8A3C0000")
    private static let cmdUUID    = CBUUID(string: "6E400001-A9E8-4B1B-9C39-6D6F8A3C0001")
    private static let replyUUID  = CBUUID(string: "6E400001-A9E8-4B1B-9C39-6D6F8A3C0002")
    private static let statusUUID = CBUUID(string: "6E400001-A9E8-4B1B-9C39-6D6F8A3C0003")
    private static let videoUUID  = CBUUID(string: "6E400001-A9E8-4B1B-9C39-6D6F8A3C0004")

    enum State: String { case off, scanning, connecting, ready, lost }

    var onReply: ((String) -> Void)?
    var onStatus: ((Data) -> Void)?
    var onVideo: ((Data) -> Void)?
    var onState: ((State) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var connectingID: UUID?
    private var cmdChar: CBCharacteristic?
    private var notifyChars = Set<CBUUID>()
    private let requiredNotifies: Set<CBUUID> = [replyUUID, statusUUID, videoUUID]
    private var wantConnect = false
    private(set) var state: State = .off { didSet { if state != oldValue { onState?(state) } } }


    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        wantConnect = true
        if central.state == .poweredOn { scan() }
    }

    func stop() {
        wantConnect = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
    }

    private func scan() {
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    /// One command line, e.g. "3 stream on" or "4 move 12 0".
    func write(_ text: String) throws {
        guard let p = peripheral, let ch = cmdChar, p.state == .connected else {
            throw NSError(domain: "ble", code: 1, userInfo: [NSLocalizedDescriptionKey: "not connected"])
        }
        let data = Data(text.utf8)
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(data, for: ch, type: type)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if wantConnect { scan() }
        } else {
            state = .off
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil, connectingID == nil else { return }
        // The board's identity may carry a mode prefix ("CLI ESP32 Agent 38CD"),
        // so match the name anywhere and fall back to the advertised local name.
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard let name = peripheral.name ?? (advName.isEmpty ? nil : advName),
              name.range(of: "esp32 agent", options: .caseInsensitive) != nil else { return }
        // Only the app identity (service ...0000) is usable: the CLI identity (...0010)
        // is dropped by the firmware while the phone's own app link is up.
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        guard uuids.contains(Self.serviceUUID) else { return }
        connectingID = peripheral.identifier
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        connectingID = nil
        if wantConnect { scan() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        cmdChar = nil
        notifyChars.removeAll()
        state = .lost
        self.peripheral = nil
        connectingID = nil
        if wantConnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.scan() }
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.cmdUUID, Self.replyUUID, Self.statusUUID, Self.videoUUID],
                                           for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case Self.cmdUUID:
                cmdChar = ch
            case Self.replyUUID, Self.statusUUID, Self.videoUUID:
                notifyChars.insert(ch.uuid)
                peripheral.setNotifyValue(true, for: ch)
            default:
                break
            }
        }
        if cmdChar != nil, notifyChars.isSuperset(of: requiredNotifies) {
            state = .ready
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let d = characteristic.value, !d.isEmpty else { return }
        switch characteristic.uuid {
        case Self.replyUUID:
            onReply?(String(decoding: d, as: UTF8.self))
        case Self.statusUUID:
            onStatus?(d)
        case Self.videoUUID:
            onVideo?(d)
        default:
            break
        }
    }
}

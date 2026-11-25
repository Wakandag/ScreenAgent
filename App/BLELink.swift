import Foundation
import CoreBluetooth

/// BLE transport for the board's CLI service (...0010). One frame per notify / write.
final class BLELink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let serviceUUID  = CBUUID(string: "6E400001-A9E8-4B1B-9C39-6D6F8A3C0010")
    private static let inUUID   = CBUUID(string: "6E400001-A9E8-4B1B-9C39-6D6F8A3C0011")
    private static let outUUID  = CBUUID(string: "6E400001-A9E8-4B1B-9C39-6D6F8A3C0012")
    private static let inNRUUID = CBUUID(string: "6E400001-A9E8-4B1B-9C39-6D6F8A3C0013")

    enum State: String { case off, scanning, connecting, ready, lost }

    var onFrame: ((Data) -> Void)?
    var onState: ((State) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var connectingID: UUID?
    private var inChar: CBCharacteristic?
    private var outChar: CBCharacteristic?
    private var inNRChar: CBCharacteristic?
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

    func write(_ frame: Data) throws {
        guard let p = peripheral, let inCh = inChar, p.state == .connected else {
            throw NSError(domain: "ble", code: 1, userInfo: [NSLocalizedDescriptionKey: "not connected"])
        }
        let nrMax = p.maximumWriteValueLength(for: .withoutResponse)
        if frame.count <= min(nrMax, 512), let nr = inNRChar {
            p.writeValue(frame, for: nr, type: .withoutResponse)
        } else {
            p.writeValue(frame, for: inCh, type: .withResponse)   // OS splits into long writes
        }
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
        guard let name = peripheral.name, name.hasPrefix("ESP32 Agent") else { return }
        // only the CLI identity (service ...0010); the app identity advertises ...0000
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
        inChar = nil; outChar = nil; inNRChar = nil
        state = .lost
        self.peripheral = nil
        connectingID = nil
        if wantConnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.scan() }
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first else { return }
        peripheral.discoverCharacteristics([Self.inUUID, Self.outUUID, Self.inNRUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case Self.inUUID: inChar = ch
            case Self.outUUID:
                outChar = ch
                peripheral.setNotifyValue(true, for: ch)
            case Self.inNRUUID: inNRChar = ch
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == Self.outUUID, error == nil {
            state = .ready
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.outUUID, let d = characteristic.value else { return }
        onFrame?(d)
    }
}

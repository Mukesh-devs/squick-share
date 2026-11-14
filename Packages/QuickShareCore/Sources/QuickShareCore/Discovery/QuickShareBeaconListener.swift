import CoreBluetooth
import Foundation

public enum BeaconListenerStatus: Sendable, Equatable {
    /// Not started, or turned off in settings.
    case off
    /// Scanning for nearby phones.
    case listening
    /// Bluetooth is switched off on this Mac.
    case bluetoothOff
    /// The user did not allow Bluetooth for this app.
    case notAllowed
    /// This Mac has no usable Bluetooth LE.
    case unsupported
}

/// Listens for the Bluetooth LE advert an Android phone sends when its Quick Share sheet opens
/// ("fast initiation": service 0xFE2C, data starting FC 12 8E). Phones that start looking only see
/// a Mac whose Bonjour announcement arrives after they started, so the caller re-announces then.
///
/// It only scans: macOS apps can't put service data in their own adverts, so the Mac can't wake
/// phones the way RQuickShare does on Linux. Scanning is passive, filtered by service UUID, and
/// reports each phone at most once per `minimumInterval`.
public final class QuickShareBeaconListener: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    static var serviceUUID: CBUUID { CBUUID(string: "FE2C") }
    static let modelID: [UInt8] = [0xFC, 0x12, 0x8E]

    private let queue = DispatchQueue(label: "squickshare.beacon")
    private let diagnostics: Diagnostics
    private let minimumInterval: TimeInterval
    private let onBeacon: @Sendable () -> Void
    private let onStatus: @Sendable (BeaconListenerStatus) -> Void
    // Touched only on `queue`.
    private var central: CBCentralManager?
    private var lastBeacon = Date.distantPast
    private var restartTimer: DispatchSourceTimer?
    private var status: BeaconListenerStatus = .off

    /// - Parameters:
    ///   - minimumInterval: ignore beacons for this long after one was reported.
    ///   - onBeacon: called on a background queue when a phone starts sharing nearby.
    public init(diagnostics: Diagnostics, minimumInterval: TimeInterval = 10,
                onBeacon: @escaping @Sendable () -> Void,
                onStatus: @escaping @Sendable (BeaconListenerStatus) -> Void = { _ in }) {
        self.diagnostics = diagnostics
        self.minimumInterval = minimumInterval
        self.onBeacon = onBeacon
        self.onStatus = onStatus
        super.init()
    }

    /// Starts listening. The first call may show the system's Bluetooth permission prompt.
    public func start() {
        queue.async { [self] in
            guard central == nil else { return }
            // No power alert: a Mac with Bluetooth off should not nag; we fall back to Wi-Fi only.
            central = CBCentralManager(delegate: self, queue: queue,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    public func stop() {
        queue.async { [self] in
            restartTimer?.cancel()
            restartTimer = nil
            if central?.state == .poweredOn { central?.stopScan() }
            central?.delegate = nil
            central = nil
            setStatus(.off)
        }
    }

    private func setStatus(_ new: BeaconListenerStatus) {
        guard new != status else { return }
        status = new
        onStatus(new)
    }

    private func startScanning() {
        guard let central, central.state == .poweredOn else { return }
        central.stopScan()
        // Without duplicates the system reports each advertiser once per scan, which is cheap.
        central.scanForPeripherals(withServices: [Self.serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        // Restart now and then so a phone that shares again with the same address is seen again.
        if restartTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.startScanning() }
            timer.resume()
            restartTimer = timer
        }
    }

    // MARK: CBCentralManagerDelegate (called on `queue`)

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            diagnostics.info("beacon", "listening for phones that start sharing")
            setStatus(.listening)
            startScanning()
        case .poweredOff:
            setStatus(.bluetoothOff)
        case .unauthorized:
            diagnostics.info("beacon", "Bluetooth not allowed; using Wi-Fi announcements only")
            setStatus(.notAllowed)
        case .unsupported:
            setStatus(.unsupported)
        default:
            break
        }
        if central.state != .poweredOn {
            restartTimer?.cancel()
            restartTimer = nil
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        guard Self.isQuickShareBeacon(serviceData?[Self.serviceUUID]) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastBeacon) >= minimumInterval else { return }
        lastBeacon = now
        diagnostics.info("beacon", "a nearby phone started Quick Share")
        onBeacon()
    }

    /// Fast Pair accessories (earbuds) use the same service UUID; only Quick Share's model ID counts.
    static func isQuickShareBeacon(_ data: Data?) -> Bool {
        guard let data, data.count >= modelID.count else { return false }
        return Array(data.prefix(modelID.count)) == modelID
    }
}

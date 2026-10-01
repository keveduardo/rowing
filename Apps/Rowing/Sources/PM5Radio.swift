import CoreBluetooth
import Foundation
import Observation
import RowingKit

/// The watch's radio: the `CBCentralManager` that talks to a PM5, and nothing
/// else.
///
/// **Why the split is where it is.** `PM5` in `RowingKit` turns bytes into
/// metrics and is exercised by `swift test` on kevg10. This file cannot be:
/// it is the piece that needs a radio. So the protocol is proven by tests, and
/// only the plumbing is proven by a build.
///
/// **Where it came from.** The Hub's rowing tile (withdrawn 2026-09-29, still
/// at `637e4a7`). Two things changed on the way to the watch: state
/// restoration is gone, because on watchOS the running workout session is what
/// keeps the app alive with the wrist down; and characteristic discovery is
/// fixed — the tile's version never asked for the characteristics after
/// finding the service, so it would have subscribed to nothing.
///
/// **Why the callbacks do not hop actors.** The manager is created with the
/// main queue, so every delegate callback is already on the main actor; each
/// one asserts that with `assumeIsolated` rather than dispatching. A hop would
/// be a reordering hazard, and PM5 notifications have a meaningful order —
/// a stroke's `0x0035` belongs after the `0x0031` that carries its elapsed
/// time, and a summary's totals after the state that ended the piece.
@MainActor
@Observable
final class PM5Radio: NSObject {
    /// Where the connection is. Rendered, never assumed: a failure says why,
    /// and a radio has more ways to fail than most.
    enum Phase: Equatable {
        /// The watch's Bluetooth is off. Recoverable by the person, so it is
        /// named separately from a failure.
        case bluetoothOff
        /// The app has not been granted Bluetooth permission.
        case unauthorized
        case unsupported
        /// Powered on and not looking for anything.
        case idle
        case scanning
        case connecting(String)
        case connected(String)
        case failed(String)

        var label: String {
            switch self {
            case .bluetoothOff: "Bluetooth is off"
            case .unauthorized: "Allow Bluetooth in Settings"
            case .unsupported: "No Bluetooth on this watch"
            case .idle: "Ready"
            case .scanning: "Looking for the rower…"
            case .connecting(let name): "Connecting to \(name)…"
            case .connected(let name): name
            case .failed(let reason): reason
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    // MARK: What a screen reads

    private(set) var phase: Phase = .idle
    /// `0x0031`. Whether the rower is moving, and the running clocks.
    private(set) var generalStatus: PM5.GeneralStatus?
    /// `0x0032`. The live numbers: pace, rate, heart rate.
    private(set) var additionalStatus: PM5.AdditionalStatus?
    /// `0x0033`. Power, calories, and the split just finished.
    private(set) var additionalStatus2: PM5.AdditionalStatus2?
    /// `0x0035`. The last stroke.
    private(set) var strokeData: PM5.StrokeData?
    /// `0x0036`. Stroke power and the projected finish.
    private(set) var additionalStrokeData: PM5.AdditionalStrokeData?
    /// `0x0037`. The split in progress.
    private(set) var splitInterval: PM5.SplitIntervalData?
    /// `0x0038`. The split's averages.
    private(set) var additionalSplitInterval: PM5.AdditionalSplitIntervalData?
    /// `0x0039`. The finished workout. Expected **twice**: once when the row
    /// ends, and again about a minute later with recovery heart rate filled in.
    private(set) var workoutSummary: PM5.WorkoutSummary?
    /// `0x003A`. Watts and rest totals for the finished workout.
    private(set) var additionalSummary: PM5.AdditionalSummary?
    /// `0x003B`. Which belt the PM5 is paired to.
    private(set) var heartRateBelt: PM5.HeartRateBeltInfo?

    /// What each characteristic has sent this connection: how many payloads,
    /// how many decoded, and the last one's length. Shown on the controls page.
    ///
    /// ! Added 2026-09-29, after a first row where pace and stroke rate never
    /// appeared: they come only from 0x0032, and nothing said whether it was
    /// silent or arriving in a shape the parser refuses. A payload of a length
    /// the spec does not give is dropped by design (the multiplexed layouts
    /// reuse the same IDs), so the one way to learn what this PM5 sends is to
    /// count it.
    ///
    /// Not on screen since 1.0.1 — the End page showed these through 1.0. Kept
    /// because the next PM5 firmware that changes a length will need them
    /// again, and counting costs nothing.
    struct PayloadStat: Identifiable, Equatable {
        let id: String          // "0032"
        var seen = 0
        var decoded = 0
        var lastLength = 0
    }
    private(set) var payloadStats: [String: PayloadStat] = [:]

    /// The PM5's own name, `"PM5 <serial>"`. Also the serial, since the PM5
    /// exposes no other readable identifier before connecting.
    private(set) var peripheralName: String?

    /// How often the PM5 should notify. Written to `0x0034` on connect.
    /// The PM5 defaults to 500 ms `0x0034` is never written.
    var sampleRate: PM5.SampleRate = .halfSecond

    /// Every decoded notification, as it arrives.
    ///
    /// The radio keeps the latest of each metric for a view to draw; this is
    /// how the *store* sees the same stream and accumulates a workout from it.
    /// One notification, two readers — rather than the store re-deriving the
    /// events from the properties, which would lose the ones that arrive
    /// between view updates.
    @ObservationIgnored var onEvent: (@MainActor (PM5.Event) -> Void)?

    // MARK: Internals

    // `@ObservationIgnored` because these are plumbing, not state a view reads,
    // and re-registering them with the observation machinery on every
    // notification would be pure cost.
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var characteristics: [String: CBCharacteristic] = [:]
    /// Set while the person wants to be connected, so an unexpected disconnect
    /// reconnects instead of quietly ending the session.
    @ObservationIgnored private var wantsConnection = false
    /// A reconnect in flight. CoreBluetooth does not time connection requests
    /// out, so one that fails needs to be retried rather than left pending.
    @ObservationIgnored private var didAttemptReconnect = false

    /// Start the manager. Safe to call more than once; the second call does
    /// nothing. Creating the manager is what asks for Bluetooth permission, so
    /// it waits until someone starts a row.
    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Look for a rower.
    ///
    /// The scan is filtered by the C2 rowing service rather than scanning
    /// everything nearby, which is what the spec asks for — *"the mobile device
    /// application should use the proprietary C2 base UUID, advertised in a
    /// Scan Response packet, to filter the selection of BTS devices available
    /// to connect to."* It also matters for battery and for the background:
    /// iOS coalesces and slows unfiltered background scans, and an unfiltered
    /// scan would report every device in the building.
    ///
    /// *If discovery turns out to be unreliable on the real monitor*, the
    /// fallback is `scanForPeripherals(withServices: nil)` plus a local check
    /// on `peripheral.name` starting with `"PM5"` — the PM5 advertises its own
    /// name, and the serial is in it. That costs battery, so it is worth trying
    /// the spec's way first.
    func scan() {
        start()
        wantsConnection = true
        guard let central, central.state == .poweredOn else {
            // The manager was only just created, or Bluetooth is off. Either
            // way the scan starts from `centralDidUpdateState` once it can.
            return
        }
        guard !phase.isConnected, peripheral == nil else { return }
        didAttemptReconnect = false
        phase = .scanning
        central.scanForPeripherals(
            withServices: Self.advertised,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    /// What a PM5 is recognised by in a scan. A scan matches *any* of these.
    ///
    /// ! The base UUID (`CE060000`) is what the PM5 advertises, as far as other
    /// clients show — ergometer.js filters on exactly it — and it is not the
    /// rowing service (`CE060030`) this radio then reads. The Hub's version
    /// filtered on the rowing service alone and would plausibly have found
    /// nothing. Both are listed until a real PM5 says which it sends.
    private static let advertised = [
        CBUUID(string: PM5.baseUUID.replacingOccurrences(of: "XXXX", with: "0000")),
        CBUUID(string: PM5.Characteristic.rowingService.rawValue),
    ]

    /// Stop everything and forget the connection. Called when the workout
    /// ends — a rower held open with nothing reading it is a battery cost on
    /// both ends.
    ///
    /// Note this does *not* stop an in-progress workout from being finished;
    /// accumulating and saving a workout is the store's job, not the radio's.
    func stop() {
        wantsConnection = false
        didAttemptReconnect = false
        if let peripheral, peripheral.state != .disconnected {
            central?.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()
        peripheral = nil
        characteristics = [:]
        peripheralName = nil
        payloadStats = [:]
        phase = .idle
    }

    // MARK: Applying decoded notifications

    /// Route one decoded event to the property a view reads.
    ///
    /// Kept separate from the delegate callback so the mapping is one readable
    /// switch rather than a second layer of logic inside an Objective-C shim.
    private func apply(_ event: PM5.Event) {
        switch event {
        case .generalStatus(let value): generalStatus = value
        case .additionalStatus(let value): additionalStatus = value
        case .additionalStatus2(let value): additionalStatus2 = value
        case .strokeData(let value): strokeData = value
        case .additionalStrokeData(let value): additionalStrokeData = value
        case .splitInterval(let value): splitInterval = value
        case .additionalSplitInterval(let value): additionalSplitInterval = value
        case .workoutSummary(let value): workoutSummary = value
        case .additionalSummary(let value): additionalSummary = value
        case .heartRateBelt(let value): heartRateBelt = value
        }
        // After the properties, so a reader of either sees a consistent picture:
        // by the time the store is told, the screen's own state is already right.
        onEvent?(event)
    }

    /// Everything the PM5 will notify on, minus the ones this client does not
    /// model. Subscribing to a characteristic the PM5 does not have is not an
    /// error — `didDiscoverCharacteristicsFor` simply never mentions it.
    ///
    /// `0x0080` is deliberately absent: it is the multiplexed characteristic,
    /// its payloads are *different layouts under the same IDs*, and it stays
    /// silent while the standalone notifications are on. See the note at the
    /// top of `PM5.swift`.
    private static let subscribing: [PM5.Characteristic] = [
        .generalStatus, .additionalStatus, .additionalStatus2, .strokeData,
        .additionalStrokeData, .splitIntervalData, .additionalSplitIntervalData,
        .endOfWorkoutSummary, .endOfWorkoutAdditionalSummary, .heartRateBeltInfo,
    ]

    /// Put the delegates back on a peripheral and re-subscribe.
    ///
    /// Called once the link is up: the peripheral gets its delegate, then its
    /// services are discovered, then each service's characteristics, and only
    /// then can anything be subscribed to.
    private func adopt(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        peripheralName = peripheral.name

        guard peripheral.state == .connected else { return }
        phase = .connected(peripheral.name ?? "rower")
        peripheral.discoverServices([CBUUID(string: PM5.Characteristic.rowingService.rawValue)])
    }

    /// Ask each discovered service for its characteristics.
    ///
    /// ! This is the step the Hub's version skipped. `discoverServices` fills
    /// in `peripheral.services` and nothing else — every service's
    /// `characteristics` stays nil until asked for, so subscribing straight
    /// after service discovery walks an empty list and the PM5 never sends a
    /// thing.
    private func discoverCharacteristics(of peripheral: CBPeripheral) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    /// Turn on notifications for everything this client wants, and set the
    /// sample rate.
    private func subscribe(to peripheral: CBPeripheral) {
        guard let services = peripheral.services else { return }
        for service in services {
            guard let found = service.characteristics else { continue }
            for characteristic in found {
                let uuid = characteristic.uuid.uuidString.uppercased()
                guard let known = PM5.Characteristic(rawValue: uuid) else { continue }
                characteristics[uuid] = characteristic

                if Self.subscribing.contains(known), characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                // The PM5 only broadcasts at the rate it is told to, and 500 ms
                // is its own default. Writing the same value it already has is
                // harmless, so this does not check first.
                if known == .sampleRate, characteristic.properties.contains(.write) {
                    peripheral.writeValue(Data([sampleRate.rawValue]), for: characteristic, type: .withResponse)
                }
            }
        }
    }
}

// MARK: - Handing CoreBluetooth's objects to the main actor

/// A deliberate, narrow hole in Swift 6's region analysis, for CoreBluetooth's
/// delegate parameters.
///
/// CoreBluetooth predates Swift concurrency. Its delegate methods hand out
/// `CBCentralManager`, `CBPeripheral`, `CBCharacteristic` and
/// `[String: Any]`, none of which are `Sendable`, and Apple has not annotated
/// them — so the compiler cannot see what is actually true here: **every one of
/// these callbacks arrives on the main queue**, because that is the queue the
/// manager was created with, and `MainActor.assumeIsolated` asserts exactly
/// that before the value is touched. Nothing crosses a thread.
///
/// Where a callback only needs a value that *is* `Sendable` — a state, a UUID
/// string, a `Data` payload, a name — that value is extracted first and this
/// box is not used at all. It is reserved for the handful of cases that must
/// call back into the peripheral itself (`connect`, `discoverServices`,
/// `setNotifyValue`, `writeValue`), where the object has to come along.
///
/// The alternative — dropping `@MainActor` and marshalling every callback by
/// hand — would give up the ordering guarantee that makes the PM5's
/// notifications land in the order it sent them, which is worth more than the
/// annotation is.
private struct MainThreadOnly<T>: @unchecked Sendable {
    let value: T
}

// MARK: - CBCentralManagerDelegate

extension PM5Radio: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Only the state is needed, and it is Sendable on its own — no box.
        let state = central.state
        MainActor.assumeIsolated { centralDidUpdateState(state) }
    }

    private func centralDidUpdateState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            if !phase.isConnected { phase = .idle }
            // A scan asked for before the radio was ready starts now.
            if wantsConnection, peripheral == nil { scan() }
        case .poweredOff: phase = .bluetoothOff
        case .unauthorized: phase = .unauthorized
        case .unsupported: phase = .unsupported
        // `.unknown` and `.resetting` are transients on the way to one of the
        // above, not failures worth drawing.
        case .unknown, .resetting: break
        @unknown default: phase = .failed("Bluetooth is in an unexpected state")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // The advertisement and RSSI are deliberately unread: the scan is
        // already filtered to the C2 rowing service, so anything that arrives
        // here is a rower, and signal strength is not a better answer than
        // first-found when there is normally one of them in the room.
        let found = MainThreadOnly(value: (central, peripheral))
        MainActor.assumeIsolated { discovered(found.value.0, found.value.1) }
    }

    private func discovered(_ central: CBCentralManager, _ peripheral: CBPeripheral) {
        // ! Stop at the first one. The PM5's Bluetooth is 1:1 — it holds a
        // single connection — so a second rower on this screen would be two
        // clients fighting over one radio, and the loser's session is the one
        // that would silently stop.
        guard wantsConnection, self.peripheral == nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        phase = .connecting(peripheral.name ?? "rower")
        central.connect(peripheral)
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let connected = MainThreadOnly(value: peripheral)
        MainActor.assumeIsolated {
            didAttemptReconnect = false
            adopt(connected.value)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        // Only the reason is needed, so only the reason crosses.
        let message = error?.localizedDescription ?? "Could not connect to the rower"
        MainActor.assumeIsolated {
            self.peripheral = nil
            phase = .failed(message)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        let dropped = MainThreadOnly(value: (central, peripheral))
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            droppedLink(dropped.value.0, dropped.value.1, isReconnecting: isReconnecting, reason: message)
        }
    }

    private func droppedLink(
        _ central: CBCentralManager,
        _ peripheral: CBPeripheral,
        isReconnecting: Bool,
        reason: String?
    ) {
        characteristics = [:]
        // CoreBluetooth is already retrying this one, so there is nothing to add.
        if isReconnecting { return }

        guard wantsConnection, !didAttemptReconnect else {
            self.peripheral = nil
            phase = reason.map { .failed($0) } ?? .idle
            return
        }

        // A dropped link mid-row. Connection requests do not time out, which is
        // why asking again is the documented way to keep trying — and the flag
        // is what stops an endless reconnect against a rower that has been
        // switched off, which is a battery drain with nobody watching.
        didAttemptReconnect = true
        phase = .connecting(peripheral.name ?? "rower")
        central.connect(peripheral)
    }
}

// MARK: - CBPeripheralDelegate

extension PM5Radio: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let message = error?.localizedDescription
        let found = MainThreadOnly(value: peripheral)
        MainActor.assumeIsolated {
            guard message == nil else {
                phase = .failed(message ?? "Could not read the rower's services")
                return
            }
            discoverCharacteristics(of: found.value)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let message = error?.localizedDescription
        let found = MainThreadOnly(value: peripheral)
        MainActor.assumeIsolated {
            guard message == nil else { return }
            subscribe(to: found.value)
        }
    }

    /// The hot path — one of these per notification — and the one that needs no
    /// box at all: a UUID string and a `Data` payload are both `Sendable`, and
    /// they are the whole of what the parser takes.
    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let bytes = characteristic.value else { return }
        let uuid = characteristic.uuid.uuidString
        MainActor.assumeIsolated { receive(uuid: uuid, bytes: bytes) }
    }

    private func receive(uuid: String, bytes: Data) {
        // Unknown characteristics, the services, and payloads of the wrong
        // length all come back nil rather than throwing: a row must not end
        // because the PM5 sent something this client does not model.
        let event = PM5.decode(uuid: uuid, bytes: bytes)
        let key = String(uuid.uppercased().prefix(8).suffix(4))
        var stat = payloadStats[key] ?? PayloadStat(id: key)
        stat.seen += 1
        if event != nil { stat.decoded += 1 }
        stat.lastLength = bytes.count
        payloadStats[key] = stat
        guard let event else { return }
        apply(event)
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let error else { return }
        let uuid = characteristic.uuid.uuidString.uppercased()
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            // Only the sample rate is ever written. A rejected write is worth
            // surfacing: it means the PM5 is notifying at its own default rate,
            // which a live pace display would show as a stutter.
            guard uuid == PM5.Characteristic.sampleRate.rawValue else { return }
            phase = .failed("The rower refused the sample rate: \(message)")
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let error else { return }
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            phase = .failed("Could not subscribe to the rower: \(message)")
        }
    }
}

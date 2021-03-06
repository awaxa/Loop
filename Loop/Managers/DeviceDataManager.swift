//
//  DeviceDataManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 8/30/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import Foundation
import CarbKit
import CoreData
import GlucoseKit
import HealthKit
import InsulinKit
import LoopKit
import LoopUI
import MinimedKit
import NightscoutUploadKit
import RileyLinkKit


final class DeviceDataManager {

    // MARK: - Utilities

    let logger = DiagnosticLogger.shared!

    /// Remember the launch date of the app for diagnostic reporting
    fileprivate let launchDate = Date()

    /// Manages all the RileyLinks
    let rileyLinkManager: RileyLinkDeviceManager

    /// Manages authentication for remote services
    let remoteDataManager = RemoteDataManager()

    private var nightscoutDataManager: NightscoutDataManager!

    fileprivate var latestPumpStatus: RileyLinkKit.PumpStatus?

    private(set) var lastError: (date: Date, error: Error)?

    fileprivate func setLastError(error: Error) {
        DispatchQueue.main.async { // Synchronize writes
            self.lastError = (date: Date(), error: error)
            // TODO: Notify observers of change
        }
    }

    // Returns a value in the range 0 - 1
    var pumpBatteryChargeRemaining: Double? {
        get {
            if let status = latestPumpStatusFromMySentry {
                return Double(status.batteryRemainingPercent) / 100
            } else if let status = latestPumpStatus {
                return batteryChemistry.chargeRemaining(voltage: status.batteryVolts)
            } else {
                return statusExtensionManager.context?.batteryPercentage
            }
        }
    }

    // Battery monitor
    fileprivate func observeBatteryDuring(_ block: () -> Void) {
        let oldVal = pumpBatteryChargeRemaining
        block()
        if let newVal = pumpBatteryChargeRemaining {
            if newVal == 0 {
                NotificationManager.sendPumpBatteryLowNotification()
            }

            if let oldVal = oldVal, newVal - oldVal >= 0.5 {
                AnalyticsManager.shared.pumpBatteryWasReplaced()
            }
        }
    }

    // MARK: - RileyLink

    @objc private func receivedRileyLinkManagerNotification(_ note: Notification) {
        NotificationCenter.default.post(name: note.name, object: self, userInfo: note.userInfo)

        switch note.name {
        case Notification.Name.DeviceConnectionStateDidChange,
             Notification.Name.DeviceNameDidChange:
            // Update the HKDevice to include the name or connection status change
            if let device = rileyLinkManager.firstConnectedDevice?.device {
                loopManager.doseStore.setDevice(device)
            }
        default:
            break
        }
    }

    /**
     Called when a new idle message is received by the RileyLink.

     Only MySentryPumpStatus messages are handled.

     - parameter note: The notification object
     */
    @objc private func receivedRileyLinkPacketNotification(_ note: Notification) {
        if let
            device = note.object as? RileyLinkDevice,
            let data = note.userInfo?[RileyLinkDevice.IdleMessageDataKey] as? Data,
            let message = PumpMessage(rxData: data)
        {
            switch message.packetType {
            case .mySentry:
                switch message.messageBody {
                case let body as MySentryPumpStatusMessageBody:
                    updatePumpStatus(body, from: device)
                case is MySentryAlertMessageBody, is MySentryAlertClearedMessageBody:
                    break
                case let body:
                    logger.forCategory("MySentry").info(["messageType": Int(message.messageType.rawValue), "messageBody": body.txData.hexadecimalString])
                }
            default:
                break
            }
        }
    }

    @objc private func receivedRileyLinkTimerTickNotification(_: Notification) {
        cgmManager?.fetchNewDataIfNeeded(with: self) { (result) in
            self.cgmManager(self.cgmManager!, didUpdateWith: result)
        }
    }

    func connectToRileyLink(_ device: RileyLinkDevice) {
        connectedPeripheralIDs.insert(device.peripheral.identifier.uuidString)

        rileyLinkManager.connectDevice(device)

        AnalyticsManager.shared.didChangeRileyLinkConnectionState()
    }

    func disconnectFromRileyLink(_ device: RileyLinkDevice) {
        connectedPeripheralIDs.remove(device.peripheral.identifier.uuidString)

        rileyLinkManager.disconnectDevice(device)

        AnalyticsManager.shared.didChangeRileyLinkConnectionState()

        if connectedPeripheralIDs.count == 0 {
            NotificationManager.clearPendingNotificationRequests()
        }
    }

    fileprivate func updateTimerTickPreference() {
        /// Controls the management of the RileyLink timer tick, which is a reliably-changing BLE
        /// characteristic which can cause the app to wake. For most users, the G5 Transmitter and
        /// G4 Receiver are reliable as hearbeats, but users who find their resources extremely constrained
        /// due to greedy apps or older devices may choose to always enable the timer by always setting `true`
        rileyLinkManager.timerTickEnabled = pumpDataIsStale() || !(cgmManager?.providesBLEHeartbeat == true)
    }

    /**
     Attempts to fix an extended communication failure between a RileyLink device and the pump

     - parameter device: The RileyLink device
     */
    private func troubleshootPumpComms(using device: RileyLinkDevice) {
        // Ensuring timer tick is enabled will allow more tries to bring the pump data up-to-date.
        updateTimerTickPreference()

        // How long we should wait before we re-tune the RileyLink
        let tuneTolerance = TimeInterval(minutes: 14)

        if device.lastTuned == nil || device.lastTuned!.timeIntervalSinceNow <= -tuneTolerance {
            device.tunePump { (result) in
                switch result {
                case .success(let scanResult):
                    self.logger.addError("Device \(device.name ?? "") auto-tuned to \(scanResult.bestFrequency) MHz", fromSource: "RileyLink")
                case .failure(let error):
                    self.logger.addError("Device \(device.name ?? "") auto-tune failed with error: \(error)", fromSource: "RileyLink")
                    self.rileyLinkManager.deprioritizeDevice(device: device)
                    self.setLastError(error: error)
                }
            }
        } else {
            rileyLinkManager.deprioritizeDevice(device: device)
        }
    }

    // MARK: Pump data

    fileprivate var latestPumpStatusFromMySentry: MySentryPumpStatusMessageBody?

    /**
     Handles receiving a MySentry status message, which are only posted by MM x23 pumps.

     This message has two important pieces of info about the pump: reservoir volume and battery.

     Because the RileyLink must actively listen for these packets, they are not a reliable heartbeat. However, we can still use them to assert glucose data is current.

     - parameter status: The status message body
     - parameter device: The RileyLink that received the message
     */
    private func updatePumpStatus(_ status: MySentryPumpStatusMessageBody, from device: RileyLinkDevice) {
        var pumpDateComponents = status.pumpDateComponents
        var glucoseDateComponents = status.glucoseDateComponents

        pumpDateComponents.timeZone = pumpState?.timeZone
        glucoseDateComponents?.timeZone = pumpState?.timeZone

        // The pump sends the same message 3x, so ignore it if we've already seen it.
        guard status != latestPumpStatusFromMySentry, let pumpDate = pumpDateComponents.date else {
            return
        }

        observeBatteryDuring {
            latestPumpStatusFromMySentry = status
        }

        // Gather PumpStatus from MySentry packet
        let pumpStatus: NightscoutUploadKit.PumpStatus?
        if let pumpID = pumpID {
            let batteryStatus = BatteryStatus(percent: status.batteryRemainingPercent)
            let iobStatus = IOBStatus(timestamp: pumpDate, iob: status.iob)

            pumpStatus = NightscoutUploadKit.PumpStatus(clock: pumpDate, pumpID: pumpID, iob: iobStatus, battery: batteryStatus, reservoir: status.reservoirRemainingUnits)
        } else {
            pumpStatus = nil
            logger.addError("Could not interpret pump clock: \(pumpDateComponents)", fromSource: "RileyLink")
        }

        // Trigger device status upload, even if something is wrong with pumpStatus
        nightscoutDataManager.uploadDeviceStatus(pumpStatus, rileylinkDevice: device)

        switch status.glucose {
        case .active(glucose: let glucose):
            // Enlite data is included
            if let date = glucoseDateComponents?.date {
                loopManager.addGlucose([(
                    quantity: HKQuantity(unit: HKUnit.milligramsPerDeciliter(), doubleValue: Double(glucose)),
                    date: date,
                    isDisplayOnly: false
                )], from: nil)
            }
        case .off:
            // Enlite is disabled, so assert glucose from another source
            cgmManager?.fetchNewDataIfNeeded(with: self) { (result) in
                switch result {
                case .newData(let values):
                    self.loopManager.addGlucose(values, from: self.cgmManager?.device)
                case .noData:
                    break
                case .error(let error):
                    self.setLastError(error: error)
                    break
                }
            }
        default:
            break
        }

        // Upload sensor glucose to Nightscout
        remoteDataManager.nightscoutService.uploader?.uploadSGVFromMySentryPumpStatus(status, device: device.deviceURI)

        // Sentry packets are sent in groups of 3, 5s apart. Wait 11s before allowing the loop data to continue to avoid conflicting comms.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(11)) {
            self.updateReservoirVolume(status.reservoirRemainingUnits, at: pumpDate, withTimeLeft: TimeInterval(minutes: Double(status.reservoirRemainingMinutes)))
        }
    }

    /**
     Store a new reservoir volume and notify observers of new pump data.

     - parameter units:    The number of units remaining
     - parameter date:     The date the reservoir was read
     - parameter timeLeft: The approximate time before the reservoir is empty
     */
    private func updateReservoirVolume(_ units: Double, at date: Date, withTimeLeft timeLeft: TimeInterval?) {
        loopManager.addReservoirValue(units, at: date) { (result) in
            switch result {
            case .failure(let error):
                self.setLastError(error: error)
                self.logger.addError(error, fromSource: "DoseStore")
            case .success(let (newValue, lastValue, areStoredValuesContinuous)):
                // Run a loop as long as we have fresh, reliable pump data.
                if self.preferredInsulinDataSource == .pumpHistory || !areStoredValuesContinuous {
                    self.fetchPumpHistory { (error) in
                        if let error = error {
                            self.setLastError(error: error)
                        }

                        if error == nil || areStoredValuesContinuous {
                            self.loopManager.loop()
                        }
                    }
                } else {
                    self.loopManager.loop()
                }

                // Send notifications for low reservoir if necessary
                if let previousVolume = lastValue?.unitVolume {
                    guard newValue.unitVolume > 0 else {
                        NotificationManager.sendPumpReservoirEmptyNotification()
                        return
                    }

                    let warningThresholds: [Double] = [10]

                    for threshold in warningThresholds {
                        if newValue.unitVolume <= threshold && previousVolume > threshold {
                            NotificationManager.sendPumpReservoirLowNotificationForAmount(newValue.unitVolume, andTimeRemaining: timeLeft)
                        }
                    }

                    if newValue.unitVolume > previousVolume + 1 {
                        AnalyticsManager.shared.reservoirWasRewound()
                    }
                }
            }

            // New reservoir data means we may want to adjust our timer tick requirements
            self.updateTimerTickPreference()
        }
    }

    /// Polls the pump for new history events and passes them to the loop manager
    ///
    /// - Parameters:
    ///   - completion: A closure called once upon completion
    ///   - error: An error describing why the fetch and/or store failed
    fileprivate func fetchPumpHistory(_ completion: @escaping (_ error: Error?) -> Void) {
        guard let device = rileyLinkManager.firstConnectedDevice else {
            completion(LoopError.connectionError)
            return
        }

        let startDate = loopManager.doseStore.pumpEventQueryAfterDate

        device.ops?.getHistoryEvents(since: startDate) { (result) in
            switch result {
            case let .success(events, model):
                self.loopManager.addPumpEvents(events, from: model) { (error) in
                    if let error = error {
                        self.logger.addError("Failed to store history: \(error)", fromSource: "DoseStore")
                    }

                    completion(error)
                }
            case .failure(let error):
                self.rileyLinkManager.deprioritizeDevice(device: device)
                self.logger.addError("Failed to fetch history: \(error)", fromSource: "RileyLink")

                completion(error)
            }
        }
    }

    private func pumpDataIsStale() -> Bool {
        // How long should we wait before we poll for new pump data?
        let pumpStatusAgeTolerance = rileyLinkManager.idleListeningEnabled ? TimeInterval(minutes: 9) : TimeInterval(minutes: 4)

        return loopManager.doseStore.lastReservoirValue == nil
            || loopManager.doseStore.lastReservoirValue!.startDate.timeIntervalSinceNow <= -pumpStatusAgeTolerance
    }

    /**
     Ensures pump data is current by either waking and polling, or ensuring we're listening to sentry packets.
     */
    fileprivate func assertCurrentPumpData() {
        guard let device = rileyLinkManager.firstConnectedDevice else {
            self.setLastError(error: LoopError.connectionError)
            return
        }

        device.assertIdleListening()

        guard pumpDataIsStale() else {
            return
        }

        rileyLinkManager.readPumpData { (result) in
            let nsPumpStatus: NightscoutUploadKit.PumpStatus?
            switch result {
            case .success(let (status, date)):
                self.observeBatteryDuring {
                    self.latestPumpStatus = status
                }

                self.updateReservoirVolume(status.reservoir, at: date, withTimeLeft: nil)
                let battery = BatteryStatus(voltage: status.batteryVolts, status: BatteryIndicator(batteryStatus: status.batteryStatus))

                nsPumpStatus = NightscoutUploadKit.PumpStatus(clock: date, pumpID: status.pumpID, iob: nil, battery: battery, suspended: status.suspended, bolusing: status.bolusing, reservoir: status.reservoir)
            case .failure(let error):
                self.logger.addError("Failed to fetch pump status: \(error)", fromSource: "RileyLink")
                self.setLastError(error: error)
                self.troubleshootPumpComms(using: device)
                self.nightscoutDataManager.uploadLoopStatus(loopError: error)
                nsPumpStatus = nil
            }
            self.nightscoutDataManager.uploadDeviceStatus(nsPumpStatus, rileylinkDevice: device)
        }
    }

    /// Send a bolus command and handle the result
    ///
    /// - parameter units:      The number of units to deliver
    /// - parameter completion: A clsure called after the command is complete. This closure takes a single argument:
    ///     - error: An error describing why the command failed
    func enactBolus(units: Double, at startDate: Date = Date(), completion: @escaping (_ error: Error?) -> Void) {
        let notify = { (error: Error?) -> Void in
            if let error = error {
                NotificationManager.sendBolusFailureNotification(for: error, units: units, at: startDate)
            }

            completion(error)
        }

        guard units > 0 else {
            notify(nil)
            return
        }

        guard let device = rileyLinkManager.firstConnectedDevice else {
            notify(LoopError.connectionError)
            return
        }

        guard let ops = device.ops else {
            notify(LoopError.configurationError("PumpOps"))
            return
        }

        let setBolus = {
            self.loopManager.addRequestedBolus(units: units, at: Date()) {
                ops.setNormalBolus(units: units) { (error) in
                    if let error = error {
                        self.logger.addError(error, fromSource: "Bolus")
                        notify(error)
                    } else {
                        self.loopManager.addConfirmedBolus(units: units, at: Date()) {
                             notify(nil)
                        }
                    }
                }
            }
        }

        // If we don't have recent pump data, or the pump was recently rewound, read new pump data before bolusing.
        if  loopManager.doseStore.lastReservoirValue == nil ||
            loopManager.doseStore.lastReservoirVolumeDrop < 0 ||
            loopManager.doseStore.lastReservoirValue!.startDate.timeIntervalSinceNow <= TimeInterval(minutes: -6)
        {
            rileyLinkManager.readPumpData { (result) in
                switch result {
                case .success(let (status, date)):
                    self.loopManager.addReservoirValue(status.reservoir, at: date) { (result) in
                        switch result {
                        case .failure(let error):
                            self.logger.addError(error, fromSource: "Bolus")
                            notify(error)
                        case .success:
                            setBolus()
                        }
                    }
                case .failure(let error):
                    switch error {
                    case let error as PumpCommsError:
                        notify(SetBolusError.certain(error))
                    default:
                        notify(error)
                    }

                    self.logger.addError("Failed to fetch pump status: \(error)", fromSource: "RileyLink")
                }
            }
        } else {
            setBolus()
        }
    }

    // MARK: - CGM

    var cgm: CGM? = UserDefaults.standard.cgm {
        didSet {
            if cgm != oldValue {
                setupCGM()
            }

            UserDefaults.standard.cgm = cgm
        }
    }

    private(set) var cgmManager: CGMManager?

    private func setupCGM() {
        cgmManager = cgm?.createManager()
        cgmManager?.delegate = self
        loopManager.glucoseStore.managedDataInterval = cgmManager?.managedDataInterval

        updateTimerTickPreference()
    }

    var sensorInfo: SensorDisplayable? {
        return cgmManager?.sensorState ?? latestPumpStatusFromMySentry
    }

    // MARK: - Configuration

    // MARK: Pump

    private var connectedPeripheralIDs: Set<String> = Set(UserDefaults.standard.connectedPeripheralIDs) {
        didSet {
            UserDefaults.standard.connectedPeripheralIDs = Array(connectedPeripheralIDs)
        }
    }

    var pumpID: String? {
        get {
            return pumpState?.pumpID
        }
        set {
            guard newValue != pumpState?.pumpID else {
                return
            }

            var pumpID = newValue

            if let pumpID = pumpID, pumpID.count == 6 {
                let pumpState = PumpState(pumpID: pumpID, pumpRegion: self.pumpState?.pumpRegion ?? .northAmerica)

                if let timeZone = self.pumpState?.timeZone {
                    pumpState.timeZone = timeZone
                }

                self.pumpState = pumpState
            } else {
                pumpID = nil
                self.pumpState = nil
            }

            remoteDataManager.nightscoutService.uploader?.reset()

            loopManager.doseStore.resetPumpData()

            UserDefaults.standard.pumpID = pumpID
        }
    }

    var pumpState: PumpState? {
        didSet {
            rileyLinkManager.pumpState = pumpState

            if let oldValue = oldValue {
                NotificationCenter.default.removeObserver(self, name: .PumpStateValuesDidChange, object: oldValue)
            }

            if let pumpState = pumpState {
                NotificationCenter.default.addObserver(self, selector: #selector(pumpStateValuesDidChange(_:)), name: .PumpStateValuesDidChange, object: pumpState)
            }
        }
    }

    @objc private func pumpStateValuesDidChange(_ note: Notification) {
        switch note.userInfo?[PumpState.PropertyKey] as? String {
        case "timeZone"?:
            UserDefaults.standard.pumpTimeZone = pumpState?.timeZone

            if let pumpTimeZone = pumpState?.timeZone {
                loopManager.setScheduleTimeZone(pumpTimeZone)
            }
        case "pumpModel"?:
            if let sentrySupported = pumpState?.pumpModel?.hasMySentry, !sentrySupported {
                rileyLinkManager.idleListeningEnabled = false
            }

            // Update the HKDevice to include the model change
            if let device = rileyLinkManager.firstConnectedDevice?.device {
                loopManager.doseStore.setDevice(device)
            }

            // Update the preference for basal profile start events
            if let recordsBasalProfileStartEvents = pumpState?.pumpModel?.recordsBasalProfileStartEvents {
                loopManager.doseStore.pumpRecordsBasalProfileStartEvents = recordsBasalProfileStartEvents
            }

            UserDefaults.standard.pumpModelNumber = pumpState?.pumpModel?.rawValue
        case "pumpRegion"?:
            UserDefaults.standard.pumpRegion = pumpState?.pumpRegion
        case "lastHistoryDump"?, "awakeUntil"?:
            break
        default:
            break
        }
    }

    /// The user's preferred method of fetching insulin data from the pump
    var preferredInsulinDataSource = UserDefaults.standard.preferredInsulinDataSource ?? .pumpHistory {
        didSet {
            UserDefaults.standard.preferredInsulinDataSource = preferredInsulinDataSource
        }
    }
    
    /// The pump battery chemistry, for voltage -> percentage calculation
    var batteryChemistry = UserDefaults.standard.batteryChemistry ?? .alkaline {
        didSet {
            UserDefaults.standard.batteryChemistry = batteryChemistry
        }
    }

    // MARK: - WatchKit

    fileprivate var watchManager: WatchDataManager!

    // MARK: - Status Extension

    fileprivate var statusExtensionManager: StatusExtensionDataManager!

    // MARK: - Initialization

    private(set) var loopManager: LoopDataManager!

    init() {
        let pumpID = UserDefaults.standard.pumpID

        var idleListeningEnabled = true

        if let pumpID = pumpID {
            let pumpState = PumpState(pumpID: pumpID, pumpRegion: UserDefaults.standard.pumpRegion ?? .northAmerica)

            if let timeZone = UserDefaults.standard.pumpTimeZone {
                pumpState.timeZone = timeZone
            } else {
                UserDefaults.standard.pumpTimeZone = TimeZone.current
            }

            if let pumpModelNumber = UserDefaults.standard.pumpModelNumber {
                if let model = PumpModel(rawValue: pumpModelNumber) {
                    pumpState.pumpModel = model

                    idleListeningEnabled = model.hasMySentry
                }
            }

            self.pumpState = pumpState
        }

        rileyLinkManager = RileyLinkDeviceManager(
            pumpState: self.pumpState,
            autoConnectIDs: connectedPeripheralIDs
        )
        rileyLinkManager.idleListeningEnabled = idleListeningEnabled

        NotificationCenter.default.addObserver(self, selector: #selector(receivedRileyLinkManagerNotification(_:)), name: nil, object: rileyLinkManager)
        NotificationCenter.default.addObserver(self, selector: #selector(receivedRileyLinkPacketNotification(_:)), name: .RileyLinkDeviceDidReceiveIdleMessage, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(receivedRileyLinkTimerTickNotification(_:)), name: .RileyLinkDeviceDidUpdateTimerTick, object: nil)

        if let pumpState = pumpState {
            NotificationCenter.default.addObserver(self, selector: #selector(pumpStateValuesDidChange(_:)), name: .PumpStateValuesDidChange, object: pumpState)
        }

        remoteDataManager.delegate = self
        statusExtensionManager = StatusExtensionDataManager(deviceDataManager: self)
        loopManager = LoopDataManager(
            delegate: self,
            lastLoopCompleted: statusExtensionManager.context?.loop?.lastCompleted,
            lastTempBasal: statusExtensionManager.context?.netBasal?.tempBasal
        )
        watchManager = WatchDataManager(deviceDataManager: self)
        nightscoutDataManager = NightscoutDataManager(deviceDataManager: self)

        loopManager.carbStore.syncDelegate = remoteDataManager.nightscoutService.uploader
        loopManager.doseStore.delegate = self
        // Proliferate PumpModel preferences to DoseStore
        if let pumpModel = pumpState?.pumpModel {
            loopManager.doseStore.pumpRecordsBasalProfileStartEvents = pumpModel.recordsBasalProfileStartEvents
        }

        setupCGM()
    }
}


extension DeviceDataManager: RemoteDataManagerDelegate {
    func remoteDataManagerDidUpdateServices(_ dataManager: RemoteDataManager) {
        loopManager.carbStore.syncDelegate = dataManager.nightscoutService.uploader
    }
}


extension DeviceDataManager: CGMManagerDelegate {
    func cgmManager(_ manager: CGMManager, didUpdateWith result: CGMResult) {
        switch result {
        case .newData(let values):
            loopManager.addGlucose(values, from: manager.device) { _ in
                self.assertCurrentPumpData()
            }
        case .noData:
            self.assertCurrentPumpData()
            break
        case .error(let error):
            self.setLastError(error: error)
            self.assertCurrentPumpData()
        }

        updateTimerTickPreference()
    }

    func startDateToFilterNewData(for manager: CGMManager) -> Date? {
        return loopManager.glucoseStore.latestGlucose?.startDate
    }
}


extension DeviceDataManager: DoseStoreDelegate {
    func doseStore(_ doseStore: DoseStore,
        hasEventsNeedingUpload pumpEvents: [PersistedPumpEvent],
        completion completionHandler: @escaping (_ uploadedObjects: [NSManagedObjectID]) -> Void
    ) {
        guard let uploader = remoteDataManager.nightscoutService.uploader, let pumpModel = pumpState?.pumpModel else {
            completionHandler(pumpEvents.map({ $0.objectID }))
            return
        }

        uploader.upload(pumpEvents, from: pumpModel) { (result) in
            switch result {
            case .success(let objects):
                completionHandler(objects)
            case .failure(let error):
                let logger = DiagnosticLogger.shared!.forCategory("NightscoutUploader")
                logger.error(error)
                completionHandler([])
            }
        }
    }
}


extension DeviceDataManager: LoopDataManagerDelegate {
    func loopDataManager(_ manager: LoopDataManager, didRecommendBasalChange basal: (recommendation: TempBasalRecommendation, date: Date), completion: @escaping (_ result: Result<DoseEntry>) -> Void) {
        guard let device = rileyLinkManager.firstConnectedDevice else {
            completion(.failure(LoopError.connectionError))
            return
        }

        guard let ops = device.ops else {
            completion(.failure(LoopError.configurationError("PumpOps")))
            return
        }

        let notify = { (result: Result<DoseEntry>) -> Void in
            // If we haven't fetched history in a while (preferredInsulinDataSource == .reservoir),
            // let's try to do so while the pump radio is on.
            if self.loopManager.doseStore.lastAddedPumpEvents.timeIntervalSinceNow < .minutes(-4) {
                self.fetchPumpHistory { (_) in
                    completion(result)
                }
            } else {
                completion(result)
            }
        }

        ops.setTempBasal(rate: basal.recommendation.unitsPerHour, duration: basal.recommendation.duration) { (result) -> Void in
            switch result {
            case .success(let body):
                let now = Date()
                let endDate = now.addingTimeInterval(body.timeRemaining)
                let startDate = endDate.addingTimeInterval(-basal.recommendation.duration)
                notify(.success(DoseEntry(
                    type: .tempBasal,
                    startDate: startDate,
                    endDate: endDate,
                    value: body.rate,
                    unit: .unitsPerHour
                )))
            case .failure(let error):
                notify(.failure(error))
            }
        }
    }
}


extension DeviceDataManager: CustomDebugStringConvertible {
    var debugDescription: String {
        return [
            Bundle.main.localizedNameAndVersion,
            "## DeviceDataManager",
            "launchDate: \(launchDate)",
            "cgm: \(String(describing: cgm))",
            "lastError: \(String(describing: lastError))",
            "latestPumpStatusFromMySentry: \(String(describing: latestPumpStatusFromMySentry))",
            "pumpState: \(String(reflecting: pumpState))",
            "preferredInsulinDataSource: \(preferredInsulinDataSource)",
            cgmManager != nil ? String(reflecting: cgmManager!) : "",
            String(reflecting: rileyLinkManager),
            String(reflecting: statusExtensionManager!),
        ].joined(separator: "\n")
    }
}

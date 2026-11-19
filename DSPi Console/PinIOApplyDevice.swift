import Foundation

// MARK: - The view model as a PinIODevice
//
// Every op goes through the view model's own setter, so published state
// follows each accepted SET exactly as it does for a single edit.  Blocking:
// run it off the main thread.

final class ViewModelPinIODevice: PinIODevice {
    private let vm: DSPViewModel

    init(_ vm: DSPViewModel) { self.vm = vm }

    func perform(_ op: PinIOOp) -> UInt8 {
        switch op {
        case .slotType(let s, let t): return vm.setOutputSlotType(slot: s, type: t)
        case .outputPin(let i, let p): return vm.setOutputPin(output: i, pin: p)
        case .pdmEnable(let on): return vm.setOutputEnableAndWait(output: vm.pdmOutputIndex, enabled: on)
        case .bckPin(let r, let p): return vm.setI2SBckPin(p, role: UInt8(r))
        case .clockPinMode(let m): return vm.setI2SClockPinMode(m)
        case .clockMode(let m): return vm.setI2SClockModeAndWait(m)
        case .mckEnable(let on): return vm.setMckEnable(on)
        case .mckPin(let p): return vm.setMckPin(p)
        case .mckMultiplier(let m): return vm.setMckMultiplier(m)
        case .spdifPin(let i, let p): return vm.setSpdifRxPin(index: i, p)
        case .spdifEnable(let i, let on): return vm.setSpdifInputEnable(index: i, on)
        case .i2sChannels(let n): return vm.setI2SInputChannels(n)
        case .i2sRxPin(let pair, let p): return vm.setI2SRxPin(pair: pair, p)
        case .i2sRate(let r): return vm.setInputRateAndWait(r)
        case .inputSource(let s): return vm.setInputSourceAndWait(s)
        case .adatPin(let p): return vm.setAdatPin(p)
        case .adatEnable(let on): return vm.setAdatEnable(on)
        case .adatInPin(let p): return vm.setAdatInputPin(p)
        case .adatInClockMode(let m): return vm.setAdatInputClockMode(m)
        case .adatInEnable(let on): return vm.setAdatInputEnable(on)
        }
    }

    func waitForApply(_ op: PinIOOp) -> Bool {
        let read: (VendorCommand, UInt16, UInt8)
        switch op {
        case .slotType(let slot, let type): read = (VC.OUTPUT.TYPE, UInt16(slot), type)
        case .inputSource(let src): read = (VC.INPUT.SOURCE, 0, UInt8(src))
        case .clockMode(let mode): read = (VC.CLOCK.I2S_CLOCK_MODE, 0, mode == I2S_CLOCK_MODE_SLAVE ? 1 : 0)
        default: return true
        }
        // The switch waits for a fade to silence and the DAC mute hold.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if vm.transport.getData(read.0, value: read.1, length: 1)?.first == read.2 { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // The setter already showed the new value; show what the device holds.
        switch op {
        case .slotType(let slot, _): vm.fetchOutputSlotType(slot: slot)
        case .inputSource: vm.fetchInputSource()
        case .clockMode: vm.fetchI2SClockMode()
        default: break
        }
        return false
    }

    /// PDM keeps its pin through a fade-out after the disable.  Its
    /// availability status reads VC_ERR_STATE until it has stopped.
    func waitForPdmStop() -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            switch vm.transport.get(VC.OUTPUT.PIN_AVAIL, value: UInt16(vm.pdmPinIndex),
                                    length: PinAvailability.maxReplySize) {
            case .success(let data):
                guard let a = PinAvailability.decode(data) else { return false }
                if a.status != VC_ERR_STATE_STATUS && a.status != VC_ERR_BUSY_STATUS { return true }
            case .failure(.vcUnknown):
                // Firmware without the query: allow the fade its usual time.
                Thread.sleep(forTimeInterval: 0.3)
                return true
            case .failure:
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func free(_ command: VendorCommand, _ value: Int) -> UInt64? {
        guard case .success(let data) = vm.transport.get(command, value: UInt16(value), length: PinAvailability.maxReplySize),
              let a = PinAvailability.decode(data) else { return nil }
        return a.masks.first?.first?.free
    }

    func freeMask(outputIndex: Int) -> UInt64? { free(VC.OUTPUT.PIN_AVAIL, outputIndex) }
    func freeMask(spdifInput: Int) -> UInt64? { free(VC.INPUT.SPDIF_RX_PIN_AVAIL, spdifInput) }
    func freeMask(i2sPair: Int) -> UInt64? { free(VC.INPUT.I2S_RX_PIN_AVAIL, i2sPair) }

    func claimedPins() -> Set<UInt8>? {
        guard case .success(let data) = vm.transport.get(VC.SYS.PIN_CLAIMS, length: PinClaimsReply.requestSize),
              let reply = PinClaimsReply.decode(data) else { return nil }
        return Set(reply.claims.map(\.gpio))
    }

    func conflictText(_ op: PinIOOp, pins: [UInt8]) -> String? {
        vm.describePinConflict(pins: pins)
    }
}

extension DSPViewModel {

    /// The hardware IO configuration as the app holds it.  Main thread.
    func currentPinIOConfig() -> PinIOConfig {
        var c = PinIOConfig()
        let slots = numOutputSlots
        c.slotTypes = Array(outputSlotTypes.prefix(slots))
        if outputPins.count > pdmPinIndex {
            c.outputPins = Array(outputPins.prefix(slots)) + [outputPins[pdmPinIndex]]
        }
        c.pdmEnabled = outputEnabled.indices.contains(pdmOutputIndex) ? outputEnabled[pdmOutputIndex] : nil
        if !platformName.hasPrefix("STM32") {
            c.bckPins = [i2sBckPin, i2sBckPinSlave]
            c.mckEnabled = mckEnabled
            c.mckPin = mckPin
            c.mckMultiplier = mckMultiplier
        }
        if i2sClockPinModeSupported { c.clockPinMode = i2sClockPinMode }
        if i2sClockModeSupported { c.clockMode = i2sClockMode }
        if inputSourceSupported {
            c.inputSource = inputSource
            let count = multiSpdifSupported ? spdifInputCount : 1
            c.spdifPins = (0..<count).map { spdifPin(index: $0) }
            c.spdifEnabled = (0..<count).map { $0 == 0 || spdifInputEnabled(index: $0) }
        }
        if i2sInputSupported {
            c.i2sChannels = i2sInputChannels
            c.i2sRxPins = Array(i2sRxPins.prefix(i2sMaxPairs))
            c.i2sRate = i2sInputRateHz
        }
        if adatSupported {
            c.adatPin = adatPin
            c.adatEnabled = adatEnabled
        }
        if adatInputSupported {
            c.adatInPin = adatInputPin
            c.adatInClockMode = adatInputClockMode
            c.adatInEnabled = adatInputEnabled
        }
        return c
    }

    /// Reach `target` from the current configuration.  Blocking; call off main.
    /// `current` is captured on main by the caller.
    func applyPinIO(current: PinIOConfig, target: PinIOConfig, interactive: Bool = false) -> PinIOApply {
        let generation = transport.generation
        let routine = PinIOApply(device: ViewModelPinIODevice(self), current: current, target: target,
                                 restoreRefusedPdm: interactive)
        routine.stillCurrent = { [weak self] in self?.transport.generation == generation }
        routine.run()
        DispatchQueue.main.async { self.refreshPinMap() }
        return routine
    }
}

import Foundation

// MARK: - Pin owners and the pin map, view-model side
//
// Names and lookups over the device's claim list.  The list is for display
// only (spec 8.4): which pins a function may take always comes from its
// availability reply, never from here.

extension DSPViewModel {

    /// What the pin map store sweeps for this board.
    var pinMapShape: PinMapShape {
        PinMapShape(pinOutputs: numOutputSlots + 1,
                    spdifInputs: inputSourceSupported ? max(1, spdifInputCount) : 0,
                    i2sPairs: i2sInputSupported ? i2sMaxPairs : 0,
                    csTypes: controlSurfacesSupported
                        ? (1..<csCaps.types.count).filter { csCaps.types[$0].pinCount > 0 }
                        : [])
    }

    /// Re-read the pin map (main thread).
    func refreshPinMap(force: Bool = false) {
        pinMap.updateShape(pinMapShape)
        pinMap.requestRefresh(force: force)
    }

    /// The `PinAvailKey` of an `OUTPUT.PIN` index (slots, then PDM).
    func outputPinKey(_ index: Int) -> PinAvailKey { .output(index) }

    // MARK: Names

    /// The name pickers and messages use for a claim's owner.
    func ownerName(_ claim: PinClaim) -> String {
        let i = Int(claim.index)
        guard let fn = claim.function else { return "Function \(claim.functionID)" }
        switch fn {
        case .output: return "Output \(i + 1)"
        case .pdm: return "Subwoofer"
        case .i2sClock:
            let lr = claim.role == 1
            return i == 0 ? (lr ? "I2S LRCLK" : "I2S BCK") : (lr ? "I2S Slave LRCLK" : "I2S Slave BCK")
        case .mck: return "I2S MCK"
        case .adatTx: return "ADAT Output"
        case .adatRx: return "ADAT Input"
        case .spdifRx:
            return multiSpdifSupported && spdifInputCount > 1 ? "S/PDIF \(i + 1) RX" : "S/PDIF RX"
        case .i2sRx: return i2sMaxPairs > 1 ? "I2S RX \(i + 1)" : "I2S RX"
        case .dacMute: return "DAC Mute"
        case .uartCtrl: return "UART Control"
        case .i2cCtrl: return "I2C Control"
        case .controlSurface: return "Control Surface \(i + 1)"
        }
    }

    /// Active owners of `pin`, other than `function` at `index`, joined for display.
    /// Nil when no other function holds it.
    func pinOwner(_ pin: UInt8, excluding function: PinFunction? = nil, index: Int = 0) -> String? {
        let names = pinMap.snapshot.claims(on: pin)
            .filter { claim in
                guard claim.active else { return false }
                guard let function else { return true }
                return !claim.isOwned(by: function, index: index)
            }
            .map(ownerName)
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }

    /// Why `pin` is outside a function's free mask, for a label that is never
    /// empty: the pin's own owners, then those of pin + 1 for a function whose
    /// role 0 implies a second pin, then a reason for blocks that hold no pin.
    func pinBlockReason(_ pin: UInt8, avail: PinAvailability,
                        function: PinFunction, index: Int = 0) -> String {
        if let owner = pinOwner(pin, excluding: function, index: index) { return owner }
        if avail.flags.contains(.pairPlusOne), pin < 63,
           let owner = pinOwner(pin + 1, excluding: function, index: index) {
            return "GPIO \(pin + 1): \(owner)"
        }
        switch function {
        case .i2cCtrl: return "I2C bus in use"
        case .controlSurface: return "in use"
        default: return "unavailable"
        }
    }

    /// Owners for the Overview: every claim on `pin`, active ones first.
    func pinClaimsForDisplay(_ pin: UInt8) -> [(name: String, role: PinRole, active: Bool)] {
        pinMap.snapshot.claims(on: pin)
            .sorted { $0.active && !$1.active }
            .map { (ownerName($0), $0.function?.role ?? .utility, $0.active) }
    }

    /// Message for a start refused with `VC_ERR_PIN_IN_USE`: names who holds
    /// the pins `function` needs, from a fresh claim list.  Blocks the caller
    /// for one GET; call it off the main thread.
    func describePinConflict(for function: PinFunction? = nil, index: Int = 0, pins: [UInt8]) -> String? {
        guard case .success(let data) = transport.get(VC.SYS.PIN_CLAIMS, length: PinClaimsReply.requestSize),
              let reply = PinClaimsReply.decode(data) else { return nil }
        let parts = pins.compactMap { pin -> String? in
            let owners = reply.claims.filter { claim in
                claim.gpio == pin && claim.active && !(function.map { claim.isOwned(by: $0, index: index) } ?? false)
            }
                .map(ownerName)
            return owners.isEmpty ? nil : "GPIO \(pin) is held by \(owners.joined(separator: ", "))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    // MARK: Starts the user asks for

    /// Send a SET that starts something pin-checked (the input source to I2S,
    /// the I2S clock mode, the PDM output).  A refusal on pins names who holds
    /// them; any other refusal is reported like `send`.  Either way the view
    /// model re-reads the device, so the optimistic UI springs back.
    func sendStart(_ command: VendorCommand, value: UInt16 = 0, data: Data, what: String,
                   function: PinFunction, index: Int = 0, pins: @escaping () -> [UInt8]) {
        transport.set(command, value: value, data: data) { [weak self] status in
            guard let self, status != .ok else { return }
            guard status == .vcPinInUse else {
                DeviceRefusal.notice.post(VendorRefusal(command: command, value: value, status: status))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let who = self.describePinConflict(for: function, index: index, pins: pins())
                DeviceRefusal.notice.show("Can't \(what): " + (who ?? "a pin it needs is in use"),
                                          detail: who)
                DispatchQueue.main.async { self.scheduleDeviceResync() }
            }
        }
    }

    /// The clock pair the I2S clocks run on (or would start on) now.
    var activeI2SClockPins: [UInt8] {
        let slave = i2sClockPinMode == I2S_CLOCK_PIN_MODE_SPLIT && i2sClockMode == I2S_CLOCK_MODE_SLAVE
        let bck = slave ? i2sBckPinSlave : i2sBckPin
        return [bck, bck &+ 1]
    }

    // MARK: Restore substitutions

    /// Tell the user which functions the last restore (boot, preset load, bulk
    /// apply) moved off their stored pins or switched off because a pin was
    /// taken.  Off the main thread.
    func reportPinSubstitutions() {
        guard case .success(let data) = transport.get(VC.SYS.PIN_STATE, length: PinStateReply.size),
              let state = PinStateReply.decode(data), !state.substitutedFunctions.isEmpty else { return }
        let names = state.substitutedFunctions.map(Self.functionTitle)
        DeviceRefusal.notice.show("Pins changed on load: " + names.joined(separator: ", "),
                                  detail: "The device replaced these functions' pins, or switched them off, because a stored pin was taken or invalid. Check them in Settings.",
                                  seconds: 12)
    }

    static func functionTitle(_ fn: PinFunction) -> String {
        switch fn {
        case .output: return "outputs"
        case .pdm: return "subwoofer"
        case .i2sClock: return "I2S clocks"
        case .mck: return "MCK"
        case .adatTx: return "ADAT output"
        case .adatRx: return "ADAT input"
        case .spdifRx: return "S/PDIF inputs"
        case .i2sRx: return "I2S inputs"
        case .dacMute: return "DAC mute"
        case .uartCtrl: return "UART control"
        case .i2cCtrl: return "I2C control"
        case .controlSurface: return "control surfaces"
        }
    }
}

import Foundation
import Combine
import SwiftUI

extension DSPViewModel {

    // --- USB Commands ---

    func fetchAll() {
        guard fetchAllParams() else { return }

        fetchCore1Mode()

        // Fetch preset state
        fetchPresetDirectory()
        for slot in 0..<10 {
            fetchPresetName(slot: slot)
        }
        fetchPresetActive()
    }

    @discardableResult
    func fetchPlatform() -> String? {
        guard let data = usb.getControlRequest(request: REQ_GET_PLATFORM, value: 0, index: 2, length: 4) else { return nil }
        let platform = data[0]
        let name = platform == 1 ? "RP2350" : "RP2040"
        DispatchQueue.main.async {
            self.platformName = name
        }
        return name
    }

    func fetchStatus() {
        let numChannels = self.numChannels
        let responseSize = numChannels * 2 + 4  // peaks (2 bytes each) + cpu0 + cpu1 + clip_flags (2 bytes)

        guard let data = usb.getControlRequest(
            request: REQ_GET_STATUS, value: 9, index: 0,
            length: UInt16(responseSize)
        ), data.count >= responseSize else { return }

        var peaks = [Float](repeating: 0, count: numChannels)
        for i in 0..<numChannels {
            let raw = data.withUnsafeBytes { $0.load(fromByteOffset: i * 2, as: UInt16.self) }
            peaks[i] = Float(raw) / 32767.0
        }
        let cpu0 = Int(data[numChannels * 2])
        let cpu1 = Int(data[numChannels * 2 + 1])
        let clipFlags = data.withUnsafeBytes {
            $0.load(fromByteOffset: numChannels * 2 + 2, as: UInt16.self)
        }

        DispatchQueue.main.async {
            var s = self.meters.status
            var fullPeaks = Array(repeating: Float(0), count: 11)
            for i in 0..<numChannels { fullPeaks[i] = peaks[i] }
            s.peaks = fullPeaks
            s.cpu0 = cpu0
            s.cpu1 = cpu1
            s.clipFlags = clipFlags

            // Only update timestamp when genuinely new clip bits appear
            let newClips = clipFlags & ~s.clipLatched
            s.clipLatched |= clipFlags
            if newClips != 0 {
                s.clipTimestamp = Date()
            }

            // Auto-clear after 10 seconds of no new clips
            if let ts = s.clipTimestamp,
               Date().timeIntervalSince(ts) > 10.0,
               s.clipLatched != 0 {
                s.clipLatched = 0
                s.clipTimestamp = nil
                DispatchQueue.global(qos: .utility).async { self.clearClips() }
            }
            self.meters.status = s
        }
    }

    func clearClips() {
        _ = usb.getControlRequest(request: REQ_CLEAR_CLIPS, value: 0, index: 0, length: 2)
    }

    // MARK: - USB-only sends (no @Published update, for slider drag)

    func sendPreampToDevice(_ db: Float) {
        var val = (db * 10).rounded() / 10
        if val == -0.0 { val = 0.0 }
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_PREAMP, value: 0, index: 0, data: data)
    }

    func sendOutputGainToDevice(output: Int, db: Float) {
        var val = (db * 10).rounded() / 10
        if val == -0.0 { val = 0.0 }
        outputGainDB[output] = val
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_OUTPUT_GAIN, value: UInt16(output), index: 2, data: data)
    }

    func sendOutputDelayToDevice(output: Int, ms: Float) {
        var val = ms.rounded()
        if val == -0.0 { val = 0.0 }
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_OUTPUT_DELAY, value: UInt16(output), index: 2, data: data)
    }

    func setFilter(ch: Int, band: Int, p: FilterParams) {
        var p = p
        p.gain = (p.gain * 10).rounded() / 10
        if p.gain == -0.0 { p.gain = 0.0 }
        channelData[ch]?[band] = p

        let data = NSMutableData()
        var ch8 = UInt8(ch); data.append(&ch8, length: 1)
        var b8 = UInt8(band); data.append(&b8, length: 1)
        var t8 = UInt8(p.type.rawValue); data.append(&t8, length: 1)
        var res = UInt8(0); data.append(&res, length: 1)
        var f32 = p.freq; data.append(&f32, length: 4)
        var q32 = p.q; data.append(&q32, length: 4)
        var g32 = p.gain; data.append(&g32, length: 4)
        
        usb.sendControlRequest(request: REQ_SET_EQ_PARAM, value: 0, index: 0, data: data as Data)
        recomputeMagnitudes(for: ch)
    }
    
    func fetchFilter(ch: Int, band: Int) {
        func getVal<T>(_ param: Int, defaultVal: T) -> T {
            let wVal = UInt16((ch << 8) | (band << 4) | param)
            if let d = usb.getControlRequest(request: REQ_GET_EQ_PARAM, value: wVal, index: 0, length: 4) {
                return d.withUnsafeBytes { $0.load(as: T.self) }
            }
            return defaultVal
        }
        
        let typeRaw: UInt32 = getVal(0, defaultVal: 0)
        let freq: Float = getVal(1, defaultVal: 1000.0)
        let q: Float = getVal(2, defaultVal: 0.707)
        let gain: Float = getVal(3, defaultVal: 0.0)
        
        let newParams = FilterParams(
            type: FilterType(rawValue: Int(typeRaw)) ?? .flat,
            freq: freq,
            q: q,
            gain: gain
        )
        
        DispatchQueue.main.async {
            if self.channelData[ch]?[band] != newParams {
                self.channelData[ch]?[band] = newParams
            }
        }
    }
    
    func setDelay(ch: Int, ms: Float) {
        var val = ms.rounded()
        if val == -0.0 { val = 0.0 }
        self.channelDelays[ch] = val
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_DELAY, value: UInt16(ch), index: 0, data: data)
    }

    func fetchDelay(ch: Int) {
        if let d = usb.getControlRequest(request: REQ_GET_DELAY, value: UInt16(ch), index: 0, length: 4) {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs((self.channelDelays[ch] ?? 0) - val) > 0.01 {
                    self.channelDelays[ch] = val
                }
            }
        }
    }

    func setPreamp(_ db: Float) {
        var val = (db * 10).rounded() / 10
        if val == -0.0 { val = 0.0 }
        self.preampDB = val
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_PREAMP, value: 0, index: 0, data: data)
    }
    
    @discardableResult
    func fetchPreamp() -> Bool {
        if let d = usb.getControlRequest(request: REQ_GET_PREAMP, value: 0, index: 0, length: 4) {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.preampDB - val) > 0.1 {
                    self.preampDB = val
                }
            }
            return true
        } else {
            DispatchQueue.main.async { self.usb.isConnected = false }
            return false
        }
    }
    
    func setBypass(_ enabled: Bool) {
        self.bypass = enabled
        var val: UInt8 = enabled ? 1 : 0
        let data = Data(bytes: &val, count: 1)
        usb.sendControlRequest(request: REQ_SET_BYPASS, value: 0, index: 0, data: data)
        recomputeMagnitudes(for: 0)
        recomputeMagnitudes(for: 1)
    }
    
    @discardableResult
    func fetchBypass() -> Bool {
        if let d = usb.getControlRequest(request: REQ_GET_BYPASS, value: 0, index: 0, length: 1) {
            let val = d[0] != 0
            DispatchQueue.main.async {
                self.bypass = val
                self.recomputeMagnitudes(for: 0)
                self.recomputeMagnitudes(for: 1)
            }
            return true
        } else {
            DispatchQueue.main.async { self.usb.isConnected = false }
            return false
        }
    }
    
    func clearAllMaster() {
        let masterChannels = [Channel.masterLeft.rawValue, Channel.masterRight.rawValue]
        let defaultFilter = FilterParams(type: .flat, freq: 1000, q: 0.707, gain: 0)

        for ch in masterChannels {
            for b in 0..<10 {
                setFilter(ch: ch, band: b, p: defaultFilter)
            }
        }
        recomputeMagnitudes(for: 0)
        recomputeMagnitudes(for: 1)
    }

    // MARK: - Loudness Compensation

    func setLoudness(_ enabled: Bool) {
        self.loudnessEnabled = enabled
        var val: UInt8 = enabled ? 1 : 0
        let data = Data(bytes: &val, count: 1)
        usb.sendControlRequest(request: REQ_SET_LOUDNESS, value: 0, index: 0, data: data)
    }

    func fetchLoudness() {
        if let d = usb.getControlRequest(request: REQ_GET_LOUDNESS, value: 0, index: 0, length: 1) {
            let val = d[0] != 0
            DispatchQueue.main.async { self.loudnessEnabled = val }
        }
    }

    func setLoudnessRef(_ spl: Float) {
        self.loudnessRefSPL = spl
        var val = spl
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_LOUDNESS_REF, value: 0, index: 0, data: data)
    }

    func fetchLoudnessRef() {
        if let d = usb.getControlRequest(request: REQ_GET_LOUDNESS_REF, value: 0, index: 0, length: 4) {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.loudnessRefSPL - val) > 0.01 {
                    self.loudnessRefSPL = val
                }
            }
        }
    }

    func setLoudnessIntensity(_ pct: Float) {
        self.loudnessIntensity = pct
        var val = pct
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_LOUDNESS_INTENSITY, value: 0, index: 0, data: data)
    }

    func fetchLoudnessIntensity() {
        if let d = usb.getControlRequest(request: REQ_GET_LOUDNESS_INTENSITY, value: 0, index: 0, length: 4) {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.loudnessIntensity - val) > 0.01 {
                    self.loudnessIntensity = val
                }
            }
        }
    }

    // MARK: - Headphone Crossfeed

    func setCrossfeed(_ enabled: Bool) {
        self.crossfeedEnabled = enabled
        var val: UInt8 = enabled ? 1 : 0
        let data = Data(bytes: &val, count: 1)
        usb.sendControlRequest(request: REQ_SET_CROSSFEED, value: 0, index: 0, data: data)
    }

    func fetchCrossfeed() {
        if let d = usb.getControlRequest(request: REQ_GET_CROSSFEED, value: 0, index: 0, length: 1) {
            let val = d[0] != 0
            DispatchQueue.main.async { self.crossfeedEnabled = val }
        }
    }

    private static let presetValues: [(freq: Float, feed: Float)] = [
        (700, 4.5),   // Default
        (700, 6.0),   // Chu Moy
        (650, 9.5),   // Jan Meier
    ]

    func setCrossfeedPreset(_ preset: Int) {
        self.crossfeedPreset = preset
        var val = UInt8(preset)
        let data = Data(bytes: &val, count: 1)
        usb.sendControlRequest(request: REQ_SET_CROSSFEED_PRESET, value: 0, index: 0, data: data)
        // Apply known preset values locally so the graph updates immediately
        if preset < DSPViewModel.presetValues.count {
            self.crossfeedFreq = DSPViewModel.presetValues[preset].freq
            self.crossfeedFeed = DSPViewModel.presetValues[preset].feed
        }
    }

    func fetchCrossfeedPreset() {
        if let d = usb.getControlRequest(request: REQ_GET_CROSSFEED_PRESET, value: 0, index: 0, length: 1) {
            let val = Int(d[0])
            DispatchQueue.main.async { self.crossfeedPreset = val }
        }
    }

    func setCrossfeedFreq(_ freq: Float) {
        self.crossfeedFreq = freq
        var val = freq
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_CROSSFEED_FREQ, value: 0, index: 0, data: data)
    }

    func fetchCrossfeedFreq() {
        if let d = usb.getControlRequest(request: REQ_GET_CROSSFEED_FREQ, value: 0, index: 0, length: 4) {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.crossfeedFreq - val) > 0.01 {
                    self.crossfeedFreq = val
                }
            }
        }
    }

    func setCrossfeedFeed(_ feed: Float) {
        self.crossfeedFeed = feed
        var val = feed
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_CROSSFEED_FEED, value: 0, index: 0, data: data)
    }

    func fetchCrossfeedFeed() {
        if let d = usb.getControlRequest(request: REQ_GET_CROSSFEED_FEED, value: 0, index: 0, length: 4) {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.crossfeedFeed - val) > 0.01 {
                    self.crossfeedFeed = val
                }
            }
        }
    }

    func setCrossfeedITD(_ enabled: Bool) {
        self.crossfeedITD = enabled
        var val: UInt8 = enabled ? 1 : 0
        let data = Data(bytes: &val, count: 1)
        usb.sendControlRequest(request: REQ_SET_CROSSFEED_ITD, value: 0, index: 0, data: data)
    }

    func fetchCrossfeedITD() {
        if let d = usb.getControlRequest(request: REQ_GET_CROSSFEED_ITD, value: 0, index: 0, length: 1) {
            let val = d[0] != 0
            DispatchQueue.main.async { self.crossfeedITD = val }
        }
    }

    // MARK: - Matrix Mixer

    func setMatrixRoute(input: Int, output: Int, enabled: Bool, gain: Float, invert: Bool) {
        matrixRouting[input][output] = enabled
        matrixGain[input][output] = gain
        matrixInvert[input][output] = invert

        var packet = Data(count: 9)
        packet[0] = UInt8(input)
        packet[1] = UInt8(output)
        packet[2] = enabled ? 1 : 0
        packet[3] = invert ? 1 : 0
        var g = gain
        withUnsafeBytes(of: &g) { packet.replaceSubrange(4..<8, with: $0) }

        usb.sendControlRequest(request: REQ_SET_MATRIX_ROUTE, value: 0, index: 2, data: packet)
    }

    func fetchMatrixRoute(input: Int, output: Int) {
        let wValue = UInt16((input << 8) | output)
        guard let data = usb.getControlRequest(request: REQ_GET_MATRIX_ROUTE, value: wValue, index: 2, length: 9) else { return }

        let enabled = data[2] != 0
        let invert = data[3] != 0
        let gain = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Float.self) }

        DispatchQueue.main.async {
            self.matrixRouting[input][output] = enabled
            self.matrixGain[input][output] = gain
            self.matrixInvert[input][output] = invert
        }
    }

    // MARK: - Per-Output Enable

    func setOutputEnable(output: Int, enabled: Bool) {
        outputEnabled[output] = enabled
        if isOverviewMode {
            channelVisibility[output + 2] = enabled
        }
        var val: UInt8 = enabled ? 1 : 0
        let data = Data(bytes: &val, count: 1)
        usb.sendControlRequest(request: REQ_SET_OUTPUT_ENABLE, value: UInt16(output), index: 2, data: data)
    }

    func fetchOutputEnable(output: Int) {
        if let d = usb.getControlRequest(request: REQ_GET_OUTPUT_ENABLE, value: UInt16(output), index: 2, length: 1) {
            let val = d[0] != 0
            DispatchQueue.main.async { self.outputEnabled[output] = val }
        }
    }

    // MARK: - Per-Output Gain

    func setOutputGain(output: Int, db: Float) {
        var val = (db * 10).rounded() / 10
        if val == -0.0 { val = 0.0 }
        outputGainDB[output] = val
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_OUTPUT_GAIN, value: UInt16(output), index: 2, data: data)
    }

    func fetchOutputGainDB(output: Int) {
        if let d = usb.getControlRequest(request: REQ_GET_OUTPUT_GAIN, value: UInt16(output), index: 2, length: 4) {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.outputGainDB[output] - val) > 0.01 {
                    self.outputGainDB[output] = val
                }
            }
        }
    }

    // MARK: - Per-Output Mute

    func setOutputMute(output: Int, muted: Bool) {
        outputMuted[output] = muted
        var val: UInt8 = muted ? 1 : 0
        let data = Data(bytes: &val, count: 1)
        usb.sendControlRequest(request: REQ_SET_OUTPUT_MUTE, value: UInt16(output), index: 2, data: data)
    }

    func fetchOutputMute(output: Int) {
        if let d = usb.getControlRequest(request: REQ_GET_OUTPUT_MUTE, value: UInt16(output), index: 2, length: 1) {
            let val = d[0] != 0
            DispatchQueue.main.async {
                self.outputMuted[output] = val
            }
        }
    }

    // MARK: - Per-Output Delay

    func setOutputDelay(output: Int, ms: Float) {
        var val = ms.rounded()
        if val == -0.0 { val = 0.0 }
        outputDelayMS[output] = val
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_OUTPUT_DELAY, value: UInt16(output), index: 2, data: data)
    }

    func fetchOutputDelay(output: Int) {
        if let d = usb.getControlRequest(request: REQ_GET_OUTPUT_DELAY, value: UInt16(output), index: 2, length: 4) {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.outputDelayMS[output] - val) > 0.01 {
                    self.outputDelayMS[output] = val
                }
            }
        }
    }

    // MARK: - Core 1 Mode

    func fetchCore1Mode() {
        if let d = usb.getControlRequest(request: REQ_GET_CORE1_MODE, value: 0, index: 0, length: 1) {
            let val = Int(d[0])
            DispatchQueue.main.async { self.core1Mode = val }
        }
    }

    func checkCore1Conflict(output: Int) -> Bool {
        if let d = usb.getControlRequest(request: REQ_GET_CORE1_CONFLICT, value: UInt16(output), index: 0, length: 1) {
            return d[0] != 0
        }
        return false
    }

    /// Disable all EQ worker outputs, then enable PDM, confirm via read-back.
    func switchToPDM() {
        for i in eqWorkerRange {
            setOutputEnable(output: i, enabled: false)
        }
        setOutputEnable(output: pdmOutputIndex, enabled: true)
        // Read back to confirm
        for i in eqWorkerRange {
            fetchOutputEnable(output: i)
        }
        fetchOutputEnable(output: pdmOutputIndex)
        fetchCore1Mode()
    }

    /// Disable PDM, then enable the requested output, confirm via read-back.
    func switchFromPDM(enabling output: Int) {
        setOutputEnable(output: pdmOutputIndex, enabled: false)
        setOutputEnable(output: output, enabled: true)
        // Read back to confirm
        fetchOutputEnable(output: pdmOutputIndex)
        fetchOutputEnable(output: output)
        fetchCore1Mode()
    }

    // MARK: - Pin Configuration

    func fetchOutputPin(output: Int) {
        if let d = usb.getControlRequest(request: REQ_GET_OUTPUT_PIN, value: UInt16(output), index: 2, length: 1) {
            let pin = d[0]
            DispatchQueue.main.async {
                self.outputPins[output] = pin
            }
        }
    }

    /// Sets the GPIO pin for a physical output. Returns the firmware status code.
    /// Single IN transfer: wValue = (new_pin << 8) | output_index
    @discardableResult
    func setOutputPin(output: Int, pin: UInt8) -> UInt8 {
        let wValue = (UInt16(pin) << 8) | UInt16(output)
        if let d = usb.getControlRequest(request: REQ_SET_OUTPUT_PIN, value: wValue, index: 2, length: 1) {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async {
                    self.outputPins[output] = pin
                }
            }
            return status
        }
        return 0xFF
    }

    // MARK: - I2S Configuration

    /// Switch an output slot between S/PDIF (0) and I2S (1). Returns firmware status code.
    @discardableResult
    func setOutputSlotType(slot: Int, type: UInt8) -> UInt8 {
        let wValue = (UInt16(type) << 8) | UInt16(slot)
        if let d = usb.getControlRequest(request: REQ_SET_OUTPUT_TYPE, value: wValue, index: 2, length: 1) {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async { self.outputSlotTypes[slot] = type }
            }
            return status
        }
        return 0xFF
    }

    func fetchOutputSlotType(slot: Int) {
        if let d = usb.getControlRequest(request: REQ_GET_OUTPUT_TYPE, value: UInt16(slot), index: 2, length: 1) {
            let type = d[0]
            DispatchQueue.main.async { self.outputSlotTypes[slot] = type }
        }
    }

    /// Set BCK GPIO pin. Requires all slots to be S/PDIF. LRCLK = BCK + 1.
    @discardableResult
    func setI2SBckPin(_ pin: UInt8) -> UInt8 {
        if let d = usb.getControlRequest(request: REQ_SET_I2S_BCK_PIN, value: UInt16(pin), index: 2, length: 1) {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async { self.i2sBckPin = pin }
            }
            return status
        }
        return 0xFF
    }

    func fetchI2SBckPin() {
        if let d = usb.getControlRequest(request: REQ_GET_I2S_BCK_PIN, value: 0, index: 2, length: 1) {
            DispatchQueue.main.async { self.i2sBckPin = d[0] }
        }
    }

    /// Enable or disable the master clock output.
    @discardableResult
    func setMckEnable(_ enabled: Bool) -> UInt8 {
        if let d = usb.getControlRequest(request: REQ_SET_MCK_ENABLE, value: enabled ? 1 : 0, index: 2, length: 1) {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async { self.mckEnabled = enabled }
            }
            return status
        }
        return 0xFF
    }

    func fetchMckEnable() {
        if let d = usb.getControlRequest(request: REQ_GET_MCK_ENABLE, value: 0, index: 2, length: 1) {
            let val = d[0] != 0
            DispatchQueue.main.async { self.mckEnabled = val }
        }
    }

    /// Set MCK GPIO pin. MCK must be disabled first.
    @discardableResult
    func setMckPin(_ pin: UInt8) -> UInt8 {
        if let d = usb.getControlRequest(request: REQ_SET_MCK_PIN, value: UInt16(pin), index: 2, length: 1) {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async { self.mckPin = pin }
            }
            return status
        }
        return 0xFF
    }

    func fetchMckPin() {
        if let d = usb.getControlRequest(request: REQ_GET_MCK_PIN, value: 0, index: 2, length: 1) {
            DispatchQueue.main.async { self.mckPin = d[0] }
        }
    }

    /// Set MCK frequency multiplier (128 or 256).
    @discardableResult
    func setMckMultiplier(_ multiplier: Int) -> UInt8 {
        if let d = usb.getControlRequest(request: REQ_SET_MCK_MULTIPLIER, value: UInt16(multiplier & 0xFF), index: 2, length: 1) {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async { self.mckMultiplier = multiplier }
            }
            return status
        }
        return 0xFF
    }

    func fetchMckMultiplier() {
        if let d = usb.getControlRequest(request: REQ_GET_MCK_MULTIPLIER, value: 0, index: 2, length: 1) {
            let raw = d[0]
            let value = raw == 0 ? 256 : Int(raw)  // 256 wraps to 0x00 in uint8
            DispatchQueue.main.async { self.mckMultiplier = value }
        }
    }

    // MARK: - Bulk Parameter Transfer

    /// Fetches all DSP parameters in a single 2480-byte USB transfer.
    /// Parses the WireBulkParams structure and updates all published properties.
    /// Returns true if successful, false if the device is not connected.
    @discardableResult
    func fetchAllParams() -> Bool {
        guard let data = usb.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0, index: 2, length: BULK_PARAMS_SIZE),
              data.count >= 2832 else {  // Accept V2 (2832) or V3 (2848) responses
            DispatchQueue.main.async { self.usb.isConnected = false }
            return false
        }

        // --- Header (offset 0, 16 bytes) ---
        let platformId = data[1]
        let numCh = Int(data[2])
        let numOutCh = Int(data[3])
        let platform = platformId == 1 ? "RP2350" : "RP2040"

        // --- Global (offset 16, 16 bytes) ---
        let preamp: Float = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: Float.self) }
        let bypassVal = data[20] != 0
        let loudnessEn = data[21] != 0
        let loudnessRef: Float = data.withUnsafeBytes { $0.load(fromByteOffset: 24, as: Float.self) }
        let loudnessInt: Float = data.withUnsafeBytes { $0.load(fromByteOffset: 28, as: Float.self) }

        // --- Crossfeed (offset 32, 16 bytes) ---
        let cfEnabled = data[32] != 0
        let cfPreset = Int(data[33])
        let cfITD = data[34] != 0
        let cfFreq: Float = data.withUnsafeBytes { $0.load(fromByteOffset: 36, as: Float.self) }
        let cfFeed: Float = data.withUnsafeBytes { $0.load(fromByteOffset: 40, as: Float.self) }

        // --- Delays (offset 64, 44 bytes) ---
        var delays = [Int: Float]()
        for i in 0..<numCh {
            delays[i] = data.withUnsafeBytes { $0.load(fromByteOffset: 64 + i * 4, as: Float.self) }
        }

        // --- Matrix crosspoints (offset 108, 144 bytes = 2 inputs × 9 outputs × 8 bytes) ---
        var routing = Array(repeating: Array(repeating: false, count: 9), count: 2)
        var mxGain = Array(repeating: Array(repeating: Float(0.0), count: 9), count: 2)
        var mxInvert = Array(repeating: Array(repeating: false, count: 9), count: 2)
        for input in 0..<2 {
            for output in 0..<numOutCh {
                let base = 108 + (input * 9 + output) * 8
                routing[input][output] = data[base] != 0
                mxInvert[input][output] = data[base + 1] != 0
                mxGain[input][output] = data.withUnsafeBytes { $0.load(fromByteOffset: base + 4, as: Float.self) }
            }
        }

        // --- Matrix outputs (offset 252, 108 bytes = 9 outputs × 12 bytes) ---
        var outEnabled = Array(repeating: false, count: 9)
        var outMuted = Array(repeating: false, count: 9)
        var outGain = Array(repeating: Float(0.0), count: 9)
        var outDelay = Array(repeating: Float(0.0), count: 9)
        for output in 0..<numOutCh {
            let base = 252 + output * 12
            outEnabled[output] = data[base] != 0
            outMuted[output] = data[base + 1] != 0
            outGain[output] = data.withUnsafeBytes { $0.load(fromByteOffset: base + 4, as: Float.self) }
            outDelay[output] = data.withUnsafeBytes { $0.load(fromByteOffset: base + 8, as: Float.self) }
        }

        // --- Pin config (offset 360, 8 bytes) ---
        let numPins = min(Int(data[360]), 5)
        var pins: [UInt8] = [6, 7, 8, 9, 10]  // defaults
        for i in 0..<numPins {
            pins[i] = data[361 + i]
        }

        // --- EQ bands (offset 368, 2112 bytes = 11 channels × 12 bands × 16 bytes) ---
        let bandsInFirmware = 12
        let bandsInApp = 10
        var channelFilters = [Int: [FilterParams]]()
        for ch in 0..<numCh {
            var bands = [FilterParams]()
            bands.reserveCapacity(bandsInApp)
            for band in 0..<bandsInApp {
                let base = 368 + (ch * bandsInFirmware + band) * 16
                let type: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: base, as: UInt32.self) }
                let freq: Float = data.withUnsafeBytes { $0.load(fromByteOffset: base + 4, as: Float.self) }
                let q: Float = data.withUnsafeBytes { $0.load(fromByteOffset: base + 8, as: Float.self) }
                let gain: Float = data.withUnsafeBytes { $0.load(fromByteOffset: base + 12, as: Float.self) }
                bands.append(FilterParams(
                    type: FilterType(rawValue: Int(type)) ?? .flat,
                    freq: freq,
                    q: q,
                    gain: gain
                ))
            }
            channelFilters[ch] = bands
        }

        // --- Channel names (offset 2480, 352 bytes = 11 channels × 32 bytes) ---
        var names = [String](repeating: "", count: 11)
        for ch in 0..<numCh {
            let base = 2480 + ch * 32
            let end = min(base + 32, data.count)
            let slice = data[base..<end]
            if let nulIdx = slice.firstIndex(of: 0) {
                names[ch] = String(data: data[base..<nulIdx], encoding: .ascii) ?? ""
            } else {
                names[ch] = String(data: slice, encoding: .ascii) ?? ""
            }
        }

        // --- I2S Config (offset 2832, 16 bytes) --- V3 firmware only
        var slotTypes: [UInt8] = [0, 0, 0, 0]
        var bckPin: UInt8 = 14
        var mckPinVal: UInt8 = 13
        var mckEn = false
        var mckMult = 128

        if data.count >= 2848 {
            for i in 0..<4 { slotTypes[i] = data[2832 + i] }
            bckPin = data[2836]
            mckPinVal = data[2837]
            mckEn = data[2838] != 0
            let rawMult = data[2839]
            mckMult = rawMult == 0 ? 256 : Int(rawMult)
        }

        // --- Apply all parsed values on main thread ---
        DispatchQueue.main.async {
            self.platformName = platform

            self.preampDB = preamp
            self.bypass = bypassVal
            self.loudnessEnabled = loudnessEn
            self.loudnessRefSPL = loudnessRef
            self.loudnessIntensity = loudnessInt

            self.crossfeedEnabled = cfEnabled
            self.crossfeedPreset = cfPreset
            self.crossfeedITD = cfITD
            self.crossfeedFreq = cfFreq
            self.crossfeedFeed = cfFeed

            self.channelDelays = delays

            self.matrixRouting = routing
            self.matrixGain = mxGain
            self.matrixInvert = mxInvert

            self.outputEnabled = outEnabled
            self.outputMuted = outMuted
            self.outputGainDB = outGain
            self.outputDelayMS = outDelay

            self.outputPins = pins

            self.outputSlotTypes = slotTypes
            self.i2sBckPin = bckPin
            self.mckPin = mckPinVal
            self.mckEnabled = mckEn
            self.mckMultiplier = mckMult

            self.channelData = channelFilters
            self.channelNames = names

            // Refresh channel visibility now that outputEnabled is populated
            if self.isOverviewMode {
                for outputIdx in 0..<9 {
                    self.channelVisibility[outputIdx + 2] = outEnabled[outputIdx]
                }
            }

            self.recomputeAllMagnitudes()
            self.updateSavedSnapshot()
        }

        return true
    }

    // MARK: - Preset Commands

    @discardableResult
    func fetchPresetDirectory() -> UInt16 {
        guard let data = usb.getControlRequest(request: REQ_PRESET_GET_DIR, value: 0, index: 2, length: 6),
              data.count >= 6 else { return 0 }
        let occupied = data.withUnsafeBytes { $0.load(as: UInt16.self) }
        let startupMode = Int(data[2])
        let defaultSlot = Int(data[3])
        let lastActive = data[4]
        let includePins = data[5] != 0
        DispatchQueue.main.async {
            self.presetOccupied = occupied
            self.presetStartupMode = startupMode
            self.presetDefaultSlot = defaultSlot
            self.activePresetSlot = Int(lastActive)
            self.presetIncludePins = includePins
        }
        return occupied
    }

    func fetchPresetName(slot: Int) {
        guard let data = usb.getControlRequest(request: REQ_PRESET_GET_NAME, value: UInt16(slot), index: 2, length: 32) else { return }
        let name: String
        if let nulIndex = data.firstIndex(of: 0) {
            name = String(data: data[0..<nulIndex], encoding: .ascii) ?? ""
        } else {
            name = String(data: data, encoding: .ascii) ?? ""
        }
        DispatchQueue.main.async {
            self.presetNames[slot] = name
        }
    }

    func fetchPresetActive() {
        guard let data = usb.getControlRequest(request: REQ_PRESET_GET_ACTIVE, value: 0, index: 2, length: 1) else { return }
        DispatchQueue.main.async {
            self.activePresetSlot = Int(data[0])
        }
    }

    @discardableResult
    func savePreset(slot: Int) -> UInt8 {
        guard let data = usb.getControlRequest(request: REQ_PRESET_SAVE, value: UInt16(slot), index: 2, length: 1) else { return 0xFF }
        let status = data[0]
        if status == PRESET_OK {
            DispatchQueue.main.async {
                self.activePresetSlot = slot
                self.presetOccupied |= UInt16(1 << slot)
                self.updateSavedSnapshot()
            }
        }
        return status
    }

    @discardableResult
    func loadPreset(slot: Int) -> UInt8 {
        guard let data = usb.getControlRequest(request: REQ_PRESET_LOAD, value: UInt16(slot), index: 2, length: 1) else { return 0xFF }
        let status = data[0]
        if status == PRESET_OK {
            DispatchQueue.main.async {
                self.activePresetSlot = slot
            }
            // Wait for mute period then re-sync DSP parameters
            Thread.sleep(forTimeInterval: 0.01)
            fetchAllParams()
        }
        return status
    }

    @discardableResult
    func deletePreset(slot: Int) -> UInt8 {
        guard let data = usb.getControlRequest(request: REQ_PRESET_DELETE, value: UInt16(slot), index: 2, length: 1) else { return 0xFF }
        let status = data[0]
        if status == PRESET_OK {
            DispatchQueue.main.async {
                self.presetOccupied &= ~UInt16(1 << slot)
            }
        }
        return status
    }

    func setPresetName(slot: Int, name: String) {
        var nameData = Data(name.prefix(31).utf8)
        nameData.append(0) // NUL terminator
        usb.sendControlRequest(request: REQ_PRESET_SET_NAME, value: UInt16(slot), index: 2, data: nameData)
        DispatchQueue.main.async {
            self.presetNames[slot] = String(name.prefix(31))
        }
    }

    func setPresetStartup(mode: Int, defaultSlot: Int) {
        let data = Data([UInt8(mode), UInt8(defaultSlot)])
        usb.sendControlRequest(request: REQ_PRESET_SET_STARTUP, value: 0, index: 2, data: data)
    }

    func fetchPresetStartup() {
        guard let data = usb.getControlRequest(request: REQ_PRESET_GET_STARTUP, value: 0, index: 2, length: 3),
              data.count >= 3 else { return }
        DispatchQueue.main.async {
            self.presetStartupMode = Int(data[0])
            self.presetDefaultSlot = Int(data[1])
            self.activePresetSlot = Int(data[2])
        }
    }

    func setPresetIncludePins(_ include: Bool) {
        let data = Data([include ? 1 : 0])
        usb.sendControlRequest(request: REQ_PRESET_SET_INCLUDE_PINS, value: 0, index: 2, data: data)
    }

    func fetchPresetIncludePins() {
        guard let data = usb.getControlRequest(request: REQ_PRESET_GET_INCLUDE_PINS, value: 0, index: 2, length: 1) else { return }
        let val = data[0] != 0
        DispatchQueue.main.async {
            self.presetIncludePins = val
        }
    }

    // MARK: - Channel Names

    func setChannelName(channel: Int, name: String) {
        var nameData = Data(count: 32)  // Always send full 32-byte buffer, zero-padded
        let utf8 = Data(name.prefix(31).utf8)
        nameData.replaceSubrange(0..<utf8.count, with: utf8)
        usb.sendControlRequest(request: REQ_SET_CHANNEL_NAME, value: UInt16(channel), index: 2, data: nameData)
        DispatchQueue.main.async {
            self.channelNames[channel] = String(name.prefix(31))
        }
    }

    func fetchChannelName(channel: Int) {
        guard let data = usb.getControlRequest(request: REQ_GET_CHANNEL_NAME, value: UInt16(channel), index: 2, length: 32) else { return }
        let name: String
        if let nulIndex = data.firstIndex(of: 0) {
            name = String(data: data[0..<nulIndex], encoding: .ascii) ?? ""
        } else {
            name = String(data: data, encoding: .ascii) ?? ""
        }
        DispatchQueue.main.async {
            self.channelNames[channel] = name
        }
    }

    // MARK: - Flash Storage Commands

    func saveParams() -> UInt8 {
        guard isDeviceConnected else { return FLASH_ERR_WRITE }
        if let data = usb.getControlRequest(request: REQ_SAVE_PARAMS, value: 0, index: 0, length: 1) {
            return data[0]
        }
        return FLASH_ERR_WRITE
    }

    func loadParams() -> UInt8 {
        guard isDeviceConnected else { return FLASH_ERR_WRITE }
        if let data = usb.getControlRequest(request: REQ_LOAD_PARAMS, value: 0, index: 0, length: 1) {
            let result = data[0]
            if result == FLASH_OK {
                // Re-fetch all params to update UI
                fetchAll()
            }
            return result
        }
        return FLASH_ERR_WRITE
    }

    func factoryReset() -> UInt8 {
        guard isDeviceConnected else { return FLASH_ERR_WRITE }
        if let data = usb.getControlRequest(request: REQ_FACTORY_RESET, value: 0, index: 0, length: 1) {
            let result = data[0]
            if result == FLASH_OK {
                // Re-fetch all params to update UI
                fetchAll()
            }
            return result
        }
        return FLASH_ERR_WRITE
    }
}

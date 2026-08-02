import Foundation
import Combine
import SwiftUI

extension DSPViewModel {

    // --- USB Commands ---

    /// Full parameter refresh.  Pass `afterConnect: true` on the connect path,
    /// where the device may not be ready to answer yet and the reads must be
    /// retried instead of treated as a dead link (see `waitForDeviceReady`).
    /// Blocking, so `afterConnect` callers must be off the main thread.
    func fetchAll(afterConnect: Bool = false) {
        // Scope this refresh to the device that is open right now. If a
        // device switch lands mid-fetch, later reads would return the NEW
        // device's data and publish a mix of both devices' state - bail out
        // instead; the switch itself triggers a fresh fetchAll that does the
        // full refresh.
        let generation = usb.generation

        // Fetch platform/version first so capability gates (notch filter,
        // per-band bypass, etc.) are populated before the UI reads them.
        // It doubles as the readiness probe on the connect path: it is the
        // cheapest interface-recipient read, i.e. the same path the bulk
        // transfer below uses.
        if afterConnect {
            guard waitForDeviceReady(generation: generation) else {
                // Never answered - the link really is dead.
                DispatchQueue.main.async { self.usb.isConnected = false }
                return
            }
        } else {
            _ = fetchPlatform()
        }

        let gotParams = afterConnect
            ? fetchAllParamsRetrying(generation: generation)
            : fetchAllParams()
        guard gotParams else { return }
        guard usb.generation == generation else { return }

        fetchInputSource()
        fetchCore1Mode()
        fetchSampleRate()
        fetchUserVolume()
        fetchLgSoundSyncEnabled()
        fetchDacHwMuteConfig()
        fetchControlInterfaces()
        fetchControlSurfaces()
        guard usb.generation == generation else { return }

        fetchSiggen()
        fetchAdatConfig()
        fetchAdatInputConfig()
        guard usb.generation == generation else { return }

        // Fetch preset state
        let occupied = fetchPresetDirectory()
        for slot in 0..<10 {
            if (occupied & UInt16(1 << slot)) != 0 {
                fetchPresetName(slot: slot)
            } else {
                DispatchQueue.main.async {
                    self.presetNames[slot] = ""
                }
            }
        }
        fetchPresetActive()
        guard usb.generation == generation else { return }

        // All fetches above have enqueued their main-thread state updates, so
        // this runs after the published values reflect the connected device.
        // Re-seeds the Settings global draft (no-op if the user has staged
        // edits) - matters after a device switch, where the draft was reset
        // from the previous device's values.
        DispatchQueue.main.async {
            SettingsSaveCoordinator.shared.refreshGlobalDraftIfClean()
        }
    }

    /// Polls a cheap vendor read until the device answers.
    ///
    /// A freshly enumerated device is not immediately usable: macOS publishes
    /// the IOKit service before the configuration is set, so interface-recipient
    /// control requests can fail for a while, and a just-flashed unit is still
    /// initialising its stored parameters on top of that.  Every read in the
    /// connect path is one-shot - `fetchAllParams` clears `isConnected` when it
    /// fails and nothing retries afterwards - so wait for the device to prove
    /// it is answering first.
    ///
    /// Returns false only if the device never responded, or if the connection
    /// changed underneath us (in which case the caller must bail out silently).
    private func waitForDeviceReady(generation: UInt64) -> Bool {
        let backoff: [TimeInterval] = [0, 0.1, 0.2, 0.4, 0.8, 1.0]
        for delay in backoff {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            guard usb.generation == generation else { return false }
            if fetchPlatform() != nil { return true }
        }
        return false
    }

    /// `fetchAllParams` for the connect path: retries the bulk transfer a few
    /// times before letting it mark the device disconnected.  The device can
    /// answer the small readiness probe and still stall on the ~6 KB bulk read
    /// while it finishes booting.
    private func fetchAllParamsRetrying(generation: UInt64) -> Bool {
        let backoff: [TimeInterval] = [0.15, 0.3, 0.6]
        for delay in backoff {
            // A short/wrong-version payload also returns false here, but the
            // device is alive and the firmware simply incompatible; retrying
            // costs a few reads and the final call records the version.
            if fetchAllParams(markDisconnectedOnFailure: false) { return true }
            guard usb.generation == generation else { return false }
            Thread.sleep(forTimeInterval: delay)
            guard usb.generation == generation else { return false }
        }
        return fetchAllParams()
    }

    @discardableResult
    func fetchPlatform() -> String? {
        guard let data = usb.getControlRequest(request: REQ_GET_PLATFORM, value: 0, index: 2, length: 4) else { return nil }
        let platform = data[0]
        let major = Int(data[1])
        let minor = Int(data[2] >> 4)
        let patch = Int(data[2] & 0x0F)
        let name: String
        switch platform {
        case 1:  name = "RP2350"
        case 2:  name = "STM32H723"
        default: name = "RP2040"
        }
        DispatchQueue.main.async {
            self.platformName = name
            self.firmwareVersion = (major: major, minor: minor, patch: patch)
        }
        return name
    }

    func fetchStatus() {
        let numChannels = self.numChannels
        // V16 combined status (wValue=9): peaks[numCh] u16 + cpu0 + cpu1 +
        // clip_flags (u32) + active_input_channels (u8).
        let responseSize = numChannels * 2 + 2 + 4 + 1

        guard let data = usb.getControlRequest(
            request: REQ_GET_STATUS, value: 9, index: 0,
            length: UInt16(responseSize)
        ), data.count >= responseSize else { return }

        var peaks = [Float](repeating: 0, count: numChannels)
        for i in 0..<numChannels {
            let raw = data.withUnsafeBytes { $0.load(fromByteOffset: i * 2, as: UInt16.self) }
            peaks[i] = Float(raw) / 32767.0
        }
        let off = numChannels * 2
        let cpu0 = Int(data[off])
        let cpu1 = Int(data[off + 1])
        let clipFlags = data.withUnsafeBytes {
            $0.load(fromByteOffset: off + 2, as: UInt32.self)
        }
        // Live active input count (2/4/6/8); follows the host's USB audio format.
        let activeInputs = max(BASE_MATRIX_INPUTS, Int(data[off + 6]))

        DispatchQueue.main.async {
            if self.activeInputChannels != activeInputs {
                self.activeInputChannels = activeInputs
            }
            var s = self.meters.status
            var fullPeaks = Array(repeating: Float(0), count: WIRE_MAX_CHANNELS)
            for i in 0..<min(numChannels, WIRE_MAX_CHANNELS) { fullPeaks[i] = peaks[i] }
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

        // Poll sample rate at a lower cadence than meter traffic to keep
        // hardware UI constraints current (e.g., MCK multiplier gating).
        struct SampleRatePollState { static var decimator = 0 }
        SampleRatePollState.decimator = (SampleRatePollState.decimator + 1) & 0x0F
        if SampleRatePollState.decimator == 0 {
            fetchSampleRate()
        }
    }

    func fetchSampleRate() {
        guard let data = usb.getControlRequest(request: REQ_GET_STATUS, value: 15, index: 0, length: 4),
              data.count >= 4 else { return }
        let rate = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        DispatchQueue.main.async {
            self.sampleRateHz = rate
            // Keep UI consistent with firmware/runtime policy:
            // 256x MCK is not available at 96 kHz.
            if rate >= 96000, self.mckMultiplier == 256 {
                self.mckMultiplier = 128
            }
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

    func sendPreampChannelToDevice(channel: Int, db: Float) {
        var val = (db * 10).rounded() / 10
        if val == -0.0 { val = 0.0 }
        let data = Data(bytes: &val, count: 4)
        // Link couples only the stereo USB L/R pair (inputs 0/1) via two
        // per-channel writes; never the legacy all-channel REQ_SET_PREAMP, which
        // would clobber the 8-channel input trims (inputs 2-7).
        if preampLinked && channel < BASE_MATRIX_INPUTS {
            usb.sendControlRequest(request: REQ_SET_PREAMP_CH, value: 0, index: 0, data: data)
            usb.sendControlRequest(request: REQ_SET_PREAMP_CH, value: 1, index: 0, data: data)
        } else {
            usb.sendControlRequest(request: REQ_SET_PREAMP_CH, value: UInt16(channel), index: 0, data: data)
        }
    }

    func sendMasterVolumeToDevice(_ db: Float) {
        var val = Self.roundMasterVolume(db)
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_MASTER_VOLUME, value: 0, index: 0, data: data)
    }

    private static func roundMasterVolume(_ db: Float) -> Float {
        if db <= -128 { return -128 }
        if db >= 0 { return 0 }
        let rounded: Float
        if db > -10 {
            rounded = (db * 10).rounded() / 10
        } else if db > -40 {
            rounded = (db * 2).rounded() / 2
        } else {
            rounded = db.rounded()
        }
        return rounded == -0.0 ? 0.0 : rounded
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

        // EqParamPacket layout: [ch, band, type, bypass, freq(4), q(4), gain(4)] = 16 bytes.
        // Per band_bypass_spec §5: write exactly 0 or 1 — never 0xFF.
        // For the Linkwitz Transform (type 11) append the 2-byte `qp` sidecar
        // (Qp x 512), making an 18-byte payload; the firmware then latches the
        // target Q.  The 16-byte form preserves the stored qp, so we always send
        // the long form for LT bands.  See peq_filters.md §4.1.
        let data = NSMutableData()
        var ch8 = UInt8(ch); data.append(&ch8, length: 1)
        var b8 = UInt8(band); data.append(&b8, length: 1)
        var t8 = UInt8(p.type.rawValue); data.append(&t8, length: 1)
        var bp = UInt8(p.bypass ? 1 : 0); data.append(&bp, length: 1)
        var f32 = p.freq; data.append(&f32, length: 4)
        var q32 = p.q; data.append(&q32, length: 4)
        var g32 = p.gain; data.append(&g32, length: 4)
        if p.type == .linkwitzTransform {
            var qp16 = p.qpEncoded; data.append(&qp16, length: 2)
        }

        usb.sendControlRequest(request: REQ_SET_EQ_PARAM, value: 0, index: 0, data: data as Data)
        recomputeMagnitudes(for: ch)
    }
    
    func fetchFilter(ch: Int, band: Int) {
        // REQ_GET_EQ_PARAM wValue: bits[15:8]=channel, bits[7:3]=band (5 bits,
        // 0..31), bits[2:0]=param (0=type, 1=freq, 2=Q, 3=gain, 4=bypass,
        // 5=qp).  The band field is 5 bits (not the original 4) so crossover
        // bands at 20..23 stay addressable after the reserved PEQ gap widened
        // to 10..19.
        func getVal<T>(_ param: Int, defaultVal: T) -> T {
            let wVal = UInt16((ch << 8) | (band << 3) | param)
            if let d = usb.getControlRequest(request: REQ_GET_EQ_PARAM, value: wVal, index: 0, length: 4) {
                return d.withUnsafeBytes { $0.load(as: T.self) }
            }
            return defaultVal
        }
        
        let typeRaw: UInt32 = getVal(0, defaultVal: 0)
        let freq: Float = getVal(1, defaultVal: 1000.0)
        let q: Float = getVal(2, defaultVal: 0.707)
        let gain: Float = getVal(3, defaultVal: 0.0)
        // param=4 returns bypass (firmware 1.1.4+); pre-1.1.4 STALLs and we
        // fall back to 0/active.  Spec §5: only the low byte is meaningful.
        let bypassRaw: UInt32 = getVal(4, defaultVal: 0)
        let bypass = (bypassRaw & 0xFF) == 1

        let type = FilterType(rawValue: Int(typeRaw)) ?? .flat
        // param=5 returns qp_x512 in the low 16 bits (0 for non-LT bands and on
        // firmware that predates it, decoding to the 0.707 default).  Only read
        // it for LT bands to avoid an extra transfer on every other type.
        var qp = FilterParams.defaultQp
        if type == .linkwitzTransform {
            let qpRaw: UInt32 = getVal(5, defaultVal: 0)
            qp = FilterParams.decodeQp(UInt16(qpRaw & 0xFFFF))
        }

        var newParams = FilterParams(
            type: type,
            freq: freq,
            q: q,
            gain: gain,
            bypass: bypass
        )
        newParams.qp = qp

        DispatchQueue.main.async {
            if self.channelData[ch]?[band] != newParams {
                self.channelData[ch]?[band] = newParams
            }
        }
    }

    /// Toggle a single band's bypass flag without touching freq/Q/gain.
    /// Cheaper than REQ_SET_EQ_PARAM when the user just clicks the bypass
    /// checkbox, and avoids racing with an in-flight parameter edit.
    func setBandBypass(ch: Int, band: Int, bypass: Bool) {
        // Update local cache immediately so the UI is responsive; the
        // notification echo from the firmware will re-confirm.
        if var bands = channelData[ch], band < bands.count {
            bands[band].bypass = bypass
            channelData[ch] = bands
            recomputeMagnitudes(for: ch)
        }

        let wValue = UInt16((ch << 8) | band)
        let payload = Data([bypass ? 1 : 0])
        usb.sendControlRequest(request: REQ_SET_BAND_BYPASS, value: wValue, index: 0, data: payload)
    }

    /// Returns the current bypass state for a single band, or nil if the
    /// firmware STALLs (pre-1.1.4).  Always normalized to true/false.
    func fetchBandBypass(ch: Int, band: Int) -> Bool? {
        let wValue = UInt16((ch << 8) | band)
        guard let data = usb.getControlRequest(request: REQ_GET_BAND_BYPASS, value: wValue, index: 0, length: 1),
              data.count >= 1 else {
            return nil
        }
        return data[0] == 1
    }

    // MARK: - Crossover Bands
    //
    // Crossover uses the existing EQ-band addressing (REQ_SET/GET_EQ_PARAM)
    // with band indices 20..23 reserved for the four crossover bands per
    // output channel.  See crossover_filters_spec.md §3.  The wValue layout
    // for SET is unused; the recipe is in the 16-byte payload.

    /// Set a single crossover band on an output channel.  `localBand` is 0..3;
    /// the wire band index is 20+localBand.  No-op for master channels (the
    /// firmware would reject them anyway) and for invalid band indices.
    func setCrossoverBand(ch: Int, localBand: Int, p: FilterParams) {
        guard ch >= chOut1,
              localBand >= 0,
              localBand < DSPViewModel.crossoverBandsPerChannel else { return }

        let wireBand = DSPViewModel.crossoverWireBand(localBand)
        var p = p
        // Crossover types ignore Q / gain in firmware; we keep the values for
        // round-trip but normalize so saved snapshots compare cleanly.
        p.gain = 0
        if p.q <= 0 { p.q = 0.707 }
        if var bands = xoverData[ch], localBand < bands.count {
            bands[localBand] = p
            xoverData[ch] = bands
            recomputeMagnitudes(for: ch)
        }

        // EqParamPacket: [ch, band, type, bypass, freq(4), q(4), gain(4)] = 16
        let data = NSMutableData()
        var ch8 = UInt8(ch); data.append(&ch8, length: 1)
        var b8 = UInt8(wireBand); data.append(&b8, length: 1)
        var t8 = UInt8(p.type.rawValue); data.append(&t8, length: 1)
        var bp = UInt8(p.bypass ? 1 : 0); data.append(&bp, length: 1)
        var f32 = p.freq; data.append(&f32, length: 4)
        var q32 = p.q;    data.append(&q32, length: 4)
        var g32 = p.gain; data.append(&g32, length: 4)

        usb.sendControlRequest(request: REQ_SET_EQ_PARAM, value: 0, index: 0, data: data as Data)
    }

    /// Toggle a single crossover band's bypass flag.  Uses REQ_SET_BAND_BYPASS
    /// (0xD8) — same opcode as PEQ.  No-op for master channels.
    func setCrossoverBandBypass(ch: Int, localBand: Int, bypass: Bool) {
        guard ch >= chOut1,
              localBand >= 0,
              localBand < DSPViewModel.crossoverBandsPerChannel else { return }
        let wireBand = DSPViewModel.crossoverWireBand(localBand)
        if var bands = xoverData[ch], localBand < bands.count {
            bands[localBand].bypass = bypass
            xoverData[ch] = bands
            recomputeMagnitudes(for: ch)
        }
        let wValue = UInt16((ch << 8) | wireBand)
        let payload = Data([bypass ? 1 : 0])
        usb.sendControlRequest(request: REQ_SET_BAND_BYPASS, value: wValue, index: 0, data: payload)
    }

    /// Clear all crossover bands on an output channel by writing the default
    /// (FLAT, 1000 Hz, Q=0.707, gain=0, bypass=0) recipe to each.
    func clearCrossoverBands(ch: Int) {
        guard ch >= chOut1 else { return }
        for i in 0..<DSPViewModel.crossoverBandsPerChannel {
            let defaults = FilterParams(type: .flat, freq: 1000, q: 0.707, gain: 0)
            setCrossoverBand(ch: ch, localBand: i, p: defaults)
        }
    }

    /// Clear all PEQ bands on a single channel by writing the default
    /// (FLAT, 1000 Hz, Q=0.707, gain=0) recipe to each.  Mirrors
    /// `clearAllMaster` but scoped to one channel — used by the Clear All
    /// button on output channel PEQ tabs.
    func clearPEQBands(ch: Int) {
        let bandCount = channelData[ch]?.count ?? 10
        let defaults = FilterParams(type: .flat, freq: 1000, q: 0.707, gain: 0)
        for b in 0..<bandCount {
            setFilter(ch: ch, band: b, p: defaults)
        }
        recomputeMagnitudes(for: ch)
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

    /// Legacy global preamp SET — sets both channels to the same value via 0x44.
    func setPreamp(_ db: Float) {
        var val = (db * 10).rounded() / 10
        if val == -0.0 { val = 0.0 }
        self.preampDB = [val, val]
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_PREAMP, value: 0, index: 0, data: data)
    }

    /// Legacy global preamp GET — returns channel 0 only.
    @discardableResult
    func fetchPreamp() -> Bool {
        if let d = usb.getControlRequest(request: REQ_GET_PREAMP, value: 0, index: 0, length: 4) {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.preampDB[0] - val) > 0.1 {
                    self.preampDB[0] = val
                }
            }
            return true
        } else {
            DispatchQueue.main.async { self.usb.isConnected = false }
            return false
        }
    }

    // MARK: - Per-Channel Preamp

    func setPreampChannel(channel: Int, db: Float) {
        var val = (db * 10).rounded() / 10
        if val == -0.0 { val = 0.0 }
        self.preampDB[channel] = val
        let data = Data(bytes: &val, count: 4)
        // Link couples only the stereo USB L/R pair (inputs 0/1) via two
        // per-channel writes; never the legacy all-channel REQ_SET_PREAMP, which
        // would clobber the 8-channel input trims (inputs 2-7).
        if preampLinked && channel < BASE_MATRIX_INPUTS {
            let other = 1 - channel
            self.preampDB[other] = val
            usb.sendControlRequest(request: REQ_SET_PREAMP_CH, value: UInt16(channel), index: 0, data: data)
            usb.sendControlRequest(request: REQ_SET_PREAMP_CH, value: UInt16(other), index: 0, data: data)
        } else {
            usb.sendControlRequest(request: REQ_SET_PREAMP_CH, value: UInt16(channel), index: 0, data: data)
        }
    }

    func fetchPreampChannel(channel: Int) {
        if let d = usb.getControlRequest(request: REQ_GET_PREAMP_CH, value: UInt16(channel), index: 0, length: 4) {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.preampDB[channel] - val) > 0.1 {
                    self.preampDB[channel] = val
                }
            }
        }
    }

    // MARK: - Master Volume

    func setMasterVolume(_ db: Float) {
        var val = Self.roundMasterVolume(db)
        self.masterVolumeDB = val
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_MASTER_VOLUME, value: 0, index: 0, data: data)
    }

    func fetchMasterVolume() {
        if let d = usb.getControlRequest(request: REQ_GET_MASTER_VOLUME, value: 0, index: 0, length: 4) {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.masterVolumeDB - val) > 0.01 {
                    self.masterVolumeDB = val
                }
            }
        }
    }

    // MARK: - User Volume (vendor channel for audio_state.volume)

    /// Send a user-volume value (firmware applies it to the same field
    /// the UAC1 host slider drives — works across USB / SPDIF / I2S).
    /// Used during slider drag for live updates without re-publishing.
    func sendUserVolumeToDevice(_ db: Float) {
        var val = Self.clampUserVolume(db)
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_USER_VOLUME, value: 0, index: 0, data: data)
    }

    /// Set user volume — publish locally + send to device.  Range is
    /// clamped to the firmware-defined [-60, 0] dB window.
    func setUserVolume(_ db: Float) {
        var val = Self.clampUserVolume(db)
        self.userVolumeDB = val
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_USER_VOLUME, value: 0, index: 0, data: data)
    }

    func fetchUserVolume() {
        if let d = usb.getControlRequest(request: REQ_GET_USER_VOLUME, value: 0, index: 0, length: 4) {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.userVolumeDB - val) > 0.01 {
                    self.userVolumeDB = val
                }
            }
        }
    }

    // MARK: - LG Sound Sync

    /// Set the user-facing enable flag.  Per-preset; saved with REQ_SAVE_PRESET.
    /// Firmware emits a PARAM_CHANGED notification on the lg_sound_sync.enabled
    /// field at the V16 bulk offset (4728) — applyNotifiedParamChange mirrors that back
    /// for non-HOST sources, so other hosts' edits flow through automatically.
    func setLgSoundSyncEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { self.lgSoundSyncEnabled = enabled }
        usb.sendControlRequest(request: REQ_SET_LG_SOUND_SYNC_ENABLE, value: 0, index: 0,
                               data: Data([enabled ? 1 : 0]))
    }

    // MARK: - DAC Hardware Mute

    /// Write the full 16-byte DAC hardware mute config to the firmware.
    /// Optimistic local publish — the firmware emits a PARAM_CHANGED on the
    /// `dac_hw_mute` section in WireBulkParams which `applyNotifiedParamChange`
    /// will pick up for non-HOST sources, keeping multi-host clients in sync.
    ///
    /// The firmware applies/validates this deferred on its main loop and can
    /// reject it silently (e.g. an invalid or already-claimed pin) without
    /// emitting a change notification. Read it back after a short settle delay
    /// so our published value reflects what the device actually accepted rather
    /// than the optimistic guess. (Firmware contract: confirm via GET 0xEB.)
    func setDacHwMuteConfig(_ config: DacHwMuteConfig) {
        DispatchQueue.main.async { self.dacHwMuteConfig = config }
        usb.sendControlRequest(request: REQ_SET_DAC_HW_MUTE_CONFIG,
                               value: 0, index: 0, data: config.toData())
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
            self.fetchDacHwMuteConfig()
        }
    }

    /// Read the current DAC hardware mute config.  STALLs on firmware older
    /// than V10; if the call returns nil, `dacHwMuteSupported` stays false
    /// and the Settings section hides itself.
    func fetchDacHwMuteConfig() {
        guard let d = usb.getControlRequest(request: REQ_GET_DAC_HW_MUTE_CONFIG,
                                            value: 0, index: 0, length: 16),
              let cfg = DacHwMuteConfig.fromData(d) else { return }
        DispatchQueue.main.async {
            self.dacHwMuteConfig = cfg
            self.dacHwMuteSupported = true
        }
    }

    /// Pulse the DAC mute line for ~1 s so the installer can audibly verify
    /// the pin / polarity wiring.  IN-direction vendor request — returns
    /// a 1-byte status (PIN_CONFIG_SUCCESS on success, PIN_CONFIG_INVALID_OUTPUT
    /// when the feature is disabled).  The audible pulse runs deferred on
    /// the firmware's main loop after the status returns.
    @discardableResult
    func testDacHwMute() -> UInt8 {
        guard let d = usb.getControlRequest(request: REQ_TEST_DAC_HW_MUTE,
                                            value: 0, index: 0, length: 1),
              d.count >= 1 else {
            return 0xFF
        }
        return d[0]
    }

    /// Probe the firmware for LG Sound Sync support and read the current
    /// enable flag.  STALLs on firmware older than V8.
    func fetchLgSoundSyncEnabled() {
        if let d = usb.getControlRequest(request: REQ_GET_LG_SOUND_SYNC_ENABLE, value: 0, index: 0, length: 1),
           d.count >= 1 {
            let en = d[0] != 0
            DispatchQueue.main.async {
                self.lgSoundSyncEnabled = en
                self.lgSoundSyncSupported = true
            }
        }
    }

    private static func clampUserVolume(_ db: Float) -> Float {
        let clamped = max(USER_VOLUME_MIN_DB, min(USER_VOLUME_MAX_DB, db))
        return clamped == -0.0 ? 0.0 : clamped
    }

    // MARK: - Master Volume Mode (preset directory flag)

    /// Set master-volume persistence mode.
    /// Pass `MASTER_VOLUME_MODE_INDEPENDENT` (0, default) for the device-wide
    /// stored value or `MASTER_VOLUME_MODE_WITH_PRESET` (1) to make master
    /// volume part of each preset.
    func setMasterVolumeMode(_ mode: Int) {
        let clamped = UInt8(max(0, min(1, mode)))
        let normalized = (Int(clamped) == MASTER_VOLUME_MODE_WITH_PRESET) ? MASTER_VOLUME_MODE_WITH_PRESET
                                                                          : MASTER_VOLUME_MODE_INDEPENDENT
        DispatchQueue.main.async { self.presetMasterVolumeMode = normalized }
        usb.sendControlRequest(request: REQ_SET_MASTER_VOLUME_MODE, value: 0, index: 2, data: Data([clamped]))
    }

    func fetchMasterVolumeMode() {
        guard let data = usb.getControlRequest(request: REQ_GET_MASTER_VOLUME_MODE, value: 0, index: 2, length: 1) else { return }
        let val = Int(data[0])
        DispatchQueue.main.async {
            self.presetMasterVolumeMode = (val == MASTER_VOLUME_MODE_WITH_PRESET) ? MASTER_VOLUME_MODE_WITH_PRESET
                                                                                  : MASTER_VOLUME_MODE_INDEPENDENT
        }
    }

    /// Persist the current live master volume into the directory's independent
    /// storage. Accepted in any mode (dormant in MASTER_VOLUME_MODE_WITH_PRESET).
    /// IN-shaped action command: device responds with a 1-byte status (0 = OK).
    /// Returns true on success, false if the device disconnected or the
    /// transfer failed.
    @discardableResult
    func saveMasterVolume() -> Bool {
        guard let data = usb.getControlRequest(request: REQ_SAVE_MASTER_VOLUME, value: 0, index: 2, length: 1) else {
            return false
        }
        return data.first == 0  // PRESET_OK
    }

    /// Read the directory's independent master-volume value (the dB applied at
    /// boot in MASTER_VOLUME_MODE_INDEPENDENT). Independent of the current
    /// live value and the current mode. Returns nil if the transfer failed.
    func fetchSavedMasterVolume() -> Float? {
        guard let data = usb.getControlRequest(request: REQ_GET_SAVED_MASTER_VOLUME, value: 0, index: 2, length: 4),
              data.count >= 4 else { return nil }
        return data.withUnsafeBytes { $0.load(as: Float.self) }
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
        // Stereo input pair (channels 0/1).
        clearChannelPEQ(0)
        clearChannelPEQ(1)
    }

    /// Reset all 10 PEQ bands of a single channel to flat.
    func clearChannelPEQ(_ ch: Int) {
        let defaultFilter = FilterParams(type: .flat, freq: 1000, q: 0.707, gain: 0)
        for b in 0..<10 {
            setFilter(ch: ch, band: b, p: defaultFilter)
        }
        recomputeMagnitudes(for: ch)
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

    /// Sets the per-output loudness mask (V19+).  Bit k enables compensation on
    /// output channel k.  Sent as a 2-byte little-endian uint16; the firmware
    /// switches masks glitch-free from the next packet (no recompute or reset).
    func setLoudnessMask(_ mask: UInt16) {
        self.loudnessOutputMask = mask
        let data = Data([UInt8(mask & 0xFF), UInt8(mask >> 8)])
        usb.sendControlRequest(request: REQ_SET_LOUDNESS_MASK, value: 0, index: 0, data: data)
    }

    /// Toggles a single output channel's bit in the loudness mask and pushes it.
    func setLoudnessOutputChannel(_ output: Int, enabled: Bool) {
        guard output >= 0, output < 16 else { return }
        var mask = loudnessOutputMask
        if enabled { mask |= (UInt16(1) << output) } else { mask &= ~(UInt16(1) << output) }
        setLoudnessMask(mask)
    }

    func fetchLoudnessMask() {
        if let d = usb.getControlRequest(request: REQ_GET_LOUDNESS_MASK, value: 0, index: 0, length: 2), d.count >= 2 {
            let val = UInt16(d[0]) | (UInt16(d[1]) << 8)
            DispatchQueue.main.async { self.loudnessOutputMask = val }
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

    /// Sets the crossfeed output-pair mask (V20+).  Bit p runs crossfeed on output
    /// pair p (outputs 2p / 2p+1).  Sent as a single byte; the firmware clamps it to
    /// the platform's valid pair bits and switches masks glitch-free (no recompute).
    func setCrossfeedMask(_ mask: UInt8) {
        self.crossfeedOutputMask = mask
        var val = mask
        let data = Data(bytes: &val, count: 1)
        usb.sendControlRequest(request: REQ_SET_CROSSFEED_OUTPUTS, value: 0, index: 0, data: data)
    }

    /// Toggles a single output pair's bit in the crossfeed mask and pushes it.
    func setCrossfeedOutputPair(_ pair: Int, enabled: Bool) {
        guard pair >= 0, pair < 8 else { return }
        var mask = crossfeedOutputMask
        if enabled { mask |= (UInt8(1) << pair) } else { mask &= ~(UInt8(1) << pair) }
        setCrossfeedMask(mask)
    }

    func fetchCrossfeedMask() {
        if let d = usb.getControlRequest(request: REQ_GET_CROSSFEED_OUTPUTS, value: 0, index: 0, length: 1), !d.isEmpty {
            let val = d[0]
            DispatchQueue.main.async { self.crossfeedOutputMask = val }
        }
    }

    // MARK: - Psychoacoustic Bass

    func setPsybass(_ enabled: Bool) {
        self.psybassEnabled = enabled
        var val: UInt8 = enabled ? 1 : 0
        let data = Data(bytes: &val, count: 1)
        usb.sendControlRequest(request: REQ_SET_PSYBASS, value: 0, index: 0, data: data)
    }

    func fetchPsybass() {
        if let d = usb.getControlRequest(request: REQ_GET_PSYBASS, value: 0, index: 0, length: 1), !d.isEmpty {
            let val = d[0] != 0
            DispatchQueue.main.async { self.psybassEnabled = val }
        }
    }

    func setPsybassCutoff(_ hz: Float) {
        self.psybassCutoffHz = hz
        var val = hz
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_PSYBASS_CUTOFF, value: 0, index: 0, data: data)
    }

    func fetchPsybassCutoff() {
        if let d = usb.getControlRequest(request: REQ_GET_PSYBASS_CUTOFF, value: 0, index: 0, length: 4), d.count >= 4 {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.psybassCutoffHz - val) > 0.01 { self.psybassCutoffHz = val }
            }
        }
    }

    func setPsybassHarmonics(_ db: Float) {
        self.psybassHarmonicsDB = db
        var val = db
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_PSYBASS_HARMONICS, value: 0, index: 0, data: data)
    }

    func fetchPsybassHarmonics() {
        if let d = usb.getControlRequest(request: REQ_GET_PSYBASS_HARMONICS, value: 0, index: 0, length: 4), d.count >= 4 {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.psybassHarmonicsDB - val) > 0.01 { self.psybassHarmonicsDB = val }
            }
        }
    }

    func setPsybassDrive(_ db: Float) {
        self.psybassDriveDB = db
        var val = db
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_PSYBASS_DRIVE, value: 0, index: 0, data: data)
    }

    func fetchPsybassDrive() {
        if let d = usb.getControlRequest(request: REQ_GET_PSYBASS_DRIVE, value: 0, index: 0, length: 4), d.count >= 4 {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.psybassDriveDB - val) > 0.01 { self.psybassDriveDB = val }
            }
        }
    }

    func setPsybassCharacter(_ pct: Float) {
        self.psybassCharacterPct = pct
        var val = pct
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_PSYBASS_CHARACTER, value: 0, index: 0, data: data)
    }

    func fetchPsybassCharacter() {
        if let d = usb.getControlRequest(request: REQ_GET_PSYBASS_CHARACTER, value: 0, index: 0, length: 4), d.count >= 4 {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.psybassCharacterPct - val) > 0.01 { self.psybassCharacterPct = val }
            }
        }
    }

    func setPsybassOriginal(_ db: Float) {
        self.psybassOriginalDB = db
        var val = db
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_PSYBASS_ORIGINAL, value: 0, index: 0, data: data)
    }

    func fetchPsybassOriginal() {
        if let d = usb.getControlRequest(request: REQ_GET_PSYBASS_ORIGINAL, value: 0, index: 0, length: 4), d.count >= 4 {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs(self.psybassOriginalDB - val) > 0.01 { self.psybassOriginalDB = val }
            }
        }
    }

    /// Sets the per-output psybass mask.  Bit k processes output channel k; sent
    /// as a 2-byte little-endian uint16.  The firmware switches masks glitch-free
    /// from the next packet (no recompute) and clears skipped outputs' state.
    func setPsybassMask(_ mask: UInt16) {
        self.psybassOutputMask = mask
        let data = Data([UInt8(mask & 0xFF), UInt8(mask >> 8)])
        usb.sendControlRequest(request: REQ_SET_PSYBASS_MASK, value: 0, index: 0, data: data)
    }

    /// Toggles a single output channel's bit in the psybass mask and pushes it.
    func setPsybassOutputChannel(_ output: Int, enabled: Bool) {
        guard output >= 0, output < 16 else { return }
        var mask = psybassOutputMask
        if enabled { mask |= (UInt16(1) << output) } else { mask &= ~(UInt16(1) << output) }
        setPsybassMask(mask)
    }

    func fetchPsybassMask() {
        if let d = usb.getControlRequest(request: REQ_GET_PSYBASS_MASK, value: 0, index: 0, length: 2), d.count >= 2 {
            let val = UInt16(d[0]) | (UInt16(d[1]) << 8)
            DispatchQueue.main.async { self.psybassOutputMask = val }
        }
    }

    // MARK: - Stereo Upmixer (V25, cmds 0x4A-0x4E)

    /// Sends one upmix parameter as a 4-byte LE float via REQ_UPMIX_SET_PARAM
    /// (spec §6.2).  Preferred for live sliders: no read-modify-write race with
    /// other controllers.  The firmware clamps out-of-range values.
    private func sendUpmixParam(_ paramId: UInt16, _ value: Float) {
        var v = value
        let data = Data(bytes: &v, count: 4)
        usb.sendControlRequest(request: REQ_UPMIX_SET_PARAM, value: paramId, index: 0, data: data)
    }

    func setUpmixEnabled(_ enabled: Bool) {
        self.upmixEnabled = enabled
        sendUpmixParam(UPMIX_PARAM_ENABLED, enabled ? 1.0 : 0.0)
    }

    func setUpmixCenterMode(_ mode: Int) {
        self.upmixCenterMode = mode
        sendUpmixParam(UPMIX_PARAM_CENTER_MODE, Float(mode))
    }

    func setUpmixSurroundMode(_ mode: Int) {
        self.upmixSurroundMode = mode
        sendUpmixParam(UPMIX_PARAM_SURROUND_MODE, Float(mode))
    }

    func setUpmixStrength(_ pct: Float) {
        self.upmixStrengthPct = pct
        sendUpmixParam(UPMIX_PARAM_STRENGTH, pct)
    }

    func setUpmixCenterWidth(_ pct: Float) {
        self.upmixCenterWidthPct = pct
        sendUpmixParam(UPMIX_PARAM_CENTER_WIDTH, pct)
    }

    func setUpmixThreshold(_ pct: Float) {
        self.upmixThresholdPct = pct
        sendUpmixParam(UPMIX_PARAM_THRESHOLD, pct)
    }

    func setUpmixAttack(_ ms: Float) {
        self.upmixAttackMs = ms
        sendUpmixParam(UPMIX_PARAM_ATTACK, ms)
    }

    func setUpmixRelease(_ ms: Float) {
        self.upmixReleaseMs = ms
        sendUpmixParam(UPMIX_PARAM_RELEASE, ms)
    }

    func setUpmixDetectorHpf(_ hz: Float) {
        self.upmixDetectorHpfHz = hz
        sendUpmixParam(UPMIX_PARAM_DET_HPF, hz)
    }

    func setUpmixSurroundDelay(_ ms: Float) {
        self.upmixSurroundDelayMs = ms
        sendUpmixParam(UPMIX_PARAM_SUR_DELAY, ms)
    }

    func setUpmixSurroundHpf(_ hz: Float) {
        self.upmixSurroundHpfHz = hz
        sendUpmixParam(UPMIX_PARAM_SUR_HPF, hz)
    }

    func setUpmixSurroundLpf(_ hz: Float) {
        self.upmixSurroundLpfHz = hz
        sendUpmixParam(UPMIX_PARAM_SUR_LPF, hz)
    }

    func setUpmixDecorr(_ pct: Float) {
        self.upmixDecorrPct = pct
        sendUpmixParam(UPMIX_PARAM_DECORR, pct)
    }

    /// Centre presence bell gain (dB).  SET_PARAM carries a plain float dB (the
    /// firmware quantizes to 0.5 dB steps when it packs the config packet).
    func setUpmixPresence(_ db: Float) {
        self.upmixPresenceDB = db
        sendUpmixParam(UPMIX_PARAM_PRESENCE, db)
    }

    /// Reads the whole 44-byte UpmixConfigPacket in one transfer and publishes it
    /// (spec §6.1).  Called after a preset load / bulk SET; the bulk parse also
    /// keeps these fields current.  On RP2040 the GET returns zeros (feature off).
    func fetchUpmixConfig() {
        guard let d = usb.getControlRequest(request: REQ_UPMIX_GET_CONFIG, value: 0, index: 0,
                                            length: UInt16(UPMIX_CONFIG_PACKET_SIZE)),
              d.count >= UPMIX_CONFIG_PACKET_SIZE else { return }
        let enabled = d[0] != 0
        let centerMode = Int(d[1])
        let surroundMode = Int(d[2])
        // Byte 3 = presence_q1 (signed i8, 0.5 dB steps); V25 firmware wrote 0 here.
        let presence = Float(Int8(bitPattern: d[3])) / 2.0
        func f(_ off: Int) -> Float { d.withUnsafeBytes { $0.load(fromByteOffset: off, as: Float.self) } }
        let strength = f(4), width = f(8), threshold = f(12), attack = f(16), release = f(20)
        let detHpf = f(24), surDelay = f(28), surHpf = f(32), surLpf = f(36), decorr = f(40)
        DispatchQueue.main.async {
            self.upmixEnabled = enabled
            self.upmixCenterMode = centerMode
            self.upmixSurroundMode = surroundMode
            self.upmixPresenceDB = presence
            self.upmixStrengthPct = strength
            self.upmixCenterWidthPct = width
            self.upmixThresholdPct = threshold
            self.upmixAttackMs = attack
            self.upmixReleaseMs = release
            self.upmixDetectorHpfHz = detHpf
            self.upmixSurroundDelayMs = surDelay
            self.upmixSurroundHpfHz = surHpf
            self.upmixSurroundLpfHz = surLpf
            self.upmixDecorrPct = decorr
        }
    }

    /// Polls the 16-byte UpmixStatus telemetry (spec §6.3).  Called from the
    /// shared poll timer only while the upmixer window is open.
    func fetchUpmixStatus() {
        guard let d = usb.getControlRequest(request: REQ_UPMIX_GET_STATUS, value: 0, index: 0,
                                            length: UPMIX_STATUS_SIZE),
              d.count >= 16 else { return }
        let active = d[0] != 0
        let parked = d[1]
        let corr = d.withUnsafeBytes { $0.load(fromByteOffset: 2, as: Int16.self) }
        let balance = d.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }
        let centerGain = d.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }
        let lsGain = d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt16.self) }
        let rsGain = d.withUnsafeBytes { $0.load(fromByteOffset: 10, as: UInt16.self) }
        DispatchQueue.main.async {
            self.upmixActive = active
            self.upmixParkedReason = parked
            self.upmixCorr = Float(corr) / 16384.0        // Q14, [-1, +1]
            self.upmixBalance = Float(balance) / 16384.0  // Q14, 0..1
            self.upmixCenterGain = Float(centerGain) / 32767.0  // Q15, 0..1
            self.upmixLsGain = Float(lsGain) / 32767.0
            self.upmixRsGain = Float(rsGain) / 32767.0
        }
    }

    // MARK: - Volume Leveller

    func setLeveller(_ enabled: Bool) {
        self.levellerEnabled = enabled
        var val: UInt8 = enabled ? 1 : 0
        let data = Data(bytes: &val, count: 1)
        usb.sendControlRequest(request: REQ_SET_LEVELLER, value: 0, index: 0, data: data)
    }

    func setLevellerAmount(_ amount: Float) {
        self.levellerAmount = amount
        var val = amount
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_LEVELLER_AMOUNT, value: 0, index: 0, data: data)
    }

    func setLevellerSpeed(_ speed: Int) {
        self.levellerSpeed = speed
        var val = UInt8(speed)
        let data = Data(bytes: &val, count: 1)
        usb.sendControlRequest(request: REQ_SET_LEVELLER_SPEED, value: 0, index: 0, data: data)
    }

    func setLevellerMaxGain(_ db: Float) {
        self.levellerMaxGainDB = db
        var val = db
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_LEVELLER_MAXGAIN, value: 0, index: 0, data: data)
    }

    func setLevellerLookahead(_ enabled: Bool) {
        self.levellerLookahead = enabled
        var val: UInt8 = enabled ? 1 : 0
        let data = Data(bytes: &val, count: 1)
        usb.sendControlRequest(request: REQ_SET_LEVELLER_LOOKAHEAD, value: 0, index: 0, data: data)
    }

    func setLevellerGate(_ db: Float) {
        self.levellerGateDB = db
        var val = db
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_LEVELLER_GATE, value: 0, index: 0, data: data)
    }

    /// Sets both leveller channel masks (V18). `detector` selects which inputs
    /// feed the shared RMS detector; `apply` selects which inputs receive the
    /// shared gain. Bit k = input channel k. Sent as a single 2-byte payload;
    /// the firmware switches masks glitch-free without a state reset.
    func setLevellerMasks(detector: UInt8, apply: UInt8) {
        self.levellerDetectorMask = detector
        self.levellerApplyMask = apply
        let data = Data([detector, apply])
        usb.sendControlRequest(request: REQ_SET_LEVELLER_MASKS, value: 0, index: 0, data: data)
    }

    /// Toggles a single channel's bit in the detector mask and pushes both masks.
    func setLevellerDetectorChannel(_ channel: Int, enabled: Bool) {
        guard channel >= 0, channel < 8 else { return }
        var mask = levellerDetectorMask
        if enabled { mask |= (1 << channel) } else { mask &= ~(UInt8(1) << channel) }
        setLevellerMasks(detector: mask, apply: levellerApplyMask)
    }

    /// Toggles a single channel's bit in the apply mask and pushes both masks.
    func setLevellerApplyChannel(_ channel: Int, enabled: Bool) {
        guard channel >= 0, channel < 8 else { return }
        var mask = levellerApplyMask
        if enabled { mask |= (1 << channel) } else { mask &= ~(UInt8(1) << channel) }
        setLevellerMasks(detector: levellerDetectorMask, apply: mask)
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

    /// Apply a direct 1:1 routing (recipe 11.1 of the 8-channel-usb-input spec):
    /// input i → output i at 0 dB for i in 0..<numMatrixInputs, enabling those
    /// outputs and disabling the PDM sub.  All other crosspoints are cleared so
    /// the result is exactly the diagonal.  Only issues async (fire-and-forget)
    /// control transfers and no blocking read-backs, so it is safe to call on
    /// the main thread.
    func applyDirectRouting() {
        let n = min(numMatrixInputs, numOutputChannels)
        // Free Core 1 first: disabling the PDM sub lets the per-output EQ workers
        // (outputs 2-7) be enabled without a shared-resource conflict.
        if outputEnabled[pdmOutputIndex] {
            setOutputEnable(output: pdmOutputIndex, enabled: false)
        }
        // Reset every crosspoint to the i→i diagonal.
        for i in 0..<numMatrixInputs {
            for o in 0..<numOutputChannels {
                let on = (i == o && i < n)
                if matrixRouting[i][o] != on || matrixGain[i][o] != 0 || matrixInvert[i][o] {
                    setMatrixRoute(input: i, output: o, enabled: on, gain: 0, invert: false)
                }
            }
        }
        // Enable the diagonal outputs (PDM stays off).
        for o in 0..<n where o != pdmOutputIndex {
            if !outputEnabled[o] { setOutputEnable(output: o, enabled: true) }
        }
    }

    /// Disconnect every matrix crosspoint, leaving gains/phase untouched.  Run
    /// off the main thread.
    func clearAllRoutes() {
        for i in 0..<numMatrixInputs {
            for o in 0..<numOutputChannels where matrixRouting[i][o] {
                setMatrixRoute(input: i, output: o, enabled: false,
                               gain: matrixGain[i][o], invert: matrixInvert[i][o])
            }
        }
    }

    // MARK: - Per-Output Enable

    func setOutputEnable(output: Int, enabled: Bool) {
        outputEnabled[output] = enabled
        if isOverviewMode {
            channelVisibility[eqChannel(forOutput: output)] = enabled
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

    /// Set a BCK GPIO pin (LRCLK = BCK + 1).  `role` selects the master/unified
    /// pair (0, the default and legacy behavior) or the slave pair (1, SPLIT
    /// clock-pin mode only; storable any time while dormant).  wValue packs the
    /// role in its high byte.  The master pair requires all slots to be S/PDIF
    /// when it is the one clocking outputs (clock_pins_spec.md §3).
    @discardableResult
    func setI2SBckPin(_ pin: UInt8, role: UInt8 = I2S_BCK_ROLE_MASTER) -> UInt8 {
        let wValue = (UInt16(role) << 8) | UInt16(pin)
        if let d = usb.getControlRequest(request: REQ_SET_I2S_BCK_PIN, value: wValue, index: 2, length: 1) {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async {
                    if role == I2S_BCK_ROLE_SLAVE { self.i2sBckPinSlave = pin }
                    else { self.i2sBckPin = pin }
                }
            }
            return status
        }
        return 0xFF
    }

    func fetchI2SBckPin(role: UInt8 = I2S_BCK_ROLE_MASTER) {
        if let d = usb.getControlRequest(request: REQ_GET_I2S_BCK_PIN, value: UInt16(role), index: 2, length: 1) {
            let pin = d[0]
            DispatchQueue.main.async {
                if role == I2S_BCK_ROLE_SLAVE { self.i2sBckPinSlave = pin }
                else { self.i2sBckPin = pin }
            }
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
    /// Wire encoding (V5+): wValue 0 = 128x, 1 = 256x.
    @discardableResult
    func setMckMultiplier(_ multiplier: Int) -> UInt8 {
        let wireValue: UInt16 = (multiplier == 256) ? 1 : 0
        if let d = usb.getControlRequest(request: REQ_SET_MCK_MULTIPLIER, value: wireValue, index: 2, length: 1) {
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
            let value = raw == 1 ? 256 : 128  // V5 encoding: 0 = 128x, 1 = 256x
            DispatchQueue.main.async { self.mckMultiplier = value }
        }
    }

    // MARK: - ADAT Bulk Output Commands
    //
    // RP2350-only ADAT lightpipe of all 8 main output channels on one GPIO.
    // See adat_output_spec.md.  Both SETs are IN-direction transfers carrying
    // the value in wValue and returning a PIN_CONFIG_* status byte (same shape
    // as REQ_SET_SPDIF_RX_PIN); on RP2040 they return INVALID_OUTPUT.

    /// Probe + refresh live ADAT state via REQ_GET_ADAT_STATUS.  A STALL (nil)
    /// means the firmware predates ADAT; combined with the RP2350 gate this sets
    /// `adatSupported`.  Called from `fetchAll` after the bulk fetch.
    func fetchAdatStatus() {
        guard let data = usb.getControlRequest(request: REQ_GET_ADAT_STATUS, value: 0, index: 2, length: 8),
              let status = AdatStatus.fromData(data) else {
            DispatchQueue.main.async { self.adatSupported = false }
            return
        }
        DispatchQueue.main.async {
            // The engine is compiled out on RP2040 (status all-zero); gate the UI
            // on platform so a zeroed RP2040 response never shows the section.
            self.adatSupported = (self.platformName == "RP2350")
            self.adatStatus = status
            self.adatEnabled = status.enabled
            if status.pin != 0 { self.adatPin = status.pin }
        }
    }

    /// Alias kept parallel to the other `fetch…Config` probes used by `fetchAll`.
    func fetchAdatConfig() { fetchAdatStatus() }

    /// Enable or disable the ADAT bulk output.  Enabling validates the
    /// configured pin first (INVALID_PIN / PIN_IN_USE on conflict); disabling
    /// always succeeds.  Returns the firmware status byte (0xFF on transfer
    /// failure).
    @discardableResult
    func setAdatEnable(_ enabled: Bool) -> UInt8 {
        if let d = usb.getControlRequest(request: REQ_SET_ADAT_ENABLE, value: enabled ? 1 : 0, index: 2, length: 1),
           d.count >= 1 {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async {
                    self.adatEnabled = enabled
                    self.adatStatus.enabled = enabled
                }
            }
            return status
        }
        return 0xFF
    }

    /// Set the ADAT data GPIO.  `wValue = 0` resets to the platform default
    /// (ADAT_PIN_DEFAULT).  May be issued while enabled; the firmware re-routes
    /// under a muted restart.  Returns the firmware status byte.
    @discardableResult
    func setAdatPin(_ pin: UInt8) -> UInt8 {
        if let d = usb.getControlRequest(request: REQ_SET_ADAT_PIN, value: UInt16(pin), index: 2, length: 1),
           d.count >= 1 {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                let applied = pin == 0 ? ADAT_PIN_DEFAULT : pin
                DispatchQueue.main.async {
                    self.adatPin = applied
                    self.adatStatus.pin = applied
                }
            }
            return status
        }
        return 0xFF
    }

    // MARK: - ADAT Input Commands
    //
    // RP2350-only selectable 8-channel ADAT input (INPUT_SOURCE_ADAT = 3).  See
    // adat_input_spec.md.  Both SETs are IN-direction transfers carrying the value
    // in wValue and returning a PIN_CONFIG_* status byte; on RP2040 0x68/0x6A
    // return INVALID_OUTPUT and 0x6E returns zeros (the config GETs round-trip).

    /// Probe + refresh live ADAT input state via REQ_GET_ADAT_INPUT_STATUS (0x6E).
    /// A STALL (nil) means the firmware predates ADAT input; combined with the
    /// RP2350 gate this sets `adatInputSupported`.  Called from `fetchAll`.
    func fetchAdatInputConfig() {
        guard let data = usb.getControlRequest(request: REQ_GET_ADAT_INPUT_STATUS, value: 0, index: 2, length: 20),
              let status = AdatInputStatus.fromData(data) else {
            DispatchQueue.main.async { self.adatInputSupported = false }
            return
        }
        DispatchQueue.main.async {
            // The engine is compiled out on RP2040 (status all-zero); gate the UI
            // on platform so a zeroed RP2040 response never shows the section.
            self.adatInputSupported = (self.platformName == "RP2350")
            self.adatInputStatus = status
            self.adatInputEnabled = status.enabled
            self.adatInputClockMode = status.clockMode
            self.adatInputPin = status.pin
        }
    }

    /// Refresh only the live 20-byte AdatInputStatusPacket (lock state, counts,
    /// detected/measured rate) for the settings lock indicator.  Also re-syncs the
    /// configured enable / pin / clock mode the packet carries.
    func fetchAdatInputStatus() {
        guard let d = usb.getControlRequest(request: REQ_GET_ADAT_INPUT_STATUS, value: 0, index: 2, length: 20),
              let status = AdatInputStatus.fromData(d) else { return }
        DispatchQueue.main.async {
            self.adatInputStatus = status
            self.adatInputClockMode = status.clockMode
            self.adatInputEnabled = status.enabled
            self.adatInputPin = status.pin
        }
    }

    /// Enable or disable the ADAT input.  Enabling validates the configured pin
    /// first (INVALID_PIN when unset/invalid, PIN_IN_USE on conflict); disabling
    /// is refused (PIN_IN_USE) while ADAT is the active source.  Returns the
    /// firmware PIN_CONFIG_* status byte (0xFF on transfer failure).
    @discardableResult
    func setAdatInputEnable(_ enabled: Bool) -> UInt8 {
        if let d = usb.getControlRequest(request: REQ_SET_ADAT_INPUT_ENABLE, value: enabled ? 1 : 0, index: 2, length: 1),
           d.count >= 1 {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async {
                    self.adatInputEnabled = enabled
                    self.adatInputStatus.enabled = enabled
                }
            }
            return status
        }
        return 0xFF
    }

    /// Set the ADAT input RX GPIO (or 0xFF to clear, allowed only while disabled).
    /// The pin MAY equal the ADAT output pin (loopback self-test).  May be issued
    /// while ADAT is the live source; the firmware re-routes under a muted restart.
    /// Returns the firmware PIN_CONFIG_* status byte.
    @discardableResult
    func setAdatInputPin(_ pin: UInt8) -> UInt8 {
        if let d = usb.getControlRequest(request: REQ_SET_ADAT_INPUT_PIN, value: UInt16(pin), index: 2, length: 1),
           d.count >= 1 {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async {
                    self.adatInputPin = pin
                    self.adatInputStatus.pin = pin
                }
            }
            return status
        }
        return 0xFF
    }

    /// Select the ADAT input clock mode (0=master, 1=slave) via 0x6C.  Deferred:
    /// the firmware applies it in its main loop (instantly when ADAT is not the
    /// active source, otherwise under a muted receiver restart).  Returns the
    /// PIN_CONFIG_* status byte; the live mode is confirmed via the
    /// adat_clock_mode_p1 PARAM_CHANGED (or the next NOTIFY 0x0B).  Part of the
    /// output-config block, so callers must mark it dirty (beginOutputEdit).
    @discardableResult
    func setAdatInputClockMode(_ mode: UInt8) -> UInt8 {
        let clamped: UInt8 = mode == ADAT_INPUT_CLOCK_MODE_SLAVE ? ADAT_INPUT_CLOCK_MODE_SLAVE : ADAT_INPUT_CLOCK_MODE_MASTER
        if let d = usb.getControlRequest(request: REQ_SET_ADAT_INPUT_CLOCK_MODE, value: UInt16(clamped), index: 2, length: 1),
           d.count >= 1 {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async {
                    self.adatInputClockMode = clamped
                    self.adatInputStatus.clockMode = clamped
                }
            }
            return status
        }
        return 0xFF
    }

    // MARK: - Input Source Commands

    /// Probes GET_INPUT_SOURCE. If the device STALLs (nil), the feature is unsupported.
    func fetchInputSource() {
        let data = usb.getControlRequest(request: REQ_GET_INPUT_SOURCE, value: 0, index: 2, length: 1)
        DispatchQueue.main.async {
            if let data = data, data.count >= 1 {
                self.inputSourceSupported = true
                self.inputSource = Int(data[0])
            } else {
                self.inputSourceSupported = false
                self.inputSource = 0
            }
        }
        if data != nil {
            fetchSpdifInputConfig()
            fetchI2SInputConfig()
        }
    }

    /// Reads the whole S/PDIF input inventory in one transfer (REQ_GET_SPDIF_INPUT_CONFIG,
    /// firmware v1.1.5+): input count, enable mask, and each input's GPIO pin.  On
    /// older firmware the request STALLs; we fall back to the single-input pin read
    /// (REQ_GET_SPDIF_RX_PIN index 0) and mark multi-input as unsupported.
    func fetchSpdifInputConfig() {
        // The response is 2 + count bytes.  Ask for the largest inventory we know
        // about; a three-input firmware answers short, which is why the pin list
        // is sized from the returned count rather than a fixed length.
        let maxLen = UInt16(2 + SPDIF_RX_NUM_INPUTS)
        guard let d = usb.getControlRequest(request: REQ_GET_SPDIF_INPUT_CONFIG, value: 0, index: 2, length: maxLen),
              d.count >= 3 else {
            DispatchQueue.main.async {
                self.multiSpdifSupported = false
                self.spdifInputCount = 1
            }
            fetchSpdifRxPin()
            return
        }
        let count = min(Int(d[0]), min(d.count - 2, SPDIF_RX_NUM_INPUTS))
        let mask = d[1]
        let pin0 = d[2]
        // Keep the ext arrays at full length whatever the device reports, so a
        // three-input device still has a well-formed slot for a future input 4;
        // indices past `count` stay at their defaults and are never shown.
        var pinsExt = Array(SPDIF_RX_PIN_DEFAULTS.dropFirst())
        var enabled = Array(repeating: false, count: SPDIF_RX_NUM_INPUTS - 1)
        for idx in 1..<max(count, 1) {
            pinsExt[idx - 1] = d[2 + idx]
            enabled[idx - 1] = (mask & (1 << UInt8(idx))) != 0
        }
        DispatchQueue.main.async {
            self.multiSpdifSupported = true
            self.spdifInputCount = max(count, 1)
            self.spdifRxPin = pin0
            self.spdifRxPinsExt = pinsExt
            self.spdifExtEnabled = enabled
        }
    }

    func setInputSource(_ source: Int) {
        let byte = Data([UInt8(source)])

        DispatchQueue.main.async {
            self.inputSource = source
        }

        usb.sendControlRequest(request: REQ_SET_INPUT_SOURCE, value: 0, index: 2, data: byte)

        // No follow-up fetch here — the firmware emits an
        // `input_config.input_source` notification at the end of its
        // deferred switch handler (main.c:1662).  applyNotifiedParamChange
        // catches that and triggers fetchUserVolume() at the right
        // moment instead of guessing a sleep duration.
    }

    /// Reads a single S/PDIF input's GPIO pin (default index 0 = input 1).
    func fetchSpdifRxPin(index: Int = 0) {
        if let data = usb.getControlRequest(request: REQ_GET_SPDIF_RX_PIN, value: UInt16(index), index: 2, length: 1),
           data.count >= 1 {
            let pin = data[0]
            DispatchQueue.main.async {
                if index == 0 { self.spdifRxPin = pin }
                else if self.spdifRxPinsExt.indices.contains(index - 1) { self.spdifRxPinsExt[index - 1] = pin }
            }
        }
    }

    /// Set the GPIO pin used for a S/PDIF input (index 0..3, default 0 = input 1).
    /// Single IN transfer: wValue = (index << 8) | pin.  Returns the firmware
    /// PIN_CONFIG_* status code.  The pin is hot-swappable while the input is
    /// active (no OUTPUT_ACTIVE rejection); a disabled optional input stores the
    /// pin as a preference validated at enable time.
    @discardableResult
    func setSpdifRxPin(index: Int = 0, _ pin: UInt8) -> UInt8 {
        let wValue = UInt16((index << 8) | Int(pin))
        if let d = usb.getControlRequest(request: REQ_SET_SPDIF_RX_PIN, value: wValue, index: 2, length: 1) {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async {
                    if index == 0 { self.spdifRxPin = pin }
                    else if self.spdifRxPinsExt.indices.contains(index - 1) { self.spdifRxPinsExt[index - 1] = pin }
                }
            }
            return status
        }
        return 0xFF
    }

    /// Enable or disable an optional S/PDIF input (index 1..3 = SPDIF 2/3/4).
    /// Input 1 (index 0) is always enabled.  IN transfer: wValue = (index<<8)|enable.
    /// Returns the firmware PIN_CONFIG_* status.  Enabling validates the configured
    /// pin; disabling is refused (PIN_IN_USE) while the input is the active source.
    @discardableResult
    func setSpdifInputEnable(index: Int, _ enable: Bool) -> UInt8 {
        let wValue = UInt16((index << 8) | (enable ? 1 : 0))
        if let d = usb.getControlRequest(request: REQ_SET_SPDIF_INPUT_ENABLE, value: wValue, index: 2, length: 1),
           d.count >= 1 {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS, index >= 1, self.spdifExtEnabled.indices.contains(index - 1) {
                let i = index - 1
                DispatchQueue.main.async { self.spdifExtEnabled[i] = enable }
            }
            return status
        }
        return 0xFF
    }

    // MARK: - I2S Input Commands

    /// Probes I2S input support (firmware V12+).  REQ_GET_I2S_RX_PIN STALLs on
    /// older firmware; on success we read every stereo pair's data pin, the
    /// active channel count, the shared BCK pin, and the selected input rate.
    func fetchI2SInputConfig() {
        guard let data = usb.getControlRequest(request: REQ_GET_I2S_RX_PIN, value: 0, index: 2, length: 1),
              data.count >= 1 else {
            DispatchQueue.main.async { self.i2sInputSupported = false }
            return
        }
        DispatchQueue.main.async {
            self.i2sInputSupported = true
            self.i2sRxPins[0] = data[0]
        }
        // Extra stereo pairs (RP2350).  Older/stereo firmware returns 0 for
        // pairs it doesn't have; keep the default in that case.
        for pair in 1..<I2S_RX_MAX_PAIRS_RP2350 {
            if let d = usb.getControlRequest(request: REQ_GET_I2S_RX_PIN, value: UInt16(pair), index: 2, length: 1),
               d.count >= 1, d[0] != 0 {
                let p = d[0]
                DispatchQueue.main.async { self.i2sRxPins[pair] = p }
            }
        }
        fetchI2SInputChannels()
        fetchInputRate()
        fetchI2SClockMode()
        fetchI2SClockPinMode()
    }

    /// Reads the active I2S input channel count (2/4/6/8).  STALLs on firmware
    /// that predates multichannel I2S; leaves the default (2) in that case.
    func fetchI2SInputChannels() {
        guard let d = usb.getControlRequest(request: REQ_GET_I2S_INPUT_CHANNELS, value: 0, index: 2, length: 1),
              d.count >= 1, d[0] != 0 else { return }
        let count = Int(d[0])
        DispatchQueue.main.async { self.i2sInputChannels = count }
    }

    /// Selects the active I2S input channel count (2/4/6/8 → 1..4 stereo pairs).
    /// IN transfer returning a PIN_CONFIG_* status: a raise validates each newly
    /// activated pair's data pin and is rejected (without changing state) on a
    /// clash; RP2040 rejects anything but 2.  Part of the output-config block,
    /// so callers should mark it dirty (beginOutputEdit).  On success the device
    /// pushes NOTIFY_EVT_INPUT_FORMAT so the channel strips relayout.
    @discardableResult
    func setI2SInputChannels(_ count: Int) -> UInt8 {
        if let d = usb.getControlRequest(request: REQ_SET_I2S_INPUT_CHANNELS, value: UInt16(count), index: 2, length: 1),
           d.count >= 1 {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async { self.i2sInputChannels = count }
            }
            return status
        }
        return 0xFF
    }

    /// Reads {current pipeline Hz, selected I2S Hz} via REQ_GET_INPUT_RATE.
    /// Only the selected I2S rate drives the picker; the current rate is valid
    /// for all sources but we already track it via REQ_GET_STATUS.
    func fetchInputRate() {
        guard let data = usb.getControlRequest(request: REQ_GET_INPUT_RATE, value: 0, index: 2, length: 8),
              data.count >= 8 else { return }
        let selected: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        DispatchQueue.main.async { self.i2sInputRateHz = selected }
    }

    /// Selects the I2S input sample rate (44100 / 48000 / 96000 Hz).  Applied
    /// live immediately if I2S is the active source.  Part of the device's
    /// output-config block (alongside the RX pins / MCK / BCK), so it only
    /// persists to flash via saveOutputConfig() in independent mode, or with
    /// the preset in with-preset mode - callers in Settings must mark the
    /// output config dirty (beginOutputEdit) so the save flow picks it up.
    /// Invalid rates are silently ignored by the firmware (no SET response).
    func setInputRate(_ hz: UInt32) {
        guard I2S_INPUT_RATES_HZ.contains(hz) else { return }
        DispatchQueue.main.async { self.i2sInputRateHz = hz }
        var le = hz.littleEndian
        let payload = withUnsafeBytes(of: &le) { Data($0) }
        usb.sendControlRequest(request: REQ_SET_INPUT_RATE, value: 0, index: 2, data: payload)
    }

    /// Sets the GPIO data pin for an I2S RX stereo pair (0..3).  Single IN
    /// transfer: wValue = (pair << 8) | gpio.  Returns the firmware PIN_CONFIG_*
    /// status code.  Pair 0 hot-swaps when stereo; any higher pair (or a
    /// multichannel config) restarts the input so every pair re-syncs.
    @discardableResult
    func setI2SRxPin(pair: Int = 0, _ pin: UInt8) -> UInt8 {
        let wValue = UInt16((pair << 8) | Int(pin))
        if let d = usb.getControlRequest(request: REQ_SET_I2S_RX_PIN, value: wValue, index: 2, length: 1),
           d.count >= 1 {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async {
                    if self.i2sRxPins.indices.contains(pair) { self.i2sRxPins[pair] = pin }
                }
            }
            return status
        }
        return 0xFF
    }
    // (The shared I2S BCK pin is set/read via setI2SBckPin/fetchI2SBckPin in the
    // I2S output section above — BCK is shared between I2S input and output.)

    // MARK: - I2S Clock-Slave Input Mode

    /// Reads the live I2S clock mode (0=master, 1=slave) via REQ_GET_I2S_CLOCK_MODE
    /// (0x89).  STALLs on firmware that predates the clock-slave feature, which
    /// leaves `i2sClockModeSupported` false so the mode picker hides itself.
    /// On success it also fetches the current slave-lock status.
    func fetchI2SClockMode() {
        guard let d = usb.getControlRequest(request: REQ_GET_I2S_CLOCK_MODE, value: 0, index: 2, length: 1),
              d.count >= 1 else {
            DispatchQueue.main.async { self.i2sClockModeSupported = false }
            return
        }
        let mode = d[0]
        DispatchQueue.main.async {
            self.i2sClockModeSupported = true
            self.i2sClockMode = mode
        }
        fetchI2SSlaveStatus()
    }

    /// Selects the I2S clock mode (0=master, 1=slave) via REQ_SET_I2S_CLOCK_MODE
    /// (0x88), OUT 1 byte.  Fire-and-forget: the firmware defers the transition
    /// to its main loop and only applies it while I2S is the input source (it is
    /// otherwise recorded and applies at the next switch into I2S).  The live
    /// mode is confirmed via the input_config.i2s_clock_mode PARAM_CHANGED (or
    /// the first NOTIFY 0x09) - we optimistically mirror it here for a snappy UI.
    /// Part of the output-config block, so callers in Settings must mark it dirty
    /// (beginOutputEdit) for the save flow to pick it up.
    func setI2SClockMode(_ mode: UInt8) {
        let clamped: UInt8 = mode == I2S_CLOCK_MODE_SLAVE ? I2S_CLOCK_MODE_SLAVE : I2S_CLOCK_MODE_MASTER
        DispatchQueue.main.async { self.i2sClockMode = clamped }
        usb.sendControlRequest(request: REQ_SET_I2S_CLOCK_MODE, value: 0, index: 2, data: Data([clamped]))
    }

    /// Reads the 16-byte I2sSlaveStatusPacket via REQ_GET_I2S_SLAVE_STATUS (0x8A)
    /// for the clock-slave lock-state indicator (state, lock/loss counts, snapped
    /// + measured rates).  STALLs on firmware that predates the feature; the live
    /// mode byte it carries also refreshes `i2sClockMode`.
    func fetchI2SSlaveStatus() {
        guard let d = usb.getControlRequest(request: REQ_GET_I2S_SLAVE_STATUS, value: 0, index: 2, length: 16),
              let status = I2sSlaveStatus.fromData(d) else { return }
        DispatchQueue.main.async {
            self.i2sClockModeSupported = true
            self.i2sSlaveStatus = status
            self.i2sClockMode = status.clockMode
        }
    }

    // MARK: - I2S Clock-Pin Mode (Unified / Split)

    /// Reads the live I2S clock-pin mode (0=unified, 1=split) via
    /// REQ_GET_I2S_CLOCK_PIN_MODE (0xFF).  STALLs on firmware that predates the
    /// feature, leaving `i2sClockPinModeSupported` false so the picker hides
    /// itself.  On success it also reads the stored slave-pair BCK pin (role 1)
    /// so the picker and pin-conflict checks reflect it even while dormant.
    func fetchI2SClockPinMode() {
        guard let d = usb.getControlRequest(request: REQ_GET_I2S_CLOCK_PIN_MODE, value: 0, index: 2, length: 1),
              d.count >= 1 else {
            DispatchQueue.main.async { self.i2sClockPinModeSupported = false }
            return
        }
        let mode = d[0]
        DispatchQueue.main.async {
            self.i2sClockPinModeSupported = true
            self.i2sClockPinMode = mode
        }
        fetchI2SBckPin(role: I2S_BCK_ROLE_SLAVE)
    }

    /// Selects the I2S clock-pin mode (0=unified, 1=split) via
    /// REQ_SET_I2S_CLOCK_PIN_MODE (0xFE), IN transfer returning a PIN_CONFIG_*
    /// status.  Unlike the clock MODE (0x88) this applies synchronously - the
    /// status byte is authoritative (only the hardware restart is deferred).
    /// Part of the output-config block, so Settings callers must mark it dirty
    /// (beginOutputEdit) for the save flow to pick it up.
    @discardableResult
    func setI2SClockPinMode(_ mode: UInt8) -> UInt8 {
        if let d = usb.getControlRequest(request: REQ_SET_I2S_CLOCK_PIN_MODE, value: UInt16(mode), index: 2, length: 1) {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async { self.i2sClockPinMode = mode }
            }
            return status
        }
        return 0xFF
    }

    // MARK: - External Control Interfaces (UART / I2C target)

    /// Probe the firmware for control-interface support and read the live UART/I2C
    /// configs plus the interface status.  REQ_GET_CTRL_IFACE_STATUS (0xF9) STALLs
    /// on firmware that predates this feature; if it returns nil,
    /// `controlInterfacesSupported` stays false and the Settings page hides itself.
    func fetchControlInterfaces() {
        guard let s = usb.getControlRequest(request: REQ_GET_CTRL_IFACE_STATUS, value: 0, index: 2, length: 8),
              let status = CtrlIfaceStatus.fromData(s) else {
            DispatchQueue.main.async { self.controlInterfacesSupported = false }
            return
        }
        DispatchQueue.main.async {
            self.controlInterfacesSupported = true
            self.ctrlIfaceStatus = status
        }
        fetchUartCtrlConfig()
        fetchI2cCtrlConfig()
    }

    /// Read the live 8-byte UART control-interface config.
    func fetchUartCtrlConfig() {
        guard let d = usb.getControlRequest(request: REQ_GET_UART_CONFIG, value: 0, index: 2, length: 8),
              let cfg = UartCtrlConfig.fromData(d) else { return }
        DispatchQueue.main.async { self.uartCtrlConfig = cfg }
    }

    /// Read the live 8-byte I2C control-interface config.
    func fetchI2cCtrlConfig() {
        guard let d = usb.getControlRequest(request: REQ_GET_I2C_CONFIG, value: 0, index: 2, length: 8),
              let cfg = I2cCtrlConfig.fromData(d) else { return }
        DispatchQueue.main.async { self.i2cCtrlConfig = cfg }
    }

    /// Read just the interface status (last-apply outcome + live flags).  Cheap
    /// enough to poll after a SET to learn whether the peripheral came up.
    func fetchCtrlIfaceStatus() {
        guard let d = usb.getControlRequest(request: REQ_GET_CTRL_IFACE_STATUS, value: 0, index: 2, length: 8),
              let status = CtrlIfaceStatus.fromData(d) else { return }
        DispatchQueue.main.async { self.ctrlIfaceStatus = status }
    }

    /// Apply and persist the UART control-interface config.  This is an OUT
    /// transfer carrying the full 8-byte struct; the firmware validates + applies
    /// it deferred on its main loop and (on success) writes flash, so the outcome
    /// is not available synchronously.  We give the device time to run the deferred
    /// apply, then read back the config and the PIN_CONFIG_* outcome from
    /// REQ_GET_CTRL_IFACE_STATUS (0xF9) and return the UART last-status byte.
    /// USB-only command; must be called off the main thread (it blocks).
    @discardableResult
    func setUartCtrlConfig(_ config: UartCtrlConfig) -> UInt8 {
        let generation = usb.generation
        usb.sendControlRequest(request: REQ_SET_UART_CONFIG, value: 0, index: 2, data: config.toData())
        // Deferred apply + ~45 ms flash blackout on the device; wait before reading.
        Thread.sleep(forTimeInterval: 0.25)
        // A device switch during the wait means the SET was dropped (or went
        // to the old device) - don't report the new device's status as ours.
        guard usb.generation == generation else { return 0xFF }
        fetchCtrlIfaceStatus()
        fetchUartCtrlConfig()
        if let d = usb.getControlRequest(request: REQ_GET_CTRL_IFACE_STATUS, value: 0, index: 2, length: 8),
           let status = CtrlIfaceStatus.fromData(d) {
            return status.uartLastStatus
        }
        return 0xFF
    }

    /// Apply and persist the I2C target control-interface config.  Same deferred
    /// OUT-then-readback flow as `setUartCtrlConfig`; returns the I2C last-status
    /// byte from REQ_GET_CTRL_IFACE_STATUS.  USB-only; call off the main thread.
    @discardableResult
    func setI2cCtrlConfig(_ config: I2cCtrlConfig) -> UInt8 {
        let generation = usb.generation
        usb.sendControlRequest(request: REQ_SET_I2C_CONFIG, value: 0, index: 2, data: config.toData())
        Thread.sleep(forTimeInterval: 0.25)
        // Same device-scoping as setUartCtrlConfig.
        guard usb.generation == generation else { return 0xFF }
        fetchCtrlIfaceStatus()
        fetchI2cCtrlConfig()
        if let d = usb.getControlRequest(request: REQ_GET_CTRL_IFACE_STATUS, value: 0, index: 2, length: 8),
           let status = CtrlIfaceStatus.fromData(d) {
            return status.i2cLastStatus
        }
        return 0xFF
    }

    // MARK: - Control Surfaces

    /// Enumerate Control Surfaces capabilities + live state at connect.  The
    /// caps header (REQ_GET_CS_CAPS, wValue=0xFFFF) doubles as the feature
    /// probe: older firmware STALLs it and the Settings page hides itself.  On
    /// success we cache the type table, every per-noun descriptor, all live
    /// bindings, and the status packet, so the picker UI is built entirely from
    /// device-served tables (spec §4/§8.1).
    func fetchControlSurfaces() {
        guard let h = usb.getControlRequest(request: REQ_GET_CS_CAPS, value: CS_CAPS_ALL, index: 2, length: 40),
              let caps = CsCapsHeader.fromData(h) else {
            DispatchQueue.main.async { self.controlSurfacesSupported = false }
            return
        }
        // Per-noun descriptors (kind, enum count, unit-encoded range, unit,
        // target addressing, accepted actions).
        var nouns: [CsNounDesc] = []
        for n in 0..<Int(caps.nounCount) {
            guard let d = usb.getControlRequest(request: REQ_GET_CS_CAPS, value: UInt16(n), index: 2, length: 12),
                  let desc = CsNounDesc.fromData(d) else { continue }
            nouns.append(desc)
        }
        DispatchQueue.main.async {
            self.controlSurfacesSupported = true
            self.csCaps = caps
            self.csNounDescs = nouns
        }
        fetchCsStatus()
        for slot in 0..<CS_MAX_BINDINGS {
            fetchCsBinding(slot: slot)
            fetchCsName(slot: slot)
        }
        // IR command sub-slots (only populated when a receiver is configured,
        // but always safe to read - an empty sub-slot reads back all-zero).
        if caps.maxIrCommands > 0 {
            for sub in 0..<min(Int(caps.maxIrCommands), CS_MAX_IR_COMMANDS) {
                fetchCsIrCommand(sub: sub)
            }
        }
        // Runs after every fetch above (all dispatch to main in FIFO order): if
        // the device is clean, snapshot the loaded config as the saved baseline
        // so csDirty can tell net-zero edits from real ones.
        DispatchQueue.main.async {
            if !self.csStatus.dirty { self.captureCsCleanSnapshot() }
        }
    }

    /// Read the live 24-byte binding for one slot into `csBindings[slot]`.
    func fetchCsBinding(slot: Int) {
        guard slot >= 0, slot < CS_MAX_BINDINGS,
              let d = usb.getControlRequest(request: REQ_GET_CS_BINDING, value: UInt16(slot), index: 2, length: 24),
              let bind = CsBinding.fromData(d) else { return }
        DispatchQueue.main.async {
            if slot < self.csBindings.count { self.csBindings[slot] = bind }
        }
    }

    /// Read the device-persistent name for one slot into `csNames[slot]`
    /// (spec §3.4).  Synchronous read of the directory RAM cache; always 32
    /// bytes, NUL-terminated.  Empty when the slot is unnamed.
    func fetchCsName(slot: Int) {
        guard slot >= 0, slot < CS_MAX_BINDINGS,
              let d = usb.getControlRequest(request: REQ_GET_CS_NAME, value: UInt16(slot), index: 2, length: UInt16(CS_NAME_LEN)) else { return }
        let name = String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
        DispatchQueue.main.async {
            if slot < self.csNames.count { self.csNames[slot] = name }
        }
    }

    /// Read one live 16-byte IR command sub-slot into `csIrCommands[sub]`.
    func fetchCsIrCommand(sub: Int) {
        guard sub >= 0, sub < CS_MAX_IR_COMMANDS,
              let d = usb.getControlRequest(request: REQ_GET_CS_IR_CMD, value: UInt16(sub), index: 2, length: 16),
              let cmd = IrCommand.fromData(d) else { return }
        DispatchQueue.main.async {
            if sub < self.csIrCommands.count { self.csIrCommands[sub] = cmd }
        }
    }

    /// Read the 32-byte status packet (last-apply outcome, dirty flag, active
    /// mask, per-slot health, IR tail).  Cheap enough to poll after a SET.
    func fetchCsStatus() {
        guard let d = usb.getControlRequest(request: REQ_GET_CS_STATUS, value: 0, index: 2, length: 32),
              let st = CsStatusPacket.fromData(d) else { return }
        DispatchQueue.main.async { self.csStatus = st }
    }

    /// Poll REQ_GET_CS_STATUS until a deferred SET/save/revert resolves, i.e.
    /// `lastSlot == expectedSlot` and `lastStatus != CS_STATUS_PENDING`, or the
    /// ~500 ms budget (25 x 20 ms) runs out.  Returns the final status code
    /// (0xFF if no readback ever succeeded).  USB-only; blocks - call off-main.
    private func pollCsDeferred(expectedSlot: UInt8) -> UInt8 {
        let generation = usb.generation
        var result: UInt8 = CS_STATUS_PENDING
        for _ in 0..<25 {
            Thread.sleep(forTimeInterval: 0.02)
            // Stop polling if a device switch lands mid-wait - the new
            // device's status says nothing about our deferred apply.
            guard usb.generation == generation else { return 0xFF }
            guard let d = usb.getControlRequest(request: REQ_GET_CS_STATUS, value: 0, index: 2, length: 32),
                  let st = CsStatusPacket.fromData(d) else { continue }
            if st.lastSlot == expectedSlot && st.lastStatus != CS_STATUS_PENDING {
                result = st.lastStatus
                break
            }
        }
        return result
    }

    /// Apply one Control Surface binding to `slot` (live-only preview; spec §3.2
    /// / §3.5).  SET (0x84) is an OUT transfer carrying the 24-byte binding; the
    /// firmware validates + applies it deferred on its main loop and marks the
    /// live config dirty on success - nothing reaches flash until `csSave()`.
    /// The outcome is not synchronous: we poll REQ_GET_CS_STATUS (0x87) until
    /// `lastSlot == slot` leaves CS_STATUS_PENDING, then refresh the live
    /// binding + status.  Returns the PIN_CONFIG_* / CS_STATUS_* result (0xFF if
    /// readback failed).  USB-only; must be called off the main thread (blocks).
    @discardableResult
    func setCsBinding(slot: Int, binding: CsBinding) -> UInt8 {
        usb.sendControlRequest(request: REQ_SET_CS_BINDING, value: UInt16(slot), index: 2, data: binding.toData())
        let result = pollCsDeferred(expectedSlot: UInt8(slot))
        fetchCsBinding(slot: slot)
        fetchCsStatus()
        return result
    }

    /// Set (or clear) a slot's name (spec §3.4).  SET (0x8B) is an OUT transfer
    /// applied deferred like a binding: it's a live-only preview that sets the
    /// device `dirty` flag, so the change takes effect immediately but only
    /// reaches flash on csSave() and is undone by csRevert().  Send a single NUL
    /// byte to clear.  Returns the PIN_CONFIG_* / CS_STATUS_* result.  USB-only;
    /// must be called off the main thread (blocks on the poll).
    @discardableResult
    func setCsName(slot: Int, name: String) -> UInt8 {
        // Truncate to 31 characters + implicit NUL (the firmware truncates too).
        var bytes = Array(name.utf8.prefix(CS_NAME_LEN - 1))
        if bytes.isEmpty { bytes = [0] }   // empty payload is INVALID_VALUE; one NUL clears
        usb.sendControlRequest(request: REQ_SET_CS_NAME, value: UInt16(slot), index: 2, data: Data(bytes))
        let result = pollCsDeferred(expectedSlot: UInt8(slot))
        fetchCsName(slot: slot)
        fetchCsStatus()
        return result
    }

    /// Apply one IR command sub-slot (live-only preview; spec §3.6).  SET (0x8D)
    /// carries the 16-byte IrCommand; the outcome is reported with
    /// `lastSlot == 0x80 | sub`.  Send an all-zero record to clear.  Returns the
    /// status code.  USB-only; must be called off the main thread (blocks).
    @discardableResult
    func setCsIrCommand(sub: Int, command: IrCommand) -> UInt8 {
        usb.sendControlRequest(request: REQ_SET_CS_IR_CMD, value: UInt16(sub), index: 2, data: command.toData())
        let result = pollCsDeferred(expectedSlot: CS_LAST_SLOT_IR_FLAG | UInt8(sub))
        fetchCsIrCommand(sub: sub)
        fetchCsStatus()
        return result
    }

    /// Persist the whole live Control Surfaces config (16 bindings + 8 IR
    /// commands) in one flash write and clear `dirty` (REQ_CS_SAVE, 0x9D; spec
    /// §3.5).  Deferred, reported with `lastSlot == 0xFF`.  Returns the status
    /// code.  USB-only; must be called off the main thread (blocks).
    @discardableResult
    func csSave() -> UInt8 {
        _ = usb.getControlRequest(request: REQ_CS_SAVE, value: 0, index: 2, length: 1)
        let result = pollCsDeferred(expectedSlot: CS_LAST_SLOT_SAVE)
        fetchCsStatus()
        // The live config is now the saved config: rebase the clean baseline so
        // subsequent net-zero churn doesn't re-strand the banner.
        if result == PIN_CONFIG_SUCCESS {
            DispatchQueue.main.async { self.captureCsCleanSnapshot() }
        }
        return result
    }

    /// Discard the live preview by reloading the stored config (REQ_CS_REVERT,
    /// 0x9E; spec §3.5), then clear `dirty`.  Deferred, reported with
    /// `lastSlot == 0xFF`.  Refreshes every binding + IR command afterward so
    /// the UI reflects the restored state.  Returns the status code.  USB-only;
    /// must be called off the main thread (blocks).
    @discardableResult
    func csRevert() -> UInt8 {
        _ = usb.getControlRequest(request: REQ_CS_REVERT, value: 0, index: 2, length: 1)
        let result = pollCsDeferred(expectedSlot: CS_LAST_SLOT_SAVE)
        for slot in 0..<CS_MAX_BINDINGS {
            fetchCsBinding(slot: slot)
            fetchCsName(slot: slot)   // revert restores the stored names too (spec 3.4)
        }
        for sub in 0..<CS_MAX_IR_COMMANDS { fetchCsIrCommand(sub: sub) }
        fetchCsStatus()
        // Live now mirrors flash again; rebase the clean baseline after the
        // re-fetches above land (FIFO on main).
        DispatchQueue.main.async { self.captureCsCleanSnapshot() }
        return result
    }

    /// Arm the IR learn listener (REQ_CS_IR_LEARN wValue=1; spec §3.6.1).  The
    /// device listens on the receiver for up to 10 s for the next cleanly
    /// decoded remote button.  Returns true on the acknowledgement byte; false
    /// if it STALLs (no live IR component -> CS_STATUS_NO_IR).  USB-only.
    @discardableResult
    func csIrLearnArm() -> Bool {
        usb.getControlRequest(request: REQ_CS_IR_LEARN, value: CS_IR_LEARN_ARM, index: 2, length: 1) != nil
    }

    /// Cancel an armed IR learn (REQ_CS_IR_LEARN wValue=0); state returns to idle.
    func csIrLearnCancel() {
        _ = usb.getControlRequest(request: REQ_CS_IR_LEARN, value: CS_IR_LEARN_CANCEL, index: 2, length: 1)
    }

    /// Read the current IR learn result (REQ_CS_IR_LEARN wValue=2 -> 8 bytes;
    /// spec §3.6.1): the state and, when done, the captured protocol + code.
    /// USB-only; safe to poll while armed.
    func csIrLearnRead() -> CsIrLearnResult? {
        guard let d = usb.getControlRequest(request: REQ_CS_IR_LEARN, value: CS_IR_LEARN_READ, index: 2, length: 8) else { return nil }
        return CsIrLearnResult.fromData(d)
    }

    // MARK: - Test Signal Generator

    /// Enumerate siggen capabilities + live state at connect.  The caps
    /// header (REQ_SIGGEN_GET_CAPS, wValue=0xFFFF) doubles as the feature
    /// probe: older firmware STALLs it and the Tools window shows its
    /// unsupported notice.  On success we cache every per-type descriptor
    /// (the authoritative parameter ranges/defaults, spec §3.4) plus the
    /// applied config and status, and seed the editing draft.
    func fetchSiggen() {
        guard let h = usb.getControlRequest(request: REQ_SIGGEN_GET_CAPS, value: SIGGEN_CAPS_HEADER, index: 2, length: 8),
              let caps = SiggenCapsHeader.fromData(h) else {
            DispatchQueue.main.async { self.siggenSupported = false }
            return
        }
        var descs: [SiggenTypeDesc] = []
        for t in 0..<Int(caps.typeCount) {
            guard let d = usb.getControlRequest(request: REQ_SIGGEN_GET_CAPS, value: UInt16(t), index: 2, length: 62),
                  let desc = SiggenTypeDesc.fromData(d) else { continue }
            descs.append(desc)
        }
        // The applied config: a zeroed struct (channelMask == 0) means
        // nothing was ever staged - keep the local draft in that case.
        let applied = usb.getControlRequest(request: REQ_SIGGEN_GET_CONFIG, value: 0, index: 2, length: 36)
            .flatMap(SiggenConfig.fromData)
        DispatchQueue.main.async {
            self.siggenSupported = true
            self.siggenCaps = caps
            self.siggenTypeDescs = descs
            if let cfg = applied, cfg.channelMask != 0 {
                self.siggenDraft = cfg
            } else {
                // Clamp the default draft mask to this platform's outputs.
                self.siggenDraft.channelMask &= caps.validChannelMask
                if self.siggenDraft.channelMask == 0 { self.siggenDraft.channelMask = 1 }
            }
        }
        fetchSiggenStatus()
    }

    /// Read the 16-byte live status (state, elapsed, cycles, sweep freq)
    /// into `siggenStatus`.  Cheap enough to poll while running.
    func fetchSiggenStatus() {
        guard let d = usb.getControlRequest(request: REQ_SIGGEN_GET_STATUS, value: 0, index: 2, length: 16),
              let st = SiggenStatus.fromData(d) else { return }
        DispatchQueue.main.async { self.siggenStatus = st }
    }

    /// Stage a config (OUT, 36 bytes).  Never auto-starts; if the generator
    /// is already running the firmware restarts it with a fade
    /// (stop_reason = RECONFIG), which is what makes live editing safe.
    func siggenSetConfig(_ cfg: SiggenConfig) {
        usb.sendControlRequest(request: REQ_SIGGEN_SET_CONFIG, value: 0, index: 2, data: cfg.toData())
    }

    /// Issue a parameterless transport action (write-as-read: an IN transfer
    /// carrying the action in wValue, acknowledged with one status byte).
    /// Returns false on STALL (unknown action, or START with no staged
    /// config).  Blocks; call off the main thread.
    @discardableResult
    func siggenControl(_ action: UInt16) -> Bool {
        guard let d = usb.getControlRequest(request: REQ_SIGGEN_CONTROL, value: action, index: 2, length: 1),
              d.first == 1 else { return false }
        return true
    }

    /// Stage `cfg` and start (or restart) the generator, then refresh the
    /// status.  The send is queued ahead of the control read on the USB
    /// serial queue, so ordering is guaranteed.  Blocks; call off main.
    func siggenStart(with cfg: SiggenConfig) {
        siggenSetConfig(cfg)
        siggenControl(SIGGEN_CTL_START)
        fetchSiggenStatus()
    }

    /// Stop the generator (faded by default, hard stop when `immediate`),
    /// then refresh the status.  Blocks; call off main.
    func siggenStop(immediate: Bool = false) {
        siggenControl(immediate ? SIGGEN_CTL_STOP_NOW : SIGGEN_CTL_STOP)
        fetchSiggenStatus()
    }

    /// Play the channel-ID ident tone on a single output (matrix output index
    /// 0..8) so a listener can physically locate it.  Stages a CHANNEL_ID
    /// config masked to just that output and starts it: the firmware's walk
    /// position latches to the lowest set mask bit, so it plays exactly
    /// (index + 1) pentatonic blips at that channel's pitch (spec §2.2).  Two
    /// passes then auto-complete to idle - brief but unmistakable.
    ///
    /// Transient, never persisted; leaves the Test Signals editing draft
    /// untouched (a running user signal is restarted as the ident and resumes
    /// only if the user restarts it).  No-op when the firmware has no
    /// generator.  Dispatches the blocking USB work off the caller's thread,
    /// so it is safe to invoke directly from a menu action on the main thread.
    func identifyOutput(_ outputIndex: Int) {
        guard siggenSupported, outputIndex >= 0, outputIndex < 16 else { return }
        let bit = UInt16(1) << UInt16(outputIndex)
        // Clamp to the platform's valid outputs (caps mask is authoritative);
        // fall back to the raw bit before the first caps fetch.
        let validMask = siggenCaps.validChannelMask != 0 ? siggenCaps.validChannelMask : bit
        let mask = bit & validMask
        guard mask != 0 else { return }
        let cfg = SiggenConfig(
            signalType: SIGGEN_CHANNEL_ID,
            channelMask: mask,
            levelDB: -12.0,        // spec §13.4 ident level; trim/volume still apply
            repeatCount: 2,        // two passes over the single channel, then idle
            p1: 120.0)             // 120 ms blips (CHANNEL_ID default)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.siggenStart(with: cfg)
        }
    }

    // MARK: - Bulk Parameter Transfer

    /// Fetches all DSP parameters in a single V16 (5864-byte) USB transfer.
    /// Parses the flat WireBulkParams structure (unified channel model: inputs
    /// 0..N-1, outputs follow) and updates all published properties.  Returns
    /// true on a valid V16 payload, false otherwise.
    @discardableResult
    func fetchAllParams(markDisconnectedOnFailure: Bool = true) -> Bool {
        guard let data = usb.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0, index: 2, length: BULK_PARAMS_SIZE) else {
            if markDisconnectedOnFailure {
                DispatchQueue.main.async { self.usb.isConnected = false }
            }
            return false
        }
        // V23 is all-or-nothing: only the full, current layout is accepted.
        // A short or wrong-version payload means incompatible firmware - the
        // device is still connected, so don't disconnect (avoids a reconnect
        // loop); just record the version so the UI can react.  Require the full
        // V23 size so the psybass section (offset 5876..5899) is always in range.
        guard data.count >= Int(BULK_PARAMS_SIZE), Int(data[0]) == WIRE_FORMAT_VERSION else {
            DispatchQueue.main.async { self.firmwareWireFormatVersion = Int(data.first ?? 0) }
            return false
        }

        // --- Header (offset 0, 16 bytes) ---
        let formatVersion = data[0]
        let platformId = data[1]
        let numCh = min(Int(data[2]), WIRE_MAX_CHANNELS)          // total channels (7 / 17)
        let numOutCh = min(Int(data[3]), 9)                       // output channels (5 / 9)
        let numInCh = max(min(Int(data[4]), MAX_MATRIX_INPUTS), BASE_MATRIX_INPUTS)  // input channels (2 / 8)
        let platform: String
        switch platformId {
        case 1:  platform = "RP2350"
        case 2:  platform = "STM32H723"
        default: platform = "RP2040"
        }

        // --- Global (offset 16) ---
        let preamp: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_GLOBAL_OFFSET, as: Float.self) }
        let bypassVal = data[BULK_GLOBAL_OFFSET + 4] != 0
        let loudnessEn = data[BULK_GLOBAL_OFFSET + 5] != 0
        let loudnessMask = UInt16(data[BULK_GLOBAL_OFFSET + 6]) | (UInt16(data[BULK_GLOBAL_OFFSET + 7]) << 8)
        let loudnessRef: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_GLOBAL_OFFSET + 8, as: Float.self) }
        let loudnessInt: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_GLOBAL_OFFSET + 12, as: Float.self) }

        // --- Crossfeed (offset 32) ---
        let cfEnabled = data[BULK_CROSSFEED_OFFSET] != 0
        let cfPreset = Int(data[BULK_CROSSFEED_OFFSET + 1])
        let cfITD = data[BULK_CROSSFEED_OFFSET + 2] != 0
        // Output-pair mask lives in the former reserved byte at offset 3 (V20+).
        let cfOutputMask = data[BULK_CROSSFEED_OFFSET + 3]
        let cfFreq: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_CROSSFEED_OFFSET + 4, as: Float.self) }
        let cfFeed: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_CROSSFEED_OFFSET + 8, as: Float.self) }

        // --- Delays (offset 64, float[17]) ---
        var delays = [Int: Float]()
        for i in 0..<numCh {
            delays[i] = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_DELAYS_OFFSET + i * 4, as: Float.self) }
        }

        // --- Matrix crosspoints (offset 132, crosspoints[8][9] inline) ---
        // Backing arrays are always MAX_MATRIX_INPUTS rows; rows beyond numInCh
        // stay disabled / 0 dB on stereo firmware.
        var routing = Array(repeating: Array(repeating: false, count: 9), count: MAX_MATRIX_INPUTS)
        var mxGain = Array(repeating: Array(repeating: Float(0.0), count: 9), count: MAX_MATRIX_INPUTS)
        var mxInvert = Array(repeating: Array(repeating: false, count: 9), count: MAX_MATRIX_INPUTS)
        for input in 0..<numInCh {
            for output in 0..<numOutCh {
                let base = BULK_CROSSPOINT_OFFSET + (input * 9 + output) * WIRE_CROSSPOINT_SIZE
                routing[input][output] = data[base] != 0
                mxInvert[input][output] = data[base + 1] != 0
                mxGain[input][output] = data.withUnsafeBytes { $0.load(fromByteOffset: base + 4, as: Float.self) }
            }
        }

        // --- Matrix outputs (offset 708, WireOutputChannel[9]) ---
        var outEnabled = Array(repeating: false, count: 9)
        var outMuted = Array(repeating: false, count: 9)
        var outGain = Array(repeating: Float(0.0), count: 9)
        var outDelay = Array(repeating: Float(0.0), count: 9)
        for output in 0..<numOutCh {
            let base = BULK_OUTPUTS_OFFSET + output * 12
            outEnabled[output] = data[base] != 0
            outMuted[output] = data[base + 1] != 0
            outGain[output] = data.withUnsafeBytes { $0.load(fromByteOffset: base + 4, as: Float.self) }
            outDelay[output] = data.withUnsafeBytes { $0.load(fromByteOffset: base + 8, as: Float.self) }
        }

        // --- Pin config (offset 816) ---
        let numPins = min(Int(data[BULK_PINS_OFFSET]), 5)
        var pins: [UInt8] = [6, 7, 8, 9, 10]  // defaults
        for i in 0..<numPins {
            pins[i] = data[BULK_PINS_OFFSET + 1 + i]
        }

        // --- EQ bands (offset 824, eq[17][12]) ---
        // WireBandParams layout: type(1) bypass(1) reserved(2) freq(4) q(4) gain_db(4)
        let bandsInFirmware = 12
        let bandsInApp = 10
        var channelFilters = [Int: [FilterParams]]()
        for ch in 0..<numCh {
            var bands = [FilterParams]()
            bands.reserveCapacity(bandsInApp)
            for band in 0..<bandsInApp {
                let base = BULK_EQ_OFFSET + (ch * bandsInFirmware + band) * WIRE_BAND_PARAMS_SIZE
                let typeByte = data[base]
                let bypassByte = data[base + 1]
                let freq: Float = data.withUnsafeBytes { $0.load(fromByteOffset: base + 4, as: Float.self) }
                let q: Float = data.withUnsafeBytes { $0.load(fromByteOffset: base + 8, as: Float.self) }
                let gain: Float = data.withUnsafeBytes { $0.load(fromByteOffset: base + 12, as: Float.self) }
                let type = FilterType(rawValue: Int(typeByte)) ?? .flat
                var fp = FilterParams(
                    type: type,
                    freq: freq,
                    q: q,
                    gain: gain,
                    bypass: bypassByte == 1
                )
                // Reserved bytes 2-3 carry qp_x512 for LT bands (V22+), zero
                // otherwise; little-endian u16.
                if type == .linkwitzTransform {
                    let qpRaw: UInt16 = data.withUnsafeBytes { $0.load(fromByteOffset: base + 2, as: UInt16.self) }
                    fp.qp = FilterParams.decodeQp(qpRaw)
                }
                bands.append(fp)
            }
            channelFilters[ch] = bands
        }

        // --- Channel names (offset 4088, names[17][32]) ---
        var names = [String](repeating: "", count: WIRE_MAX_CHANNELS)
        for ch in 0..<numCh {
            let base = BULK_CHANNEL_NAMES_OFFSET + ch * 32
            let end = min(base + 32, data.count)
            let slice = data[base..<end]
            if let nulIdx = slice.firstIndex(of: 0) {
                names[ch] = String(data: data[base..<nulIdx], encoding: .ascii) ?? ""
            } else {
                names[ch] = String(data: slice, encoding: .ascii) ?? ""
            }
        }

        // --- I2S Config (offset 4632) ---
        var slotTypes: [UInt8] = [0, 0, 0, 0]
        for i in 0..<4 { slotTypes[i] = data[BULK_I2S_OFFSET + i] }
        let bckPin = data[BULK_I2S_OFFSET + 4]
        let mckPinVal = data[BULK_I2S_OFFSET + 5]
        let mckEn = data[BULK_I2S_OFFSET + 6] != 0
        let mckMult = data[BULK_I2S_OFFSET + 7] == 1 ? 256 : 128
        // Clock-pin mode + slave pair claim former reserved bytes (+8/+9), wire
        // version unchanged (18).  clock_pin_mode_p1 is +1 encoded (0=absent on
        // firmware without the feature - the feature-detection signal); slave
        // BCK is a plain GPIO (0=absent → keep the live default).
        let clockPinModeP1 = data[BULK_I2S_OFFSET + 8]
        let bckPinSlaveRaw = data[BULK_I2S_OFFSET + 9]

        // --- Volume Leveller (offset 4648) ---
        let lvlEnabled = data[BULK_LEVELLER_OFFSET] != 0
        let lvlSpeed = Int(data[BULK_LEVELLER_OFFSET + 1])
        let lvlLookahead = data[BULK_LEVELLER_OFFSET + 2] != 0
        let lvlAmount: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_LEVELLER_OFFSET + 4, as: Float.self) }
        let lvlMaxGain: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_LEVELLER_OFFSET + 8, as: Float.self) }
        let lvlGateDB: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_LEVELLER_OFFSET + 12, as: Float.self) }
        let lvlDetectorMask = data[BULK_LEVELLER_OFFSET + 16]   // V18: bit k = input channel k feeds detector
        let lvlApplyMask = data[BULK_LEVELLER_OFFSET + 17]      // V18: bit k = gain applied to input channel k

        // --- Per-Input Preamp (offset 4664, preamp_db[8]) ---
        var preampAll = Array(repeating: Float(0.0), count: MAX_MATRIX_INPUTS)
        for ch in 0..<numInCh {
            preampAll[ch] = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_PREAMP_OFFSET + ch * 4, as: Float.self) }
        }

        // --- Master Volume (offset 4696) ---
        let masterVol: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_MASTER_VOLUME_OFFSET, as: Float.self) }

        // --- Input Config (offset 4712) ---
        let bulkInputSource = Int(data[BULK_INPUT_CONFIG_OFFSET])
        let bulkSpdifRxPin = data[BULK_INPUT_CONFIG_OFFSET + 1]
        let bulkI2SRxPin = data[BULK_INPUT_CONFIG_OFFSET + 2]   // pair 0
        let bulkI2SInputRateHz = i2sRateEnumToHz(data[BULK_INPUT_CONFIG_OFFSET + 3])
        // V16+ multichannel I2S: count at +4 (0 = absent), pairs 1..3 at +5..+7
        // (0 = unset → keep the live default).
        let bulkI2SInputChannels = Int(data[BULK_INPUT_CONFIG_OFFSET + 4])
        let bulkI2SRxPinsExt: [UInt8] = [data[BULK_INPUT_CONFIG_OFFSET + 5],
                                         data[BULK_INPUT_CONFIG_OFFSET + 6],
                                         data[BULK_INPUT_CONFIG_OFFSET + 7]]
        // Optional S/PDIF inputs 2/3/4: pins at +8/+9/+10 (0 = keep live), enable
        // mask "plus one" at +11 (0 = field absent; otherwise mask = enc-1,
        // bit0 = SPDIF2 .. bit2 = SPDIF4).  The +1 encoding lets old hosts push
        // zeros meaning "absent" rather than "disable them all".  V28 grew the
        // pin array from 2 to 3, which is what shifted this and the fields below.
        let bulkSpdifRxPinsExt: [UInt8] = [data[BULK_INPUT_CONFIG_OFFSET + 8],
                                           data[BULK_INPUT_CONFIG_OFFSET + 9],
                                           data[BULK_INPUT_CONFIG_OFFSET + 10]]
        let bulkSpdifEnabledExtP1 = data[BULK_INPUT_CONFIG_OFFSET + 11]
        // V21+ I2S clock mode at +12 (0=master, 1=slave).
        let bulkI2SClockMode = data[BULK_INPUT_I2S_CLOCK_MODE_OFFSET]
        // V24+ ADAT input at +13/+14/+15 (RP2350).  Pin: 0 = unset (0xFF never on
        // the wire).  Enable / clock mode are +1 encoded (0 = absent/keep live).
        let bulkAdatInputPinRaw = data[BULK_INPUT_ADAT_PIN_OFFSET]
        let bulkAdatInputPin: UInt8 = bulkAdatInputPinRaw == 0 ? ADAT_INPUT_PIN_UNSET : bulkAdatInputPinRaw
        let bulkAdatInputEnabledP1 = data[BULK_INPUT_ADAT_ENABLED_P1_OFFSET]
        let bulkAdatInputClockModeP1 = data[BULK_INPUT_ADAT_CLOCK_MODE_P1_OFFSET]


        // --- LG Sound Sync (offset 4728) — only `enabled` honoured on SET ---
        let bulkLgEnabled = data[BULK_LG_OFFSET] != 0

        // --- User Volume (offset 4744) ---
        let bulkUserVolume: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_USER_VOLUME_OFFSET, as: Float.self) }

        // --- DAC Hardware Mute (offset 4760, 16 bytes) ---
        let bulkDacHwMute = DacHwMuteConfig.fromData(data.subdata(in: BULK_DAC_HW_MUTE_OFFSET..<(BULK_DAC_HW_MUTE_OFFSET + 16))) ?? DacHwMuteConfig()

        // --- Crossover Config (offset 4776, crossovers[17][4]) ---
        // Input rows (ch < chOut1) come back zeroed; stored as FLAT and hidden.
        var bulkCrossovers = [Int: [FilterParams]]()
        for ch in 0..<numCh {
            var bands: [FilterParams] = []
            bands.reserveCapacity(WIRE_MAX_XOVER_BANDS)
            for band in 0..<WIRE_MAX_XOVER_BANDS {
                let base = BULK_CROSSOVER_OFFSET + (ch * WIRE_MAX_XOVER_BANDS + band) * WIRE_BAND_PARAMS_SIZE
                let typeByte = data[base]
                let bypassByte = data[base + 1]
                let freq: Float = data.withUnsafeBytes { $0.load(fromByteOffset: base + 4, as: Float.self) }
                let q: Float = data.withUnsafeBytes { $0.load(fromByteOffset: base + 8, as: Float.self) }
                let gain: Float = data.withUnsafeBytes { $0.load(fromByteOffset: base + 12, as: Float.self) }
                bands.append(FilterParams(
                    type: FilterType(rawValue: Int(typeByte)) ?? .flat,
                    freq: max(freq, 10),
                    q: q > 0 ? q : 0.707,
                    gain: gain,
                    bypass: bypassByte == 1
                ))
            }
            bulkCrossovers[ch] = bands
        }

        // --- ADAT bulk output config (offset 5864, WireAdatConfig) ---
        // Live config: enabled + data pin (pin 0 => platform default).  RP2040
        // reports zeros; ADAT support is gated on platform below.
        let bulkAdatEnabled = data[BULK_ADAT_OFFSET] != 0
        let bulkAdatPinRaw = data[BULK_ADAT_OFFSET + 1]
        let bulkAdatPin = bulkAdatPinRaw == 0 ? ADAT_PIN_DEFAULT : bulkAdatPinRaw

        // --- Psychoacoustic Bass (offset 5876, WirePsybassParams 24 bytes) ---
        let pbEnabled = data[BULK_PSYBASS_OFFSET] != 0
        let pbOutputMask = UInt16(data[BULK_PSYBASS_OFFSET + 2]) | (UInt16(data[BULK_PSYBASS_OFFSET + 3]) << 8)
        let pbCutoff: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_PSYBASS_OFFSET + 4, as: Float.self) }
        let pbHarmonics: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_PSYBASS_OFFSET + 8, as: Float.self) }
        let pbDrive: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_PSYBASS_OFFSET + 12, as: Float.self) }
        let pbCharacter: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_PSYBASS_OFFSET + 16, as: Float.self) }
        let pbOriginal: Float = data.withUnsafeBytes { $0.load(fromByteOffset: BULK_PSYBASS_OFFSET + 20, as: Float.self) }

        // --- Stereo Upmixer (offset 5900, WireUpmixParams 44 bytes) ---
        let umEnabled = data[BULK_UPMIX_OFFSET] != 0
        let umCenterMode = Int(data[BULK_UPMIX_OFFSET + 1])
        let umSurroundMode = Int(data[BULK_UPMIX_OFFSET + 2])
        let umPresence = Float(Int8(bitPattern: data[BULK_UPMIX_OFFSET + 3])) / 2.0  // presence_q1 -> dB
        func umF(_ off: Int) -> Float { data.withUnsafeBytes { $0.load(fromByteOffset: BULK_UPMIX_OFFSET + off, as: Float.self) } }
        let umStrength = umF(4), umWidth = umF(8), umThreshold = umF(12), umAttack = umF(16), umRelease = umF(20)
        let umDetHpf = umF(24), umSurDelay = umF(28), umSurHpf = umF(32), umSurLpf = umF(36), umDecorr = umF(40)

        // --- Apply all parsed values on main thread ---
        DispatchQueue.main.async {
            self.platformName = platform
            self.numInputChannels = numInCh
            _ = preamp  // legacy global preamp; per-input preamp is authoritative

            self.preampDB = preampAll
            self.masterVolumeDB = masterVol
            self.bypass = bypassVal
            self.loudnessEnabled = loudnessEn
            self.loudnessOutputMask = loudnessMask
            self.loudnessRefSPL = loudnessRef
            self.loudnessIntensity = loudnessInt

            self.crossfeedEnabled = cfEnabled
            self.crossfeedPreset = cfPreset
            self.crossfeedITD = cfITD
            self.crossfeedFreq = cfFreq
            self.crossfeedFeed = cfFeed
            self.crossfeedOutputMask = cfOutputMask

            self.psybassEnabled = pbEnabled
            self.psybassOutputMask = pbOutputMask
            self.psybassCutoffHz = pbCutoff
            self.psybassHarmonicsDB = pbHarmonics
            self.psybassDriveDB = pbDrive
            self.psybassCharacterPct = pbCharacter
            self.psybassOriginalDB = pbOriginal

            self.upmixEnabled = umEnabled
            self.upmixCenterMode = umCenterMode
            self.upmixSurroundMode = umSurroundMode
            self.upmixPresenceDB = umPresence
            self.upmixStrengthPct = umStrength
            self.upmixCenterWidthPct = umWidth
            self.upmixThresholdPct = umThreshold
            self.upmixAttackMs = umAttack
            self.upmixReleaseMs = umRelease
            self.upmixDetectorHpfHz = umDetHpf
            self.upmixSurroundDelayMs = umSurDelay
            self.upmixSurroundHpfHz = umSurHpf
            self.upmixSurroundLpfHz = umSurLpf
            self.upmixDecorrPct = umDecorr

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
            // Clock-pin mode: a nonzero +1-encoded value is the feature-detection
            // signal (older firmware leaves the reserved byte 0).  Slave BCK 0
            // means "unset"; keep the live default in that case.
            if clockPinModeP1 != 0 {
                self.i2sClockPinModeSupported = true
                self.i2sClockPinMode = clockPinModeP1 - 1
            }
            if bckPinSlaveRaw != 0 { self.i2sBckPinSlave = bckPinSlaveRaw }

            self.levellerEnabled = lvlEnabled
            self.levellerAmount = lvlAmount
            self.levellerSpeed = lvlSpeed
            self.levellerMaxGainDB = lvlMaxGain
            self.levellerLookahead = lvlLookahead
            self.levellerGateDB = lvlGateDB
            self.levellerDetectorMask = lvlDetectorMask
            self.levellerApplyMask = lvlApplyMask

            self.channelData = channelFilters
            self.channelNames = names

            self.inputSource = bulkInputSource
            self.inputSourceSupported = true
            self.spdifRxPin = bulkSpdifRxPin
            // Optional S/PDIF 2/3/4: a non-zero enable-mask+1 byte marks the
            // multiple-input feature present and carries the live enable state;
            // ext pins of 0 mean "absent, keep the live pin".  The count comes
            // from the 0xEF inventory (fetchSpdifInputConfig), which is the only
            // thing that knows how many inputs this firmware actually has; bulk
            // just fills in the state.  Assume the full count until it lands.
            if bulkSpdifEnabledExtP1 != 0 {
                self.multiSpdifSupported = true
                if self.spdifInputCount < 2 { self.spdifInputCount = SPDIF_RX_NUM_INPUTS }
                let mask = bulkSpdifEnabledExtP1 - 1
                for i in 0..<(SPDIF_RX_NUM_INPUTS - 1) {
                    self.spdifExtEnabled[i] = (mask & (1 << UInt8(i))) != 0
                    if bulkSpdifRxPinsExt[i] != 0 { self.spdifRxPinsExt[i] = bulkSpdifRxPinsExt[i] }
                }
            }
            self.i2sInputSupported = true
            self.i2sRxPins[0] = bulkI2SRxPin
            for pair in 1..<min(4, self.i2sRxPins.count) where bulkI2SRxPinsExt[pair - 1] != 0 {
                self.i2sRxPins[pair] = bulkI2SRxPinsExt[pair - 1]
            }
            if bulkI2SInputChannels != 0 { self.i2sInputChannels = bulkI2SInputChannels }
            self.i2sInputRateHz = bulkI2SInputRateHz
            // Clock mode: the bulk payload is V21 by definition (strict version
            // gate above), so the device supports the clock-slave feature.  The
            // richer live lock state arrives via fetchI2SClockMode/0x09.
            self.i2sClockModeSupported = true
            self.i2sClockMode = bulkI2SClockMode
            self.i2sSlaveStatus.clockMode = bulkI2SClockMode
            self.userVolumeDB = bulkUserVolume
            self.lgSoundSyncEnabled = bulkLgEnabled
            self.lgSoundSyncSupported = true
            self.dacHwMuteConfig = bulkDacHwMute
            self.dacHwMuteSupported = true

            // ADAT bulk output is RP2350-only (the engine is compiled out on
            // RP2040, which reports zeros here).  fetchAdatConfig() refines this
            // with live active/rate status right after the bulk fetch.
            self.adatSupported = (platform == "RP2350")
            self.adatEnabled = bulkAdatEnabled
            self.adatPin = bulkAdatPin
            self.adatStatus.enabled = bulkAdatEnabled
            self.adatStatus.pin = bulkAdatPin

            // ADAT input (V24+): same RP2350 gate as the bulk output.  The +1
            // encoded enable / clock-mode fields decode as absent (keep live) when
            // zero; fetchAdatInputConfig() refines this with the live lock status
            // right after the bulk fetch.
            self.adatInputSupported = (platform == "RP2350")
            self.adatInputPin = bulkAdatInputPin
            self.adatInputStatus.pin = bulkAdatInputPin
            if bulkAdatInputEnabledP1 != 0 {
                let en = bulkAdatInputEnabledP1 == 2
                self.adatInputEnabled = en
                self.adatInputStatus.enabled = en
            }
            if bulkAdatInputClockModeP1 != 0 {
                let mode = bulkAdatInputClockModeP1 == 2 ? ADAT_INPUT_CLOCK_MODE_SLAVE : ADAT_INPUT_CLOCK_MODE_MASTER
                self.adatInputClockMode = mode
                self.adatInputStatus.clockMode = mode
            }

            self.firmwareWireFormatVersion = Int(formatVersion)

            // V16 always carries crossover state (input rows zeroed); types use
            // the V13+ 32..63 numbering that matches FilterType.
            self.firmwareSupportsCrossover = true
            self.xoverData = bulkCrossovers

            // Refresh channel visibility now that platform/outputs are populated.
            // (chOut1 reflects the freshly-set platformName.)  Any dashboard
            // snapshot predates this channel set, so drop it - leaving a channel
            // page now re-derives the defaults instead of restoring stale pills.
            self.savedOverviewVisibility = nil
            if self.isOverviewMode {
                for i in 0..<self.chOut1 {
                    self.channelVisibility[i] = (i < self.effectiveInputChannels)
                }
                for outputIdx in 0..<numOutCh {
                    self.channelVisibility[self.eqChannel(forOutput: outputIdx)] = outEnabled[outputIdx]
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
        guard let data = usb.getControlRequest(request: REQ_PRESET_GET_DIR, value: 0, index: 2, length: 7),
              data.count >= 6 else { return 0 }
        let occupied = data.withUnsafeBytes { $0.load(as: UInt16.self) }
        let startupMode = Int(data[2])
        let defaultSlot = Int(data[3])
        let lastActive = data[4]
        // Byte [5] carries output_config_mode (0 = independent, 1 = with preset,
        // the repurposed former include_pins flag).  Anything other than 1
        // (including legacy 0) reads as independent.
        let outputConfigMode: Int = (data[5] == UInt8(OUTPUT_CONFIG_MODE_WITH_PRESET))
            ? OUTPUT_CONFIG_MODE_WITH_PRESET
            : OUTPUT_CONFIG_MODE_INDEPENDENT
        // Byte [6] carries master_volume_mode (0 = independent, 1 = with preset).
        // Older firmware that pre-dates the byte returns < 7 bytes; default to mode 0.
        let masterVolMode: Int = (data.count >= 7 && data[6] == UInt8(MASTER_VOLUME_MODE_WITH_PRESET))
            ? MASTER_VOLUME_MODE_WITH_PRESET
            : MASTER_VOLUME_MODE_INDEPENDENT
        DispatchQueue.main.async {
            self.presetOccupied = occupied
            self.presetStartupMode = startupMode
            self.presetDefaultSlot = defaultSlot
            self.activePresetSlot = Int(lastActive)
            self.presetOutputConfigMode = outputConfigMode
            self.presetMasterVolumeMode = masterVolMode
            // Ensure UI cannot show stale names for slots that are not occupied.
            for slot in 0..<10 where (occupied & UInt16(1 << slot)) == 0 {
                self.presetNames[slot] = ""
            }
        }
        return occupied
    }

    func fetchPresetName(slot: Int) {
        guard let data = usb.getControlRequest(request: REQ_PRESET_GET_NAME, value: UInt16(slot), index: 2, length: 32) else {
            DispatchQueue.main.async {
                self.presetNames[slot] = ""
            }
            return
        }
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

    /// Copy the current live DSP state into `destinationSlot` while leaving
    /// `sourceSlot` as the active preset.
    ///
    /// Mechanism:
    ///   1. Save live → destination.  Wait for the deferred firmware save to
    ///      finish (signaled by REQ_PRESET_GET_ACTIVE returning destinationSlot).
    ///   2. Re-save live → source.  Wait for that save to finish.
    ///
    /// The wait between the two saves is essential: REQ_PRESET_SAVE is
    /// deferred on the firmware (the USB handler queues a single pending
    /// slot and returns PRESET_OK immediately, with the actual flash work
    /// happening in the main loop).  Without the wait, the second save
    /// overwrites `pending_preset_save_slot` before the first one has been
    /// processed, so the first slot is never written — the user sees the
    /// destination slot getting a name (from setPresetName, which writes
    /// the directory directly) but factory-default parameters when loaded.
    ///
    /// Returns PRESET_OK on success, an error code on failure.
    @discardableResult
    func copyPreset(from sourceSlot: Int, to destinationSlot: Int) -> UInt8 {
        let generation = usb.generation
        let dstStatus = savePreset(slot: destinationSlot)
        guard dstStatus == PRESET_OK else { return dstStatus }
        guard waitForPresetActivation(slot: destinationSlot) else { return 0xFF }

        // A device switch during the deferred wait must not let the source
        // re-save (which also moves last_active) run against the new device.
        guard usb.generation == generation else { return 0xFF }

        let srcStatus = savePreset(slot: sourceSlot)
        guard srcStatus == PRESET_OK else { return srcStatus }
        _ = waitForPresetActivation(slot: sourceSlot)

        return PRESET_OK
    }

    @discardableResult
    func loadPreset(slot: Int) -> UInt8 {
        print("[PRESET] loadPreset(\(slot)) starting")
        guard let status = usb.getControlRequest(request: REQ_PRESET_LOAD, value: UInt16(slot), index: 2, length: 1)?.first else {
            // nil = USB request failed; empty Data = device returned no status
            // byte (e.g. it reset/disconnected mid-transfer).  Treat both as a
            // failure rather than indexing [0] on an empty buffer (which traps).
            print("[PRESET] loadPreset(\(slot)) USB request failed (nil/empty)")
            return 0xFF
        }
        print("[PRESET] loadPreset(\(slot)) device status=\(status)")
        if status == PRESET_OK {
            // Publish the new active slot BEFORE the bulk refresh so the UI
            // converges quickly and the NSPopUpButton's native click-set
            // selection state reconciles with @Binding's view of truth.
            //
            // Why this matters: when the user picks a slot from the preset
            // popup, NSPopUpButton immediately sets .state=.on on the clicked
            // NSMenuItem (native click handling).  If activePresetSlot never
            // follows, the next BorderlessPopUpButton.updateNSView call
            // (triggered by any @Published poll update) will call
            // selectItem(withTag:) with the STALE activePresetSlot — which,
            // depending on NSPopUpButton's internal selectedItem-pointer
            // state vs. the NSMenuItem .state fields, can leave a checkmark
            // on BOTH the old and new slots until something else resyncs.
            // Mirroring savePreset's behavior (Commands.swift:~1144) keeps
            // the invariant "on PRESET_OK, activePresetSlot reflects the
            // slot the device is now on" uniform across both ops.
            DispatchQueue.main.async {
                self.activePresetSlot = slot
            }
            Thread.sleep(forTimeInterval: 0.1)
            fetchAllParams()
            // Rebase the unsaved-changes baseline to the just-loaded slot.
            // Without this, savedSnapshot still reflects whatever slot was
            // active before this load, and hasUnsavedChanges will spuriously
            // report differences (firing the "save changes?" dialog on the
            // very next preset switch).  Queued AFTER fetchAllParams so that
            // all of fetchAllParams's main.async writes have settled by the
            // time captureSnapshot() runs — FIFO ordering on the main queue
            // guarantees this.
            DispatchQueue.main.async {
                self.updateSavedSnapshot()
            }
        }
        return status
    }

    private func waitForPresetActivation(slot: Int, timeout: TimeInterval = 1.5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = usb.getControlRequest(request: REQ_PRESET_GET_ACTIVE, value: 0, index: 2, length: 1),
               data.count >= 1,
               Int(data[0]) == slot {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private func refreshAfterPresetLoad(timeout: TimeInterval = 1.5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fetchAllParams(markDisconnectedOnFailure: false) {
                _ = fetchPresetDirectory()
                fetchPresetActive()
                return true
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return false
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

    /// Poll REQ_PRESET_GET_DIR until the firmware has actually finished
    /// processing a deferred delete for `slot` (slot_occupied bit cleared).
    ///
    /// Like preset save, REQ_PRESET_DELETE is deferred — the USB handler sets
    /// `preset_delete_mask |= bit(slot)` and returns PRESET_OK immediately,
    /// while the actual flash erase + directory flush happens in the main
    /// loop.  Callers that need to read post-delete directory state (e.g.,
    /// to refresh `presetOccupied` / `presetNames`) must wait for the bit
    /// to clear, otherwise they'll race the deferred work and overwrite
    /// their optimistic local state with the firmware's stale value.
    ///
    /// Returns true on observed completion, false on timeout (default 1.5 s
    /// of polling at 20 ms intervals).
    @discardableResult
    func waitForPresetDeletion(slot: Int, timeout: TimeInterval = 1.5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = usb.getControlRequest(request: REQ_PRESET_GET_DIR, value: 0, index: 2, length: 7),
               data.count >= 2 {
                let occupied = UInt16(data[0]) | (UInt16(data[1]) << 8)
                if (occupied & UInt16(1 << slot)) == 0 {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
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
        DispatchQueue.main.async {
            self.presetStartupMode = mode
            self.presetDefaultSlot = defaultSlot
        }
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

    // MARK: - Output Config Mode (preset directory flag)

    /// Set output-config persistence mode (the repurposed include-pins flag).
    /// Pass `OUTPUT_CONFIG_MODE_WITH_PRESET` (1, default) to make the whole IO
    /// block — pins, output types, I2S MCK/BCK, and the S/PDIF RX pin — part of
    /// each preset, or `OUTPUT_CONFIG_MODE_INDEPENDENT` (0) for device-global
    /// wiring that's stored in the directory and applied at boot.
    func setOutputConfigMode(_ mode: Int) {
        let clamped = UInt8(max(0, min(1, mode)))
        let normalized = (Int(clamped) == OUTPUT_CONFIG_MODE_WITH_PRESET) ? OUTPUT_CONFIG_MODE_WITH_PRESET
                                                                          : OUTPUT_CONFIG_MODE_INDEPENDENT
        DispatchQueue.main.async { self.presetOutputConfigMode = normalized }
        usb.sendControlRequest(request: REQ_SET_OUTPUT_CONFIG_MODE, value: 0, index: 2, data: Data([clamped]))
    }

    func fetchOutputConfigMode() {
        guard let data = usb.getControlRequest(request: REQ_GET_OUTPUT_CONFIG_MODE, value: 0, index: 2, length: 1) else { return }
        let val = Int(data[0])
        DispatchQueue.main.async {
            self.presetOutputConfigMode = (val == OUTPUT_CONFIG_MODE_WITH_PRESET) ? OUTPUT_CONFIG_MODE_WITH_PRESET
                                                                                  : OUTPUT_CONFIG_MODE_INDEPENDENT
        }
    }

    /// Persist the current live output configuration into the directory's
    /// independent storage so it survives a reboot. Relevant in
    /// `OUTPUT_CONFIG_MODE_INDEPENDENT`, where per-field edits (pins, output
    /// types, I2S clocks, S/PDIF RX pin) apply live but only persist after an
    /// explicit save. IN-shaped action command: device responds with a 1-byte
    /// status (0 = PRESET_OK); the flash write is deferred on-device. Returns
    /// true on success, false if the device disconnected or the transfer failed.
    @discardableResult
    func saveOutputConfig() -> Bool {
        guard let data = usb.getControlRequest(request: REQ_SAVE_OUTPUT_CONFIG, value: 0, index: 2, length: 1) else {
            return false
        }
        return data.first == 0  // PRESET_OK
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

    // MARK: - Notification → State Mirroring

    /// Apply a v2 PARAM_CHANGED notification (already filtered to non-HOST
    /// sources) to local UI state.  Currently mirrors channel-name edits
    /// from BULK / PRESET / FACTORY / GPIO writes; extend as more fields
    /// need cross-source live updates.  Runs on the main thread.
    func applyNotifiedParamChange(offset: UInt16, size: UInt16, payload: Data) {
        let off = Int(offset)
        let sz = Int(size)

        // EQ band updates: 17 channels × 12 bands × 16 bytes at the V16 EQ
        // offset (824).  Firmware sends a full WireBandParams (16 bytes) on any
        // band change, including REQ_SET_BAND_BYPASS — see band_bypass_spec §6.4.
        // Decode and update channelData so other hosts' edits flow into our
        // UI without a re-poll.
        let eqBase = BULK_EQ_OFFSET
        let bandsInFirmware = 12
        let bandSize = WIRE_BAND_PARAMS_SIZE
        let channelCount = WIRE_MAX_CHANNELS
        if sz == bandSize,
           off >= eqBase,
           off < eqBase + channelCount * bandsInFirmware * bandSize,
           (off - eqBase) % bandSize == 0,
           payload.count >= bandSize {
            let flatIdx = (off - eqBase) / bandSize
            let ch = flatIdx / bandsInFirmware
            let band = flatIdx % bandsInFirmware
            // App tracks 10 bands per channel; firmware tracks 12 — ignore
            // updates for the two bands we don't surface.
            if band < 10, var bands = self.channelData[ch], band < bands.count {
                let typeByte = payload[0]
                let bypassByte = payload[1]
                let freq: Float = payload.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Float.self) }
                let q: Float = payload.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Float.self) }
                let gain: Float = payload.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Float.self) }
                let type = FilterType(rawValue: Int(typeByte)) ?? .flat
                var fp = bands[band]
                fp.type = type
                fp.freq = freq
                fp.q = q
                fp.gain = gain
                fp.bypass = bypassByte == 1
                // Reserved bytes 2-3 carry qp_x512 for LT bands (V22+).
                if type == .linkwitzTransform {
                    let qpRaw: UInt16 = payload.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) }
                    fp.qp = FilterParams.decodeQp(qpRaw)
                }
                if bands[band] != fp {
                    bands[band] = fp
                    self.channelData[ch] = bands
                    self.recomputeMagnitudes(for: ch)
                }
            }
            return
        }

        // Crossover band updates: 17 channels × 4 bands × 16 bytes at the V16
        // crossover offset (BULK_CROSSOVER_OFFSET = 4776).  Layout mirrors PEQ
        // but in its own WireCrossoverConfig section.  Input rows (ch < chOut1)
        // come through zeroed and we just store-but-don't-render them.
        let xoverBase = BULK_CROSSOVER_OFFSET
        let xoverChannelStride = WIRE_MAX_XOVER_BANDS * WIRE_BAND_PARAMS_SIZE
        if sz == WIRE_BAND_PARAMS_SIZE,
           off >= xoverBase,
           off < xoverBase + WIRE_MAX_CHANNELS * xoverChannelStride,
           (off - xoverBase) % WIRE_BAND_PARAMS_SIZE == 0,
           payload.count >= WIRE_BAND_PARAMS_SIZE {
            let flatIdx = (off - xoverBase) / WIRE_BAND_PARAMS_SIZE
            let ch = flatIdx / WIRE_MAX_XOVER_BANDS
            let localBand = flatIdx % WIRE_MAX_XOVER_BANDS
            if var bands = self.xoverData[ch], localBand < bands.count {
                let typeByte = payload[0]
                let bypassByte = payload[1]
                let freq: Float = payload.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Float.self) }
                let q: Float = payload.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Float.self) }
                let gain: Float = payload.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Float.self) }
                var fp = bands[localBand]
                fp.type = FilterType(rawValue: Int(typeByte)) ?? .flat
                fp.freq = freq
                fp.q = q
                fp.gain = gain
                fp.bypass = bypassByte == 1
                if bands[localBand] != fp {
                    bands[localBand] = fp
                    self.xoverData[ch] = bands
                    self.recomputeMagnitudes(for: ch)
                }
                self.firmwareSupportsCrossover = true
            }
            return
        }

        // Channel names: 17 channels × 32 bytes at the V16 offset (4088).
        let channelNamesBase = BULK_CHANNEL_NAMES_OFFSET
        let channelNameSize = 32
        if sz == channelNameSize,
           off >= channelNamesBase,
           off < channelNamesBase + channelCount * channelNameSize,
           (off - channelNamesBase) % channelNameSize == 0,
           payload.count >= channelNameSize {
            let ch = (off - channelNamesBase) / channelNameSize
            let nulIdx = payload.firstIndex(of: 0) ?? payload.endIndex
            let slice = payload[payload.startIndex..<nulIdx]
            let name = String(data: slice, encoding: .utf8)
                ?? String(data: slice, encoding: .ascii)
                ?? ""
            self.channelNames[ch] = name
            return
        }

        // dac_hw_mute (V16 offset 4760, full 16-byte struct).  Emitted by the
        // firmware on a successful REQ_SET_DAC_HW_MUTE_CONFIG or after a
        // factory-reset rewrite of the directory.  Mirror back so the UI
        // stays in sync with non-HOST writes.
        if off == BULK_DAC_HW_MUTE_OFFSET && sz == 16 && payload.count >= 16,
           let cfg = DacHwMuteConfig.fromData(payload) {
            self.dacHwMuteConfig = cfg
            self.dacHwMuteSupported = true
            return
        }

        // user_volume.user_volume_db (BULK_USER_VOLUME_OFFSET = 4744, 4 bytes float dB).
        // Fired on REQ_SET_USER_VOLUME (PARAM_SRC_HOST_SET — ignored
        // upstream as our own echo), bulk apply, and — crucially — on
        // OS volume-slider moves via UAC1, which the firmware reports
        // with PARAM_SRC_UAC1.  Those UAC1 events are how the in-app
        // slider stays synced with the OS volume control during USB
        // playback (UAC1 can't push the value the other direction, so
        // this notification is the only signal we get).  GPIO/INTERNAL
        // (hardware-knob / firmware) writes flow through here too.
        if off == BULK_USER_VOLUME_OFFSET && sz == 4 && payload.count >= 4 {
            let db: Float = payload.withUnsafeBytes { $0.load(as: Float.self) }
            if abs(self.userVolumeDB - db) > 0.01 {
                self.userVolumeDB = db
            }
            return
        }

        // lg_sound_sync.enabled (BULK_LG_OFFSET = 4728, 1 byte).  Fired by
        // lg_sound_sync_set_enabled() on the firmware side, and on bulk
        // apply.  Mirrors the user-controlled gate so external hosts /
        // preset loads flow into our Settings toggle without a re-poll.
        if off == BULK_LG_OFFSET && sz == 1 && payload.count >= 1 {
            let en = payload[0] != 0
            if self.lgSoundSyncEnabled != en {
                self.lgSoundSyncEnabled = en
            }
            self.lgSoundSyncSupported = true
            return
        }

        // input_config.input_source (BULK_INPUT_CONFIG_OFFSET, 1 byte).  Fired at the
        // tail of the firmware's deferred input-source switch handler —
        // i.e. after all per-source thaw/init work has run (including
        // the SPDIF→USB audio_set_volume() thaw).  Use this as the
        // "switch complete" trigger to refresh user volume so the
        // slider lands on the firmware's authoritative value, regardless
        // of which direction we switched.
        if off == BULK_INPUT_CONFIG_OFFSET && sz == 1 && payload.count >= 1 {
            let src = Int(payload[0])
            if self.inputSource != src {
                self.inputSource = src
            }
            let inputChannelCount = self.numInputChannels
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.fetchUserVolume()
                // The firmware relabels default input-channel names to follow the
                // new source (e.g. "SPDIF L/R"); custom names are preserved.
                // Refetch the input rows so the sidebar/matrix reflect the change.
                for ch in 0..<inputChannelCount {
                    self?.fetchChannelName(channel: ch)
                }
            }
            return
        }

        // input_config.i2s_rx_pin (+2, 1 byte) — pair 0 data pin.
        // Fires when 0xF1 (pair 0) succeeds, bulk apply, or a preset load.
        if off == BULK_INPUT_CONFIG_OFFSET + 2 && sz == 1 && payload.count >= 1 {
            self.i2sInputSupported = true
            self.i2sRxPins[0] = payload[0]
            return
        }

        // input_config.i2s_input_rate (+3, 1 byte, enum 0/1/2) —
        // fires when 0xED accepts a rate.
        if off == BULK_INPUT_CONFIG_OFFSET + 3 && sz == 1 && payload.count >= 1 {
            self.i2sInputSupported = true
            self.i2sInputRateHz = i2sRateEnumToHz(payload[0])
            return
        }

        // input_config.i2s_input_channels (offset 4716, 1 byte: 2/4/6/8) —
        // fires when 0xF3 changes the active I2S channel count.
        if off == BULK_INPUT_CONFIG_OFFSET + 4 && sz == 1 && payload.count >= 1, payload[0] != 0 {
            self.i2sInputSupported = true
            self.i2sInputChannels = Int(payload[0])
            return
        }

        // input_config.i2s_rx_pin_ext[0..2] (offsets 4717..4719) — data pins for
        // stereo pairs 1..3.  Fires when 0xF1 (pair >= 1) succeeds, bulk, preset.
        if off >= BULK_INPUT_CONFIG_OFFSET + 5 && off <= BULK_INPUT_CONFIG_OFFSET + 7 && sz == 1 && payload.count >= 1 {
            let pair = off - (BULK_INPUT_CONFIG_OFFSET + 5) + 1   // 1..3
            self.i2sInputSupported = true
            if self.i2sRxPins.indices.contains(pair) { self.i2sRxPins[pair] = payload[0] }
            return
        }

        // input_config.i2s_clock_mode (offset 4727, 1 byte: 0=master/1=slave).
        // Fired at the tail of the firmware's deferred mode-change transition
        // (not at SET time) - i.e. the "mode is now live" confirmation.  A
        // NOTIFY 0x09 with the fresh lock state follows; refresh the full status.
        if off == BULK_INPUT_I2S_CLOCK_MODE_OFFSET && sz == 1 && payload.count >= 1 {
            let mode = payload[0]
            self.i2sClockModeSupported = true
            self.i2sInputSupported = true
            if self.i2sClockMode != mode { self.i2sClockMode = mode }
            self.i2sSlaveStatus.clockMode = mode
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.fetchI2SSlaveStatus()
            }
            return
        }

        // input_config.adat_input_pin (offset 4728, 1 byte: raw GPIO, 0 = unset).
        // Fires when 0x6A re-routes the RX pin, on bulk apply, and on preset load.
        if off == BULK_INPUT_ADAT_PIN_OFFSET && sz == 1 && payload.count >= 1 {
            let pin = payload[0] == 0 ? ADAT_INPUT_PIN_UNSET : payload[0]
            if self.adatInputPin != pin { self.adatInputPin = pin }
            self.adatInputStatus.pin = pin
            return
        }

        // input_config.adat_input_enabled_p1 (offset 4729, +1 encoded: 1=disabled,
        // 2=enabled).  Fires when 0x68 toggles the input, on bulk, and on preset.
        if off == BULK_INPUT_ADAT_ENABLED_P1_OFFSET && sz == 1 && payload.count >= 1, payload[0] != 0 {
            let en = payload[0] == 2
            if self.adatInputEnabled != en { self.adatInputEnabled = en }
            self.adatInputStatus.enabled = en
            return
        }

        // input_config.adat_clock_mode_p1 (offset 4730, +1 encoded: 1=master,
        // 2=slave).  Fired at the tail of the firmware's deferred clock-mode apply
        // (the "mode is now live" confirmation); a NOTIFY 0x0B follows, so refresh
        // the full status.
        if off == BULK_INPUT_ADAT_CLOCK_MODE_P1_OFFSET && sz == 1 && payload.count >= 1, payload[0] != 0 {
            let mode = payload[0] == 2 ? ADAT_INPUT_CLOCK_MODE_SLAVE : ADAT_INPUT_CLOCK_MODE_MASTER
            if self.adatInputClockMode != mode { self.adatInputClockMode = mode }
            self.adatInputStatus.clockMode = mode
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.fetchAdatInputStatus()
            }
            return
        }

        // i2s_config.bck_pin (BULK_I2S_OFFSET + 4, 1 byte).  Fired when 0xC2
        // role 0 re-routes the master/unified BCK pair, on bulk, and on preset.
        if off == BULK_I2S_OFFSET + 4 && sz == 1 && payload.count >= 1 {
            if self.i2sBckPin != payload[0] { self.i2sBckPin = payload[0] }
            return
        }

        // i2s_config.clock_pin_mode_p1 (BULK_I2S_CLOCK_PIN_MODE_OFFSET, 1 byte,
        // +1 encoded: 1=unified, 2=split).  Fired when 0xFE applies, on bulk, and
        // on preset load.  0xFE applies synchronously so this is a confirmation.
        if off == BULK_I2S_CLOCK_PIN_MODE_OFFSET && sz == 1 && payload.count >= 1, payload[0] != 0 {
            let mode = payload[0] - 1
            self.i2sClockPinModeSupported = true
            if self.i2sClockPinMode != mode { self.i2sClockPinMode = mode }
            return
        }

        // i2s_config.bck_pin_slave (BULK_I2S_BCK_PIN_SLAVE_OFFSET, 1 byte, plain
        // GPIO).  Fired when 0xC2 role 1 moves the slave pair, on bulk, preset.
        if off == BULK_I2S_BCK_PIN_SLAVE_OFFSET && sz == 1 && payload.count >= 1, payload[0] != 0 {
            if self.i2sBckPinSlave != payload[0] { self.i2sBckPinSlave = payload[0] }
            return
        }

        // adat_config.enabled (BULK_ADAT_OFFSET, 1 byte).  Fired when 0xCA
        // toggles the stream, on bulk apply, and on preset load.  The richer
        // live state (active / rate_ok) arrives via NOTIFY_EVT_ADAT_STATE and
        // fetchAdatStatus(); here we just mirror the persisted enable intent.
        if off == BULK_ADAT_OFFSET && sz == 1 && payload.count >= 1 {
            let en = payload[0] != 0
            if self.adatEnabled != en { self.adatEnabled = en }
            self.adatStatus.enabled = en
            return
        }

        // adat_config.pin (BULK_ADAT_OFFSET + 1, 1 byte).  Fired when 0xCC
        // re-routes the data pin, on bulk apply, and on preset load.  A stored
        // 0 means "unset — use the platform default".
        if off == BULK_ADAT_OFFSET + 1 && sz == 1 && payload.count >= 1 {
            let pin = payload[0] == 0 ? ADAT_PIN_DEFAULT : payload[0]
            if self.adatPin != pin { self.adatPin = pin }
            self.adatStatus.pin = pin
            return
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
        // "Revert to Saved" reloads the active preset slot from flash,
        // discarding unsaved live edits.  Route it through the DEFERRED
        // REQ_PRESET_LOAD path (loadPreset) rather than a synchronous load: a
        // synchronous flash read + state apply inside the device's USB-IRQ
        // handler WITHOUT stopping the SPDIF receiver crashes the device when
        // SPDIF is the active input (its decode-timeout alarm tears down
        // DMA/PIO during the ~45 ms flash blackout).  loadPreset defers
        // on-device — it stops RX, fences Core 1, and resyncs the pipeline — so
        // it is safe on every input source, and it also refreshes the UI and
        // rebaselines the unsaved-changes snapshot.  (The legacy synchronous
        // load opcode 0x52 has since been repurposed as REQ_SAVE_OUTPUT_CONFIG.)
        let status = loadPreset(slot: activePresetSlot)
        // Map preset status codes onto the FLASH_* codes the caller expects.
        switch status {
        case PRESET_OK:      return FLASH_OK
        case PRESET_ERR_CRC: return FLASH_ERR_CRC
        default:             return FLASH_ERR_WRITE   // invalid slot / USB failure (0xFF)
        }
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

import Foundation
import Combine
import SwiftUI

extension DSPViewModel {

    // --- USB Commands ---

    func fetchAll() {
        // Fetch platform/version first so capability gates (notch filter,
        // per-band bypass, etc.) are populated before the UI reads them.
        _ = fetchPlatform()

        guard fetchAllParams() else { return }

        fetchInputSource()
        fetchCore1Mode()
        fetchSampleRate()
        fetchUserVolume()
        fetchLgSoundSyncEnabled()
        fetchDacHwMuteConfig()

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
        if preampLinked {
            let data = Data(bytes: &val, count: 4)
            usb.sendControlRequest(request: REQ_SET_PREAMP, value: 0, index: 0, data: data)
        } else {
            let data = Data(bytes: &val, count: 4)
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
        let data = NSMutableData()
        var ch8 = UInt8(ch); data.append(&ch8, length: 1)
        var b8 = UInt8(band); data.append(&b8, length: 1)
        var t8 = UInt8(p.type.rawValue); data.append(&t8, length: 1)
        var bp = UInt8(p.bypass ? 1 : 0); data.append(&bp, length: 1)
        var f32 = p.freq; data.append(&f32, length: 4)
        var q32 = p.q; data.append(&q32, length: 4)
        var g32 = p.gain; data.append(&g32, length: 4)

        usb.sendControlRequest(request: REQ_SET_EQ_PARAM, value: 0, index: 0, data: data as Data)
        recomputeMagnitudes(for: ch)
    }
    
    func fetchFilter(ch: Int, band: Int) {
        // REQ_GET_EQ_PARAM wValue: bits[15:8]=channel, bits[7:3]=band (5 bits,
        // 0..31), bits[2:0]=param (0=type, 1=freq, 2=Q, 3=gain, 4=bypass).  The
        // band field is 5 bits (not the original 4) so crossover bands at
        // 20..23 stay addressable after the reserved PEQ gap widened to 10..19.
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

        let newParams = FilterParams(
            type: FilterType(rawValue: Int(typeRaw)) ?? .flat,
            freq: freq,
            q: q,
            gain: gain,
            bypass: bypass
        )

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
        guard ch >= 2,
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
        guard ch >= 2,
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
        guard ch >= 2 else { return }
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
        if preampLinked {
            self.preampDB[1 - channel] = val
            let data = Data(bytes: &val, count: 4)
            usb.sendControlRequest(request: REQ_SET_PREAMP, value: 0, index: 0, data: data)
        } else {
            let data = Data(bytes: &val, count: 4)
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
    /// field at bulk offset 2912 — applyNotifiedParamChange mirrors that back
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
            fetchSpdifRxPin()
            fetchI2SInputConfig()
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

    func fetchSpdifRxPin() {
        if let data = usb.getControlRequest(request: REQ_GET_SPDIF_RX_PIN, value: 0, index: 2, length: 1),
           data.count >= 1 {
            DispatchQueue.main.async { self.spdifRxPin = data[0] }
        }
    }

    /// Set the GPIO pin used for the S/PDIF receiver. Requires SPDIF input to be inactive.
    /// Single IN transfer: wValue = pin. Returns firmware status code.
    @discardableResult
    func setSpdifRxPin(_ pin: UInt8) -> UInt8 {
        if let d = usb.getControlRequest(request: REQ_SET_SPDIF_RX_PIN, value: UInt16(pin), index: 2, length: 1) {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async { self.spdifRxPin = pin }
            }
            return status
        }
        return 0xFF
    }

    // MARK: - I2S Input Commands

    /// Probes I2S input support (firmware V12+).  REQ_GET_I2S_RX_PIN STALLs on
    /// older firmware; on success we also read the selected input rate.
    func fetchI2SInputConfig() {
        guard let data = usb.getControlRequest(request: REQ_GET_I2S_RX_PIN, value: 0, index: 2, length: 1),
              data.count >= 1 else {
            DispatchQueue.main.async { self.i2sInputSupported = false }
            return
        }
        let pin = data[0]
        DispatchQueue.main.async {
            self.i2sInputSupported = true
            self.i2sRxPin = pin
        }
        fetchInputRate()
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

    /// Sets the GPIO data pin used for the I2S receiver.  Single IN transfer:
    /// wValue = pin.  Returns the firmware PIN_CONFIG_* status code.  Hot-swap
    /// is supported (input restarts on the new pin if I2S is active).
    @discardableResult
    func setI2SRxPin(_ pin: UInt8) -> UInt8 {
        if let d = usb.getControlRequest(request: REQ_SET_I2S_RX_PIN, value: UInt16(pin), index: 2, length: 1),
           d.count >= 1 {
            let status = d[0]
            if status == PIN_CONFIG_SUCCESS {
                DispatchQueue.main.async { self.i2sRxPin = pin }
            }
            return status
        }
        return 0xFF
    }

    // MARK: - Bulk Parameter Transfer

    /// Fetches all DSP parameters in a single 2480-byte USB transfer.
    /// Parses the WireBulkParams structure and updates all published properties.
    /// Returns true if successful, false if the device is not connected.
    @discardableResult
    func fetchAllParams(markDisconnectedOnFailure: Bool = true) -> Bool {
        guard let data = usb.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0, index: 2, length: BULK_PARAMS_SIZE),
              data.count >= 2832 else {  // Accept V2 (2832) or later
            if markDisconnectedOnFailure {
                DispatchQueue.main.async { self.usb.isConnected = false }
            }
            return false
        }

        // --- Header (offset 0, 16 bytes) ---
        let formatVersion = data[0]
        let platformId = data[1]
        let numCh = Int(data[2])
        let numOutCh = Int(data[3])
        let platform: String
        switch platformId {
        case 1:  platform = "RP2350"
        case 2:  platform = "STM32H723"
        default: platform = "RP2040"
        }

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
        // WireBandParams layout: type(1) bypass(1) reserved(2) freq(4) q(4) gain_db(4)
        let bandsInFirmware = 12
        let bandsInApp = 10
        var channelFilters = [Int: [FilterParams]]()
        for ch in 0..<numCh {
            var bands = [FilterParams]()
            bands.reserveCapacity(bandsInApp)
            for band in 0..<bandsInApp {
                let base = 368 + (ch * bandsInFirmware + band) * 16
                let typeByte = data[base]
                let bypassByte = data[base + 1]
                let freq: Float = data.withUnsafeBytes { $0.load(fromByteOffset: base + 4, as: Float.self) }
                let q: Float = data.withUnsafeBytes { $0.load(fromByteOffset: base + 8, as: Float.self) }
                let gain: Float = data.withUnsafeBytes { $0.load(fromByteOffset: base + 12, as: Float.self) }
                bands.append(FilterParams(
                    type: FilterType(rawValue: Int(typeByte)) ?? .flat,
                    freq: freq,
                    q: q,
                    gain: gain,
                    bypass: bypassByte == 1
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
            mckMult = rawMult == 1 ? 256 : 128  // V5 encoding: 0 = 128x, 1 = 256x
        }

        // --- Volume Leveller (offset 2848, 16 bytes) --- V4 firmware only
        var lvlEnabled = false
        var lvlSpeed = 0
        var lvlLookahead = false
        var lvlAmount: Float = 100.0
        var lvlMaxGain: Float = 24.0
        var lvlGateDB: Float = -70.0

        if data.count >= 2864 {
            lvlEnabled = data[2848] != 0
            lvlSpeed = Int(data[2849])
            lvlLookahead = data[2850] != 0
            lvlAmount = data.withUnsafeBytes { $0.load(fromByteOffset: 2852, as: Float.self) }
            lvlMaxGain = data.withUnsafeBytes { $0.load(fromByteOffset: 2856, as: Float.self) }
            lvlGateDB = data.withUnsafeBytes { $0.load(fromByteOffset: 2860, as: Float.self) }
        }

        // --- Per-Channel Preamp (offset 2864, 16 bytes) --- V6 firmware only
        var preampCh0: Float = preamp  // fallback to global preamp
        var preampCh1: Float = preamp

        if formatVersion >= 6 && data.count >= 2872 {
            preampCh0 = data.withUnsafeBytes { $0.load(fromByteOffset: 2864, as: Float.self) }
            preampCh1 = data.withUnsafeBytes { $0.load(fromByteOffset: 2868, as: Float.self) }
        }

        // --- Master Volume (offset 2880, 16 bytes) --- V6 firmware only
        var masterVol: Float = 0.0

        if formatVersion >= 6 && data.count >= 2884 {
            masterVol = data.withUnsafeBytes { $0.load(fromByteOffset: 2880, as: Float.self) }
        }

        // --- Input Config (offset 2896, 16 bytes) --- V7 firmware only
        var bulkInputSource: Int? = nil
        var bulkSpdifRxPin: UInt8? = nil

        if formatVersion >= 7 && data.count >= 2912 {
            bulkInputSource = Int(data[2896])
            bulkSpdifRxPin = data[2897]
        }

        // I2S input fields claimed two previously-reserved bytes in V12.
        // byte 2898 = i2s_rx_pin, byte 2899 = i2s_input_rate (enum 0/1/2).
        var bulkI2SRxPin: UInt8? = nil
        var bulkI2SInputRateHz: UInt32? = nil
        if formatVersion >= 12 && data.count >= 2912 {
            bulkI2SRxPin = data[2898]
            bulkI2SInputRateHz = i2sRateEnumToHz(data[2899])
        }

        // --- LG Sound Sync (offset 2912, 16 bytes) --- V8 firmware only
        // Only `enabled` is honoured on bulk SET; present/volume/muted are
        // runtime telemetry, polled via REQ_GET_LG_SOUND_SYNC_STATUS by the
        // Stats window for live monitoring.
        var bulkLgEnabled: Bool? = nil
        if formatVersion >= 8 && data.count >= 2928 {
            bulkLgEnabled = data[2912] != 0
        }

        // --- User Volume (offset 2928, 16 bytes) --- V9 firmware only
        // Mirrors audio_state.volume — same field UAC1 host slider drives,
        // surfaced via REQ_SET_USER_VOLUME for non-USB modes.
        var bulkUserVolume: Float? = nil
        if formatVersion >= 9 && data.count >= 2944 {
            bulkUserVolume = data.withUnsafeBytes { $0.load(fromByteOffset: 2928, as: Float.self) }
        }

        // --- DAC Hardware Mute (offset 2944, 16 bytes) --- V10 firmware only
        // Board-level mute-pin config stored in the directory sector.
        var bulkDacHwMute: DacHwMuteConfig? = nil
        if formatVersion >= 10 && data.count >= 2960 {
            bulkDacHwMute = DacHwMuteConfig.fromData(data.subdata(in: 2944..<2960))
        }

        // --- Crossover Config (offset 2960, 704 bytes) --- V11 firmware only
        // WireCrossoverConfig: bands[11 channels][4 bands][16 bytes].  Master
        // rows (channels 0..1) come back zeroed and we mirror that into the
        // app's empty xoverData entries for those channels.  See
        // crossover_filters_spec.md §4.
        var bulkCrossovers: [Int: [FilterParams]]? = nil
        if formatVersion >= 11 && data.count >= BULK_PARAMS_V11_SIZE {
            var xovers = [Int: [FilterParams]]()
            for ch in 0..<numCh {
                var bands: [FilterParams] = []
                bands.reserveCapacity(WIRE_MAX_XOVER_BANDS)
                for band in 0..<WIRE_MAX_XOVER_BANDS {
                    let base = BULK_CROSSOVER_OFFSET
                            + (ch * WIRE_MAX_XOVER_BANDS + band) * WIRE_BAND_PARAMS_SIZE
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
                xovers[ch] = bands
            }
            bulkCrossovers = xovers
        }

        // --- Apply all parsed values on main thread ---
        DispatchQueue.main.async {
            self.platformName = platform

            self.preampDB = [preampCh0, preampCh1]
            self.masterVolumeDB = masterVol
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

            self.levellerEnabled = lvlEnabled
            self.levellerAmount = lvlAmount
            self.levellerSpeed = lvlSpeed
            self.levellerMaxGainDB = lvlMaxGain
            self.levellerLookahead = lvlLookahead
            self.levellerGateDB = lvlGateDB

            self.channelData = channelFilters
            self.channelNames = names

            if let src = bulkInputSource {
                self.inputSource = src
                self.inputSourceSupported = true
            }
            if let pin = bulkSpdifRxPin {
                self.spdifRxPin = pin
            }
            if let pin = bulkI2SRxPin {
                self.i2sInputSupported = true
                self.i2sRxPin = pin
            }
            if let rate = bulkI2SInputRateHz {
                self.i2sInputRateHz = rate
            }
            if let userVol = bulkUserVolume {
                self.userVolumeDB = userVol
            }
            if let lgEn = bulkLgEnabled {
                self.lgSoundSyncEnabled = lgEn
                self.lgSoundSyncSupported = true
            }
            if let cfg = bulkDacHwMute {
                self.dacHwMuteConfig = cfg
                self.dacHwMuteSupported = true
            }

            self.firmwareWireFormatVersion = Int(formatVersion)

            // Crossover types were renumbered to 32..63 in wire format V13.  A
            // V11/V12 firmware still returns a crossover payload but with the
            // old 8..39 numbering, which no longer matches FilterType - so only
            // expose crossover (and send the new type bytes) on V13+.
            if let xovers = bulkCrossovers, formatVersion >= 13 {
                self.firmwareSupportsCrossover = true
                // Replace the entire xoverData dictionary so deletions on the
                // wire propagate.  Master rows are stored too (they'll be all
                // zeros / FLAT) but the UI hides them.
                self.xoverData = xovers
            } else {
                self.firmwareSupportsCrossover = false
            }

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
        let dstStatus = savePreset(slot: destinationSlot)
        guard dstStatus == PRESET_OK else { return dstStatus }
        guard waitForPresetActivation(slot: destinationSlot) else { return 0xFF }

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

        // EQ band updates: 11 channels × 12 bands × 16 bytes at offset 368.
        // Firmware sends a full WireBandParams (16 bytes) on any band change,
        // including REQ_SET_BAND_BYPASS — see band_bypass_spec §6.4.
        // Decode and update channelData so other hosts' edits flow into our
        // UI without a re-poll.
        let eqBase = 368
        let bandsInFirmware = 12
        let bandSize = 16
        let channelCount = 11
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
                var fp = bands[band]
                fp.type = FilterType(rawValue: Int(typeByte)) ?? .flat
                fp.freq = freq
                fp.q = q
                fp.gain = gain
                fp.bypass = bypassByte == 1
                if bands[band] != fp {
                    bands[band] = fp
                    self.channelData[ch] = bands
                    self.recomputeMagnitudes(for: ch)
                }
            }
            return
        }

        // Crossover band updates: 11 channels × 4 bands × 16 bytes at the
        // V11 crossover offset (2960).  Layout mirrors PEQ but in its own
        // WireCrossoverConfig section.  Master rows (channels 0..1) come
        // through zeroed and we just store-but-don't-render them.
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

        // Channel names: 11 channels × 32 bytes at offset 2480.
        let channelNamesBase = 2480
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

        // dac_hw_mute (offset 2944, full 16-byte struct).  Emitted by the
        // firmware on a successful REQ_SET_DAC_HW_MUTE_CONFIG or after a
        // factory-reset rewrite of the directory.  Mirror back so the UI
        // stays in sync with non-HOST writes.
        if off == 2944 && sz == 16 && payload.count >= 16,
           let cfg = DacHwMuteConfig.fromData(payload) {
            self.dacHwMuteConfig = cfg
            self.dacHwMuteSupported = true
            return
        }

        // user_volume.user_volume_db (offset 2928, 4 bytes float dB).
        // Fired on REQ_SET_USER_VOLUME (PARAM_SRC_HOST_SET — ignored
        // upstream as our own echo), bulk apply, and — crucially — on
        // OS volume-slider moves via UAC1, which the firmware reports
        // with PARAM_SRC_UAC1.  Those UAC1 events are how the in-app
        // slider stays synced with the OS volume control during USB
        // playback (UAC1 can't push the value the other direction, so
        // this notification is the only signal we get).  GPIO/INTERNAL
        // (hardware-knob / firmware) writes flow through here too.
        if off == 2928 && sz == 4 && payload.count >= 4 {
            let db: Float = payload.withUnsafeBytes { $0.load(as: Float.self) }
            if abs(self.userVolumeDB - db) > 0.01 {
                self.userVolumeDB = db
            }
            return
        }

        // lg_sound_sync.enabled (offset 2912, 1 byte).  Fired by
        // lg_sound_sync_set_enabled() on the firmware side, and on bulk
        // apply.  Mirrors the user-controlled gate so external hosts /
        // preset loads flow into our Settings toggle without a re-poll.
        if off == 2912 && sz == 1 && payload.count >= 1 {
            let en = payload[0] != 0
            if self.lgSoundSyncEnabled != en {
                self.lgSoundSyncEnabled = en
            }
            self.lgSoundSyncSupported = true
            return
        }

        // input_config.input_source (offset 2896, 1 byte).  Fired at the
        // tail of the firmware's deferred input-source switch handler —
        // i.e. after all per-source thaw/init work has run (including
        // the SPDIF→USB audio_set_volume() thaw).  Use this as the
        // "switch complete" trigger to refresh user volume so the
        // slider lands on the firmware's authoritative value, regardless
        // of which direction we switched.
        if off == 2896 && sz == 1 && payload.count >= 1 {
            let src = Int(payload[0])
            if self.inputSource != src {
                self.inputSource = src
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.fetchUserVolume()
            }
            return
        }

        // input_config.i2s_rx_pin (offset 2898, 1 byte) — fires when 0xF1
        // succeeds, bulk apply changes it, or a preset load changes it.
        if off == 2898 && sz == 1 && payload.count >= 1 {
            self.i2sInputSupported = true
            self.i2sRxPin = payload[0]
            return
        }

        // input_config.i2s_input_rate (offset 2899, 1 byte, enum 0/1/2) —
        // fires when 0xED accepts a rate.
        if off == 2899 && sz == 1 && payload.count >= 1 {
            self.i2sInputSupported = true
            self.i2sInputRateHz = i2sRateEnumToHz(payload[0])
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

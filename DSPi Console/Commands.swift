import Foundation
import Combine
import SwiftUI

extension DSPViewModel {
    
    // --- USB Commands ---
    
    func fetchAll() {
        guard fetchPreamp() else { return }
        fetchBypass()
        fetchLoudness()
        fetchLoudnessRef()
        fetchLoudnessIntensity()
        fetchCrossfeed()
        fetchCrossfeedPreset()
        fetchCrossfeedFreq()
        fetchCrossfeedFeed()
        fetchCrossfeedITD()

        for ch in Channel.allCases {
            for b in 0..<ch.bandCount {
                fetchFilter(ch: ch.rawValue, band: b)
            }
            if ch.isOutput {
                fetchDelay(ch: ch.rawValue)
                // Map channel to output index (outLeft=2->0, outRight=3->1, sub=4->2)
                let outputIdx = ch.rawValue - 2
                fetchChannelGain(ch: outputIdx)
                fetchChannelMute(ch: outputIdx)
            }
        }
    }
    
    func fetchStatus() {
        // Single request for all peaks + CPU (wValue=9) - ensures synchronized meter readings
        guard let data = usb.getControlRequest(request: REQ_GET_STATUS, value: 9, index: 0, length: 12) else { return }

        let peak0 = Float(data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) }) / 65535.0
        let peak1 = Float(data.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) }) / 65535.0
        let peak2 = Float(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }) / 65535.0
        let peak3 = Float(data.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }) / 65535.0
        let peak4 = Float(data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt16.self) }) / 65535.0
        let cpu0 = Int(data[10])
        let cpu1 = Int(data[11])

        DispatchQueue.main.async {
            self.status.peaks = [peak0, peak1, peak2, peak3, peak4]
            self.status.cpu0 = cpu0
            self.status.cpu1 = cpu1
        }
    }
    
    func setFilter(ch: Int, band: Int, p: FilterParams) {
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
        self.channelDelays[ch] = ms
        var val = ms
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

    // MARK: - Per-Channel Gain

    func setChannelGain(ch: Int, db: Float) {
        guard ch < 3 else { return }
        channelGainDB[ch] = db
        var val = db
        let data = Data(bytes: &val, count: 4)
        usb.sendControlRequest(request: REQ_SET_CHANNEL_GAIN, value: UInt16(ch), index: 0, data: data)
    }

    func fetchChannelGain(ch: Int) {
        guard ch < 3 else { return }
        if let d = usb.getControlRequest(request: REQ_GET_CHANNEL_GAIN, value: UInt16(ch), index: 0, length: 4) {
            let val = d.withUnsafeBytes { $0.load(as: Float.self) }
            DispatchQueue.main.async {
                if abs((self.channelGainDB[ch] ?? 0) - val) > 0.01 {
                    self.channelGainDB[ch] = val
                }
            }
        }
    }

    // MARK: - Per-Channel Mute

    func setChannelMute(ch: Int, muted: Bool) {
        guard ch < 3 else { return }
        channelMute[ch] = muted
        var val: UInt8 = muted ? 1 : 0
        let data = Data(bytes: &val, count: 1)
        usb.sendControlRequest(request: REQ_SET_CHANNEL_MUTE, value: UInt16(ch), index: 0, data: data)
    }

    func fetchChannelMute(ch: Int) {
        guard ch < 3 else { return }
        if let d = usb.getControlRequest(request: REQ_GET_CHANNEL_MUTE, value: UInt16(ch), index: 0, length: 1) {
            let val = d[0] != 0
            DispatchQueue.main.async {
                self.channelMute[ch] = val
            }
        }
    }

    func setPreamp(_ db: Float) {
        self.preampDB = db
        var val = db
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
    }
    
    @discardableResult
    func fetchBypass() -> Bool {
        if let d = usb.getControlRequest(request: REQ_GET_BYPASS, value: 0, index: 0, length: 1) {
            let val = d[0] != 0
            DispatchQueue.main.async { self.bypass = val }
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

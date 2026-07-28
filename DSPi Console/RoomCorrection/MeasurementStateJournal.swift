import Foundation

/// Everything a measurement session temporarily changes, captured so it can be
/// put back.
///
/// Room measurement needs a linear, stable signal path, which means switching
/// off things the user deliberately switched on. That is acceptable only if it
/// is exactly reversible, including when the app is killed or the device is
/// unplugged mid-session - which is why this is written to disk before anything
/// is touched rather than held in memory.
///
/// See `Documentation/automated_room_correction_spec.md` section 8.
struct MeasurementStateSnapshot: Codable, Equatable {

    /// A single PEQ band, in the wire form.
    struct Band: Codable, Equatable {
        var type: Int
        var freq: Float
        var q: Float
        var gain: Float
        var qp: Float
        var bypass: Bool

        init(_ params: FilterParams) {
            type = params.type.rawValue
            freq = params.freq
            q = params.q
            gain = params.gain
            qp = params.qp
            bypass = params.bypass
        }

        var filterParams: FilterParams {
            var params = FilterParams()
            params.type = FilterType(rawValue: type) ?? .flat
            params.freq = freq
            params.q = q
            params.gain = gain
            params.qp = qp
            params.bypass = bypass
            return params
        }
    }

    // Identity. A journal that cannot prove it belongs to the attached device
    // must not be replayed onto it.
    var deviceSerial: String
    var platformName: String
    var sampleRateHz: UInt32
    var createdAt: Date
    var appVersion: String

    /// Every PEQ bank in the measured path, keyed by unified channel index.
    ///
    /// Both ends, not just the destination. Host playback traverses the input
    /// chain, so measuring through a live input bank would fold the user's tone
    /// controls into the measured response and the correction would then fight
    /// them. The old device-side generator injected after the matrix and could
    /// never see input EQ, which is why bypassing outputs alone used to be
    /// enough and no longer is.
    var peqBanks: [Int: [Band]]
    var crossoverBanks: [Int: [Band]]

    var matrixRouting: [[Bool]]
    var matrixGain: [[Float]]
    var matrixInvert: [[Bool]]

    var outputEnabled: [Bool]
    var outputMuted: [Bool]
    var outputGainDB: [Float]
    var outputDelayMS: [Float]

    var inputPreampDB: [Float]
    var masterVolumeDB: Float

    /// Nonlinear, dynamic and channel-deriving processing, all of which makes a
    /// measurement meaningless if left running.
    var bypassMasterEQ: Bool
    var loudnessEnabled: Bool
    var levellerEnabled: Bool
    var psybassEnabled: Bool
    var crossfeedEnabled: Bool
    var upmixEnabled: Bool

    var activePresetSlot: Int
    var hadUnsavedChanges: Bool
}

// MARK: - Capture and restore

extension MeasurementStateSnapshot {
    /// Capture from the live view model.
    init(capturing vm: DSPViewModel) {
        deviceSerial = vm.selectedDevice?.serial ?? ""
        platformName = vm.platformName
        sampleRateHz = vm.sampleRateHz
        createdAt = Date()
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "unknown"

        var peq: [Int: [Band]] = [:]
        var xover: [Int: [Band]] = [:]
        for (channel, bands) in vm.channelData {
            peq[channel] = bands.map(Band.init)
        }
        for (channel, bands) in vm.xoverData {
            xover[channel] = bands.map(Band.init)
        }
        peqBanks = peq
        crossoverBanks = xover

        matrixRouting = vm.matrixRouting
        matrixGain = vm.matrixGain
        matrixInvert = vm.matrixInvert

        outputEnabled = vm.outputEnabled
        outputMuted = vm.outputMuted
        outputGainDB = vm.outputGainDB
        outputDelayMS = vm.outputDelayMS

        inputPreampDB = vm.preampDB
        masterVolumeDB = vm.masterVolumeDB

        bypassMasterEQ = vm.bypass
        loudnessEnabled = vm.loudnessEnabled
        levellerEnabled = vm.levellerEnabled
        psybassEnabled = vm.psybassEnabled
        crossfeedEnabled = vm.crossfeedEnabled
        upmixEnabled = vm.upmixEnabled

        activePresetSlot = vm.activePresetSlot
        hadUnsavedChanges = vm.hasUnsavedChanges
    }

    /// Whether this journal may be replayed onto the attached device.
    ///
    /// Restoring one device's state onto another would be worse than not
    /// restoring at all, so identity is checked rather than assumed.
    func matches(_ vm: DSPViewModel) -> Bool {
        guard !deviceSerial.isEmpty else { return false }
        return deviceSerial == (vm.selectedDevice?.serial ?? "")
            && platformName == vm.platformName
    }

    /// Channels whose PEQ must be flattened, which depends on the mode.
    ///
    /// This is not "everything with a PEQ bank". Flattening the wrong bank
    /// produces a correction that is wrong by exactly whatever that bank does:
    ///
    /// - **Input mode** flattens only the input channels being corrected. The
    ///   output PEQ must stay active, because the correction lands upstream of
    ///   it and it will still be there when the user listens. An earlier
    ///   version flattened both ends, which meant the output PEQ was re-applied
    ///   after a correction that had not accounted for it.
    /// - **Output mode** flattens the driven input, whose PEQ is irrelevant
    ///   since the path is synthetic, and the target output, whose bank the
    ///   correction replaces outright.
    ///
    /// Crossovers are never included in either mode. See
    /// `Documentation/room_correction_measurement_modes.md`.
    func channelsToFlatten(mode: MeasurementMode,
                           correctedInputs: [Int],
                           drivenInput: Int?,
                           measuredOutputChannel: Int?) -> [Int] {
        switch mode {
        case .inputChannels:
            return correctedInputs.sorted()
        case .outputChannels:
            return [drivenInput, measuredOutputChannel].compactMap { $0 }.sorted()
        }
    }
}

// MARK: - Journal

/// Persists a snapshot before the device is changed, so an interrupted session
/// can still be undone.
///
/// A single slot rather than a history: the question this answers is "was a
/// session interrupted, and what did it change", and a stack of those would
/// only invite replaying the wrong one.
final class MeasurementStateJournal {
    enum JournalError: LocalizedError {
        case noJournal
        case deviceMismatch

        var errorDescription: String? {
            switch self {
            case .noJournal:
                return "There is no interrupted measurement to restore."
            case .deviceMismatch:
                return "The saved measurement state belongs to a different DSPi, so it "
                     + "cannot be restored onto this one."
            }
        }
    }

    private let url: URL
    private let fileManager: FileManager

    init(url: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let url {
            self.url = url
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let directory = support.appendingPathComponent("com.weeblabs.DSPi-Console",
                                                           isDirectory: true)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            self.url = directory.appendingPathComponent("room-correction-recovery.json")
        }
    }

    var hasPendingRecovery: Bool { fileManager.fileExists(atPath: url.path) }

    /// Write before touching the device.
    ///
    /// Written atomically: a journal half-written by a crash is worse than none,
    /// because it would restore a partial state and look like it succeeded.
    func write(_ snapshot: MeasurementStateSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    func read() throws -> MeasurementStateSnapshot {
        guard hasPendingRecovery else { throw JournalError.noJournal }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeasurementStateSnapshot.self,
                                  from: Data(contentsOf: url))
    }

    /// Clear once the device has been put back, and only then. Clearing on a
    /// merely successful measurement would lose the ability to undo it.
    func clear() {
        try? fileManager.removeItem(at: url)
    }

    /// Read a journal that belongs to the attached device, if there is one.
    ///
    /// A journal from a different device is discarded rather than offered:
    /// keeping it would mean showing a recovery prompt the user can never
    /// usefully accept.
    func pendingRecovery(for vm: DSPViewModel) -> MeasurementStateSnapshot? {
        guard let snapshot = try? read() else { return nil }
        guard snapshot.matches(vm) else { return nil }
        return snapshot
    }
}

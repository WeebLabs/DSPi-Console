import XCTest
import Combine
@testable import DSPi_Console

/// A device with one analyser configuration, driven only through vendor
/// requests: SET_CONFIG stages, GET_CONFIG reads back.  Records what the
/// engine sent so the tests can count pushes and readbacks.
private final class RtaFakeTransport: DeviceTransport {
    var session: LinkSessionID = 1
    var generation: UInt64 = 1
    var isConnected: Bool = true
    var isConnectedPublisher: AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
    var availableDevices: [DSPiDevice] = []
    var availableDevicesPublisher: AnyPublisher<[DSPiDevice], Never> { Just([]).eraseToAnyPublisher() }
    var selectedDevice: DSPiDevice? = nil
    var selectedDevicePublisher: AnyPublisher<DSPiDevice?, Never> { Just(nil).eraseToAnyPublisher() }
    var errorMessage: String? = nil
    var errorMessagePublisher: AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
    func selectDevice(_ device: DSPiDevice) {}
    func reconnect() {}
    func disconnect() {}
    func markDisconnected() {}
    func addNotificationObserver(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable {
        AnyCancellable {}
    }

    /// What the device holds.
    var config = RtaConfig(tap: RTA_TAP_OUTPUT, channelMask: 0x0001)
    /// False: every SET is refused (STALLed), so the readback never agrees.
    var applies = true
    /// Channels some other host keeps in the mask whatever we push.
    var forcedExtra: UInt16 = 0
    /// What the device clamps averaging to.
    var clampAvgMs: UInt16? = nil

    private(set) var pushes: [RtaConfig] = []
    private(set) var configReads = 0
    private(set) var bandReads: [(request: UInt8, value: UInt16)] = []

    func sendControlRequest(request: UInt8, value: UInt16, index: UInt16, data: Data) {
        guard request == REQ_RTA_SET_CONFIG, let c = RtaConfig.fromData(data) else { return }
        pushes.append(c)
        guard applies else { return }
        var applied = c
        applied.channelMask |= forcedExtra
        if let clamp = clampAvgMs { applied.avgMs = clamp }
        config = applied
    }

    func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Result<Data, LinkStatus> {
        switch request {
        case REQ_RTA_GET_CAPS:
            return .success(value == 0 ? Self.caps : Data(count: Int(length)))
        case REQ_RTA_GET_CONFIG:
            configReads += 1
            return .success(config.toData())
        case REQ_RTA_GET_BANDS, REQ_RTA_GET_BANDS_ALL:
            bandReads.append((request, value))
            return .failure(.error)
        default:
            return .failure(.error)
        }
    }

    static let caps: Data = {
        var d = Data(count: RTA_CAPS_SIZE)
        d[0] = RTA_CFG_VERSION
        d[1] = 8; d[2] = 9                   // input / output channels
        d[3] = 8; d[4] = 10; d[5] = 10       // order min / max / default
        d[6] = 14; d[7] = UInt8(RTA_MAX_BANDS)
        d[8] = RTA_LEVEL_ZERO_DBFS
        return d
    }()
}

/// Sharing the device's one analyser with other consoles
/// (Documentation/rta_sharing_spec.md section 3), driven through a fake
/// transport.  Tick runs on the test thread; its published results land on
/// the main queue, which `pump` drains.
final class RtaSharingTests: XCTestCase {
    private var fake: RtaFakeTransport!
    private var engine: RtaEngine!

    private let outOptions = RtaOptions(fftOrder: 10, avgMs: 300, peakDecayDBs: 12)

    override func setUp() {
        super.setUp()
        fake = RtaFakeTransport()
        engine = RtaEngine(transport: fake)
        engine.statusInterval = 0     // read status and config back on every tick
        engine.fetchCaps()
        pump()
        XCTAssertTrue(engine.supported)
        engine.setOptions(outOptions)
    }

    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private func tick(_ n: Int = 1) {
        for _ in 0..<n { engine.tick() }
        pump()
    }

    private func out(_ mask: UInt16) -> RtaConfig {
        RtaConfig(tap: RTA_TAP_OUTPUT, channelMask: mask, fftOrder: 10, avgMs: 300, peakDecayDBs: 12)
    }

    // MARK: Own echo

    /// Our echo confirms the push: no more pushes, the clamped averaging is
    /// not mistaken for a difference, and the readback is no longer polled.
    func testOwnEchoConfirmsAndStopsReadback() {
        fake.clampAvgMs = 250
        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick()
        XCTAssertEqual(fake.pushes.count, 1)

        var echoed = out(0b1); echoed.avgMs = 250
        engine.deviceAnnounced(echoed, origin: fake.session)
        XCTAssertEqual(engine.ownership, .driving)

        let reads = fake.configReads
        tick(5)
        XCTAssertEqual(fake.pushes.count, 1, "a clamped value must not be re-pushed")
        XCTAssertEqual(fake.configReads, reads, "the event replaces the readback")
        XCTAssertFalse(engine.configRejected)
    }

    /// A refused configuration ends rejected; the echo of a later accepted
    /// push clears it.
    func testOwnEchoClearsRejection() {
        fake.applies = false
        fake.config = out(0b10)
        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick(4)
        XCTAssertTrue(engine.configRejected)
        engine.deviceAnnounced(out(0b1), origin: fake.session)
        XCTAssertFalse(engine.configRejected)
        XCTAssertEqual(engine.ownership, .driving)
    }

    // MARK: Following

    /// Someone else's configuration that lacks our channels is followed: no
    /// push over it, and the device's channels are what the views draw.
    func testForeignEventFollows() {
        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick()
        fake.config = out(0b100)
        engine.deviceAnnounced(out(0b100), origin: 7)
        XCTAssertEqual(engine.ownership, .following(origin: 7))
        XCTAssertEqual(engine.effectiveSelection, RtaChannelSelection(tap: RTA_TAP_OUTPUT, channels: [2]))

        let pushes = fake.pushes.count
        tick(3)
        XCTAssertEqual(fake.pushes.count, pushes, "a follower never pushes")
        XCTAssertEqual(fake.bandReads.last?.request, REQ_RTA_GET_BANDS)
        XCTAssertEqual(fake.bandReads.last?.value, 2, "bands are read for the device's channel")
        XCTAssertFalse(engine.configRejected)
    }

    /// A UART or I2C writer arrives with origin 0 and is followed the same way.
    func testUnattributedEventFollowsWithOriginZero() {
        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick()
        engine.deviceAnnounced(RtaConfig(tap: RTA_TAP_INPUT, channelMask: 0b11), origin: 0)
        XCTAssertEqual(engine.ownership, .following(origin: 0))
        XCTAssertEqual(engine.effectiveSelection?.tap, RTA_TAP_INPUT)
    }

    /// A foreign superset of what we want is not a reason to follow.
    func testForeignSupersetKeepsDriving() {
        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick()
        engine.deviceAnnounced(out(0b11), origin: 7)
        XCTAssertEqual(engine.ownership, .driving)
        let pushes = fake.pushes.count
        tick(3)
        XCTAssertEqual(fake.pushes.count, pushes)
    }

    // MARK: Taking control

    /// Choosing channels while following pushes ours with the other
    /// console's channels kept, because it is at the same tap.
    func testUserChangeTakesControlWithUnionMask() {
        let id = engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick()
        fake.config = out(0b100)
        engine.deviceAnnounced(out(0b100), origin: 7)
        XCTAssertEqual(engine.ownership, .following(origin: 7))

        engine.update(id, to: RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b11))
        XCTAssertEqual(engine.ownership, .driving)
        XCTAssertNil(engine.effectiveSelection)
        tick()
        XCTAssertEqual(fake.pushes.last?.channelMask, 0b111)
        XCTAssertEqual(engine.ownership, .driving)
    }

    /// The Take control button does the same without changing the selection.
    func testTakeControlButtonPushesUnion() {
        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick()
        fake.config = out(0b100)
        engine.deviceAnnounced(out(0b100), origin: 7)
        engine.takeControl()
        tick()
        XCTAssertEqual(fake.pushes.last?.channelMask, 0b101)
        XCTAssertEqual(engine.ownership, .driving)
    }

    /// At the other tap there is nothing to keep: the push is ours alone.
    func testTakeControlAtOtherTapPushesOursOnly() {
        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick()
        let theirs = RtaConfig(tap: RTA_TAP_INPUT, channelMask: 0b1000, fftOrder: 10)
        fake.config = theirs
        engine.deviceAnnounced(theirs, origin: 7)
        engine.takeControl()
        tick()
        XCTAssertEqual(fake.pushes.last?.tap, RTA_TAP_OUTPUT)
        XCTAssertEqual(fake.pushes.last?.channelMask, 0b1)
    }

    /// A view re-publishing the same request does not steal the analyser.
    func testSameRequestDoesNotTakeControl() {
        let id = engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick()
        engine.deviceAnnounced(out(0b100), origin: 7)
        engine.update(id, to: RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        XCTAssertEqual(engine.ownership, .following(origin: 7))
    }

    /// Showing a second display of the same selection (the bars beside the
    /// graph) is not a choice, so it must not push over the console we follow.
    func testShowingAnotherDisplayDoesNotTakeControl() {
        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1, wantsBins: true))
        tick()
        fake.config = out(0b100)
        engine.deviceAnnounced(out(0b100), origin: 7)
        let pushes = fake.pushes.count

        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick(3)
        XCTAssertEqual(engine.ownership, .following(origin: 7))
        XCTAssertEqual(fake.pushes.count, pushes)
    }

    /// Hiding the only display and showing it again keeps following.
    func testReshowingAfterHidingAllKeepsFollowing() {
        let id = engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick()
        fake.config = out(0b100)
        engine.deviceAnnounced(out(0b100), origin: 7)
        let pushes = fake.pushes.count

        engine.release(id)
        pump()
        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick(3)
        XCTAssertEqual(engine.ownership, .following(origin: 7))
        XCTAssertEqual(fake.pushes.count, pushes)
    }

    /// While driving, showing a display again does not push the same
    /// configuration over again: the device kept it.
    func testReshowingWhileDrivingDoesNotRepush() {
        let id = engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick()
        engine.deviceAnnounced(out(0b1), origin: fake.session)
        engine.release(id)
        pump()
        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick(3)
        XCTAssertEqual(fake.pushes.count, 1)
        XCTAssertEqual(engine.ownership, .driving)
    }

    /// A change someone else makes while nothing here watches is followed
    /// when a display comes back, not pushed over.
    func testChangeWhileHiddenIsFollowedOnReshow() {
        let id = engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick()
        engine.deviceAnnounced(out(0b1), origin: fake.session)
        engine.release(id)
        pump()
        fake.config = out(0b100)
        engine.deviceAnnounced(out(0b100), origin: 7)

        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick(3)
        XCTAssertEqual(engine.ownership, .following(origin: 7))
        XCTAssertEqual(fake.pushes.count, 1)
    }

    // MARK: Bar displays

    /// While following at the other tap the bars draw the device's channels,
    /// named and coloured for that tap, and re-registering the page's own
    /// request on a relayout keeps following.
    func testBarsDrawFollowedSelectionWithoutTakingControl() {
        let own = RtaChannelSelection(tap: RTA_TAP_OUTPUT, channels: [0])
        let id = engine.subscribe(RtaRequest(tap: own.tap, mask: own.mask))
        tick()
        let theirs = RtaConfig(tap: RTA_TAP_INPUT, channelMask: 0b110, fftOrder: 10)
        fake.config = theirs
        engine.deviceAnnounced(theirs, origin: 7)

        let drawn = RtaChannelSelection.drawn(own: own, followed: engine.effectiveSelection)
        XCTAssertEqual(drawn, RtaChannelSelection(tap: RTA_TAP_INPUT, channels: [1, 2]))

        let vm = DSPViewModel()
        let cells = vm.rtaDrawnChannels(drawn)
        XCTAssertEqual(cells.map(\.channel), [1, 2])
        XCTAssertEqual(cells.map(\.eqChannel), [1, 2], "input channels colour as input rows")
        XCTAssertEqual(cells.map(\.name), [vm.channelNames[1], vm.channelNames[2]])

        engine.update(id, to: RtaRequest(tap: own.tap, mask: own.mask))
        tick()
        XCTAssertEqual(engine.ownership, .following(origin: 7))
        XCTAssertEqual(fake.pushes.count, 1, "drawing the followed selection pushes nothing")
    }

    /// Driving, the bars draw the page's own selection, and a followed output
    /// is named and coloured through the output's EQ channel.
    func testBarsDrawOwnSelectionWhileDriving() {
        let own = RtaChannelSelection(tap: RTA_TAP_INPUT, channels: [0, 1])
        XCTAssertNil(engine.effectiveSelection)
        XCTAssertEqual(RtaChannelSelection.drawn(own: own, followed: engine.effectiveSelection), own)

        let vm = DSPViewModel()
        let outputs = RtaChannelSelection(tap: RTA_TAP_OUTPUT, channels: [3])
        let cell = vm.rtaDrawnChannels(outputs)[0]
        XCTAssertEqual(cell.eqChannel, vm.chOut1 + 3)
        XCTAssertEqual(cell.name, vm.rtaChannelName(tap: RTA_TAP_OUTPUT, channel: 3))
    }

    // MARK: Readback (firmware without the event)

    /// A readback holding every channel we asked for and more is success.
    func testSupersetReadbackIsSuccess() {
        fake.forcedExtra = 0b100
        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick(5)
        XCTAssertEqual(fake.pushes.count, 1)
        XCTAssertFalse(engine.configRejected)
        XCTAssertEqual(engine.ownership, .driving)
    }

    /// A readback that agreed and then changes means another host: follow
    /// with an unknown origin, and stop pushing.
    func testReadbackFollowsAfterEarlierAgreement() {
        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick()
        XCTAssertEqual(engine.ownership, .driving)

        fake.config = out(0b1000)
        tick()
        XCTAssertEqual(engine.ownership, .following(origin: 0))
        XCTAssertEqual(engine.effectiveSelection, RtaChannelSelection(tap: RTA_TAP_OUTPUT, channels: [3]))
        let pushes = fake.pushes.count
        tick(4)
        XCTAssertEqual(fake.pushes.count, pushes)
        XCTAssertFalse(engine.configRejected)

        // A further change is followed in place.
        fake.config = out(0b10000)
        tick()
        XCTAssertEqual(engine.effectiveSelection, RtaChannelSelection(tap: RTA_TAP_OUTPUT, channels: [4]))
    }

    /// A readback that never agreed is a refusal, never a reason to follow.
    func testNeverAgreeingReadbackEndsRejected() {
        fake.applies = false
        fake.config = out(0b1000)
        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick(6)
        XCTAssertEqual(fake.pushes.count, 3, "three attempts, then give up")
        XCTAssertTrue(engine.configRejected)
        XCTAssertEqual(engine.ownership, .driving)
    }

    /// A device switch forgets the event, so the readback comes back.
    func testConfigurationChangedResumesReadback() {
        engine.subscribe(RtaRequest(tap: RTA_TAP_OUTPUT, mask: 0b1))
        tick()
        engine.deviceAnnounced(out(0b1), origin: fake.session)
        let reads = fake.configReads
        tick(2)
        XCTAssertEqual(fake.configReads, reads)

        engine.configurationChanged()
        pump()
        tick(2)
        XCTAssertGreaterThan(fake.configReads, reads)
    }
}

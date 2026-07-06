import XCTest
@testable import DSPi_Console

/// Live-device diagnostic for the test signal generator: stages a quiet sine,
/// starts it, and watches the status for two seconds to see whether the
/// engine actually advances (elapsed_ms growing, state leaving FADE_IN).
/// Skips with no device.  Always stops the generator on exit.
final class SiggenHardwareDiagTests: XCTestCase {

    func testSineStartAdvances() throws {
        let usb = try HardwareTest.requireDevice()

        guard let capsData = usb.getControlRequest(request: REQ_SIGGEN_GET_CAPS,
                                                   value: SIGGEN_CAPS_HEADER, index: 2, length: 8),
              let caps = SiggenCapsHeader.fromData(capsData) else {
            throw XCTSkip("Firmware has no siggen (GET_CAPS stalled)")
        }
        print("SIGGEN caps: types=\(caps.typeCount) outputs=\(caps.outputChannels) mask=0x\(String(caps.validChannelMask, radix: 16))")

        defer {
            _ = usb.getControlRequest(request: REQ_SIGGEN_CONTROL,
                                      value: SIGGEN_CTL_STOP_NOW, index: 2, length: 1)
        }

        // Note whether the host USB stream is warm (buffer-stats flags bit 1
        // mirrors usb_audio_stream_active).  When cold, phase 1 exercises the
        // firmware's zero-input pump - including pumping through a latched
        // preset_loading mute (the boot-with-no-stream deadlock found
        // 2026-07-05); when warm, phase 1 is host-driven and trivially passes.
        if let bs = usb.getControlRequest(request: REQ_GET_BUFFER_STATS,
                                          value: 0, index: 0, length: 44) {
            print("PHASE0: usb stream \(bs[1] & 0x02 != 0 ? "warm (host-driven)" : "cold (pump-driven)")")
        }

        // Quiet 1 kHz sine on output 0 only.
        let cfg = SiggenConfig(signalType: SIGGEN_SINE, channelMask: 0x0001,
                               levelDB: -40.0, p1: 1000.0)
        usb.sendControlRequest(request: REQ_SIGGEN_SET_CONFIG, value: 0, index: 2, data: cfg.toData())

        let ack = usb.getControlRequest(request: REQ_SIGGEN_CONTROL,
                                        value: SIGGEN_CTL_START, index: 2, length: 1)
        print("SIGGEN start ack: \(ack.map { Array($0) }.map(String.init(describing:)) ?? "STALL")")
        XCTAssertEqual(ack?.first, 1, "START was not accepted")

        // Phase 1: no host stream - only the firmware pump can drive blocks.
        var lastState: UInt8 = 0xFF
        var sawRunIdle = false
        for i in 0..<10 {
            Thread.sleep(forTimeInterval: 0.1)
            guard let d = usb.getControlRequest(request: REQ_SIGGEN_GET_STATUS,
                                                value: 0, index: 2, length: 16),
                  let st = SiggenStatus.fromData(d) else { continue }
            if st.state != lastState || i % 5 == 0 {
                print("idle poll \(i): state=\(st.state) elapsed=\(st.elapsedMS)ms")
            }
            lastState = st.state
            if st.state == SIGGEN_STATE_RUN { sawRunIdle = true }
        }
        print("PHASE1 (pump only): sawRun=\(sawRunIdle)")

        // Dump buffer stats while stuck: slot-0 consumer fill is the pump's
        // pacing signal (pump refuses to push while fill >= 50%), and flags
        // bit 1 mirrors sync_started / usb_audio_stream_active.
        if let bs = usb.getControlRequest(request: REQ_GET_BUFFER_STATS, value: 0, index: 0, length: 44) {
            let numSpdif = Int(bs[0])
            print("BUFSTATS: flags=0x\(String(bs[1], radix: 16)) (bit1=streaming) numSpdif=\(numSpdif)")
            for i in 0..<min(numSpdif, 4) {
                let base = 4 + i * 8
                print("  slot\(i): free=\(bs[base]) prepared=\(bs[base + 1]) playing=\(bs[base + 2]) fill=\(bs[base + 3])% min=\(bs[base + 4])% max=\(bs[base + 5])%")
            }
        } else {
            print("BUFSTATS: read failed")
        }

        // Phase 2: open a real USB audio stream to the device so
        // process_input_block runs regardless of the pump.
        let sayProc = Process()
        sayProc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        sayProc.arguments = ["-a", "Weeb Labs DSPi", "-r", "60", "one two three four five six"]
        try? sayProc.run()

        var sawRun = false
        var lastElapsed: UInt32 = 0
        for i in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            guard let d = usb.getControlRequest(request: REQ_SIGGEN_GET_STATUS,
                                                value: 0, index: 2, length: 16),
                  let st = SiggenStatus.fromData(d) else {
                print("poll \(i): GET_STATUS failed")
                continue
            }
            if st.state != lastState || i % 5 == 0 {
                print("stream poll \(i): state=\(st.state) elapsed=\(st.elapsedMS)ms cycles=\(st.cyclesDone) reason=\(st.stopReason)")
            }
            lastState = st.state
            lastElapsed = st.elapsedMS
            if st.state == SIGGEN_STATE_RUN { sawRun = true }
        }
        sayProc.terminate()
        print("PHASE2 (host stream): sawRun=\(sawRun) elapsed=\(lastElapsed)ms")

        XCTAssertTrue(sawRun, "engine never reached RUN even with a live host stream (stuck state=\(lastState))")
        XCTAssertGreaterThan(lastElapsed, 500, "elapsed_ms not advancing - no blocks flowing")
    }

    /// Drives the real `DSPViewModel.identifyOutput(_:)` end to end (including
    /// its async dispatch) and verifies the device plays a CHANNEL_ID ident on
    /// exactly the requested output: the walk channel latches to that output's
    /// index, and the two-pass config auto-completes to idle.
    func testIdentifyOutputPlaysChannelId() throws {
        let usb = try HardwareTest.requireDevice()
        let vm = AppState.shared.viewModel

        // The VM populates siggenSupported during its connect-time fetchAll on
        // a background queue; spin the run loop until it (or the caps probe)
        // resolves.
        let deadline = Date().addingTimeInterval(10)
        while !vm.siggenSupported && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        guard vm.siggenSupported else {
            throw XCTSkip("Firmware has no siggen (siggenSupported never set)")
        }

        defer {
            _ = usb.getControlRequest(request: REQ_SIGGEN_CONTROL,
                                      value: SIGGEN_CTL_STOP_NOW, index: 2, length: 1)
        }

        // Output 1 is enabled by default (stereo pass-through) and gives a
        // non-trivial walk index: ident should play 2 blips as channel 1.
        let target = 1

        // Keep blocks flowing even if the host stream has gone cold.
        let sayProc = Process()
        sayProc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        sayProc.arguments = ["-a", "Weeb Labs DSPi", "-r", "70", "identify identify identify"]
        try? sayProc.run()
        defer { sayProc.terminate() }

        vm.identifyOutput(target)

        var sawChannelIdRun = false
        var sawTargetWalk = false
        var sawCompleted = false
        for i in 0..<40 {
            Thread.sleep(forTimeInterval: 0.1)
            guard let d = usb.getControlRequest(request: REQ_SIGGEN_GET_STATUS,
                                                value: 0, index: 2, length: 16),
                  let st = SiggenStatus.fromData(d) else { continue }
            if i % 5 == 0 || st.state == SIGGEN_STATE_IDLE {
                print("identify poll \(i): state=\(st.state) type=\(st.signalType) walkCh=\(st.activeChannel) cycles=\(st.cyclesDone) reason=\(st.stopReason)")
            }
            if st.signalType == SIGGEN_CHANNEL_ID && st.state == SIGGEN_STATE_RUN {
                sawChannelIdRun = true
            }
            if st.signalType == SIGGEN_CHANNEL_ID && st.activeChannel == UInt8(target) {
                sawTargetWalk = true
            }
            // Finite two-pass ident: eventually idle with COMPLETED.
            if st.state == SIGGEN_STATE_IDLE && st.stopReason == SIGGEN_STOP_COMPLETED {
                sawCompleted = true
                break
            }
        }
        print("IDENTIFY: channelIdRun=\(sawChannelIdRun) targetWalk=\(sawTargetWalk) completed=\(sawCompleted)")

        XCTAssertTrue(sawChannelIdRun, "generator never ran a CHANNEL_ID signal")
        XCTAssertTrue(sawTargetWalk, "ident walk never latched to output \(target)")
        XCTAssertTrue(sawCompleted, "two-pass ident never auto-completed to idle")
    }
}

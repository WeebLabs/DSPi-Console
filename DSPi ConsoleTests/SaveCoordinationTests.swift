import XCTest
@testable import DSPi_Console

/// Tests for the save/prompt **coordination** logic - the layer between the
/// Settings UI and the device that decides when changes are "dirty", whether a
/// save prompt should fire, and which kind of save to queue. This logic lives in
/// `DSPViewModel` (preset unsaved-changes) and `SettingsSaveCoordinator`
/// (global + output-config batching), both plain `ObservableObject`s, so it is
/// exercised here without driving any SwiftUI view.
///
/// Not covered (would need an XCUITest target): that the `NSAlert` modal
/// actually renders and that controls are wired to these methods. These tests
/// verify the decision inputs and outcomes that drive that modal.
final class SaveCoordinationTests: XCTestCase {

    // MARK: Helpers

    /// A `DSPViewModel` for isolated dirty-detection tests. Constructing one
    /// repoints the shared interrupt monitor's handler at the new instance, so
    /// we save and restore it to avoid disturbing the app's live view model.
    private func makeIsolatedVM() -> DSPViewModel {
        let savedHandler = AppState.shared.interruptMonitor.onParamChanged
        let vm = DSPViewModel(usb: AppState.shared.usb)
        AppState.shared.interruptMonitor.onParamChanged = savedHandler
        return vm
    }

    private func spin(until condition: @autoclosure () -> Bool, timeout: TimeInterval = 6.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: 1. Preset dirty / prompt-trigger logic (no device, no flash)

    func testCleanBaselineHasNoUnsavedChanges() {
        let vm = makeIsolatedVM()
        vm.updateSavedSnapshot()
        XCTAssertFalse(vm.hasUnsavedChanges, "a freshly-baselined state must be clean")
    }

    func testFilterEditMarksPresetDirtyAndNamesEQ() {
        let vm = makeIsolatedVM()
        vm.updateSavedSnapshot()

        vm.channelData[0]?[0] = FilterParams(type: .peaking, freq: 1000, q: 1.0, gain: 6.0)

        XCTAssertTrue(vm.hasUnsavedChanges, "editing a PEQ band must mark the preset dirty (prompt would fire)")
        XCTAssertTrue(vm.computeDiff().changes.contains { $0.category.contains("EQ") },
                      "the prompt's change list should name the EQ channel: \(vm.computeDiff().changes.map(\.category))")
    }

    func testCrossoverEditMarksPresetDirtyAndNamesCrossover() {
        let vm = makeIsolatedVM()
        vm.updateSavedSnapshot()

        vm.xoverData[2]?[0] = FilterParams(type: .lr4_lp, freq: 1200, q: 0.707, gain: 0)

        XCTAssertTrue(vm.hasUnsavedChanges, "editing a crossover band must mark the preset dirty")
        XCTAssertTrue(vm.computeDiff().changes.contains { $0.category.contains("Crossover") },
                      "the prompt's change list should name Crossover: \(vm.computeDiff().changes.map(\.category))")
    }

    func testChannelRenameMarksPresetDirty() {
        let vm = makeIsolatedVM()
        vm.channelNames = ["USB L", "USB R", "Out L", "Out R", "Sub"]
        vm.updateSavedSnapshot()

        vm.channelNames[2] = "Living Room Mains"

        XCTAssertTrue(vm.hasUnsavedChanges, "renaming a channel must mark the preset dirty")
    }

    // MARK: 2. Output-config save gating by mode (no device, no flash)

    func testOutputEditGatedByMode() {
        let vm = AppState.shared.viewModel
        let coord = SettingsSaveCoordinator.shared
        let savedMode = vm.presetOutputConfigMode
        let savedDirty = coord.outputConfigDirty
        defer { vm.presetOutputConfigMode = savedMode; coord.outputConfigDirty = savedDirty }

        // WITH_PRESET: output wiring rides with the preset, so an output edit must
        // NOT arm the explicit output-config save (no separate "Save" prompt).
        vm.presetOutputConfigMode = OUTPUT_CONFIG_MODE_WITH_PRESET
        coord.outputConfigDirty = false
        coord.beginOutputEdit()
        XCTAssertFalse(coord.outputConfigDirty, "with-preset mode must not arm the output-config save")
        XCTAssertFalse(coord.outputDirty)

        // INDEPENDENT: output wiring is saved explicitly, so an edit arms it and
        // surfaces as a pending change (the "Save Output Configuration" prompt).
        vm.presetOutputConfigMode = OUTPUT_CONFIG_MODE_INDEPENDENT
        coord.outputConfigDirty = false
        coord.beginOutputEdit()
        XCTAssertTrue(coord.outputConfigDirty, "independent mode must arm the output-config save")
        XCTAssertTrue(coord.outputDirty)
        XCTAssertTrue(coord.hasPendingChanges)
    }

    func testGlobalDraftEditMarksGlobalDirty() {
        let vm = AppState.shared.viewModel
        let coord = SettingsSaveCoordinator.shared
        let savedDraft = coord.globalDraft
        let savedEdited = coord.globalUserEdited
        defer { coord.globalDraft = savedDraft; coord.globalUserEdited = savedEdited }

        // Start from a clean draft that mirrors the device.
        coord.globalDraft = GlobalSettingsDraft.from(vm)
        coord.globalUserEdited = false
        XCTAssertFalse(coord.globalDirty, "a draft mirroring the device is clean")

        // Edit a field through the draft binding (the same path the UI controls use).
        let current = GlobalSettingsDraft.from(vm).presetDefaultSlot
        coord.draftBinding(\.presetDefaultSlot).wrappedValue = (current == 0 ? 1 : 0)

        XCTAssertTrue(coord.globalUserEdited, "editing through the draft binding flags user-edited")
        XCTAssertTrue(coord.globalDirty, "a draft diverging from the device is dirty")
        XCTAssertTrue(coord.hasPendingChanges)
    }

    // MARK: 3. Real save() persistence round-trip (writes flash; opt-in)

    /// Verifies `SettingsSaveCoordinator.save()` actually pushes a global change
    /// to the device and clears the dirty flags. Writes flash, so it is OPT-IN:
    /// set `DSPI_ALLOW_FLASH=1` in the test environment to run it.
    func testGlobalSaveAppliesOutputConfigModeAndClearsDirty() throws {
        // Opt-in (writes flash). A host-app test process is launched by
        // testmanagerd and inherits neither the shell environment nor the app's
        // own defaults domain, but `UserDefaults.standard` does read the GLOBAL
        // domain. So the switch is a global default. Enable / clear with:
        //   defaults write -g DSPiAllowFlash -bool YES
        //   defaults delete -g DSPiAllowFlash
        try XCTSkipUnless(UserDefaults.standard.bool(forKey: "DSPiAllowFlash"),
                          "Enable flash-writing save tests with: defaults write -g DSPiAllowFlash -bool YES")
        let usb = try HardwareTest.requireDevice()
        let vm = AppState.shared.viewModel
        let coord = SettingsSaveCoordinator.shared

        func deviceMode() -> Int? {
            guard let d = usb.getControlRequest(request: REQ_GET_OUTPUT_CONFIG_MODE, value: 0, index: 2, length: 1),
                  let b = d.first else { return nil }
            return Int(b)
        }

        let original = deviceMode()
        try XCTSkipIf(original == nil, "device did not report output-config mode")
        let target = original == OUTPUT_CONFIG_MODE_WITH_PRESET
            ? OUTPUT_CONFIG_MODE_INDEPENDENT : OUTPUT_CONFIG_MODE_WITH_PRESET

        defer {
            coord.globalDraft = GlobalSettingsDraft.from(vm)
            coord.globalUserEdited = false
            coord.draftBinding(\.presetOutputConfigMode).wrappedValue = original!
            coord.save()
            spin(until: !coord.globalUserEdited)
        }

        // Edit the global draft, then save and verify it landed on the device.
        coord.globalDraft = GlobalSettingsDraft.from(vm)
        coord.globalUserEdited = false
        coord.draftBinding(\.presetOutputConfigMode).wrappedValue = target
        XCTAssertTrue(coord.globalDirty, "the mode change should be dirty before save")

        coord.save()
        spin(until: !coord.globalUserEdited)   // save()'s completion clears the flags

        XCTAssertFalse(coord.globalDirty, "save() should clear the global dirty flag")
        XCTAssertEqual(deviceMode(), target,
                       "save() should persist the new output-config mode to the device")
    }
}

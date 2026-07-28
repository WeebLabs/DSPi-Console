import AppKit
import SwiftUI
import XCTest
@testable import DSPi_Console

/// Renders the Room Correction window headlessly.
///
/// A compiling SwiftUI view is not a working one: a layout that traps, a
/// binding that recurses, or a picker with no valid selection all build fine
/// and fail at first paint. This drives the view to an actual bitmap, which is
/// the cheapest thing that would catch that, and writes it out so the result
/// can be looked at rather than assumed.
@MainActor
final class RoomCorrectionRenderTests: XCTestCase {

    /// One view model and one catalog for the whole class.
    ///
    /// `DSPViewModel()` defaults to the *shared* USB device and installs
    /// listeners, so creating one per test spun up nine of them all talking to
    /// the same hardware. That raced the live-device siggen test, which passed
    /// alone and failed in a full run - the kind of interaction that is
    /// miserable to track down later.
    private static let sharedModel: (vm: DSPViewModel, catalog: AudioDeviceCatalog) = {
        (DSPViewModel(), AudioDeviceCatalog(startListening: false))
    }()

    private func makeModel() -> RoomCorrectionModel {
        RoomCorrectionModel(vm: Self.sharedModel.vm, catalog: Self.sharedModel.catalog)
    }

    /// Renders in an explicit appearance.
    ///
    /// An offscreen `NSHostingView` inherits no appearance, so without this the
    /// same view rendered dark on one run and light on the next - which made
    /// the images useless as a check and briefly looked like a layout bug.
    /// Pinning it also means both themes get exercised, which the app has to
    /// support anyway.
    private func render(_ view: some View,
                        size: NSSize,
                        name: String,
                        appearance: NSAppearance.Name = .darkAqua) throws -> NSImage {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
                                           "view produced no drawable area")
        hosting.cacheDisplay(in: hosting.bounds, to: representation)

        let image = NSImage(size: size)
        image.addRepresentation(representation)

        if let data = representation.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("dspi-render-\(name)-\(appearance.rawValue).png")
            try? data.write(to: url)
            print("rendered \(name) to \(url.path)")
        }
        return image
    }

    /// Not a blank frame, and not a uniform fill either: a view that fails to
    /// lay out often still produces a correctly sized rectangle of background.
    private func assertHasContent(_ image: NSImage, _ label: String) throws {
        let representation = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        var colours = Set<UInt32>()
        let width = representation.pixelsWide
        let height = representation.pixelsHigh
        for y in stride(from: 0, to: height, by: 7) {
            for x in stride(from: 0, to: width, by: 7) {
                guard let colour = representation.colorAt(x: x, y: y) else { continue }
                let packed = (UInt32(colour.redComponent * 255) << 16)
                    | (UInt32(colour.greenComponent * 255) << 8)
                    | UInt32(colour.blueComponent * 255)
                colours.insert(packed)
            }
        }
        XCTAssertGreaterThan(colours.count, 8,
                             "\(label) rendered only \(colours.count) distinct colours, "
                             + "which looks like a blank or unlaid-out view")
    }

    func testSetupStepRenders() throws {
        let model = makeModel()
        let image = try render(RoomCorrectionView(model: model),
                               size: NSSize(width: 1080, height: 720),
                               name: "setup")
        try assertHasContent(image, "Setup step")
    }

    func testEveryStepRendersWithoutTrapping() throws {
        // The unbuilt steps still have to render their placeholder rather than
        // crash, or navigating the step list breaks the window.
        for step in RoomCorrectionStep.allCases {
            let model = makeModel()
            model.step = step
            let image = try render(RoomCorrectionView(model: model),
                                   size: NSSize(width: 1080, height: 720),
                                   name: "step-\(step.title.lowercased())")
            try assertHasContent(image, step.title)
        }
    }

    func testSetupRendersWithSpeakersAndCalibrationLoaded() throws {
        // The populated path exercises the speaker rows, the destination
        // picker and the calibration summary, none of which appear in the
        // empty state.
        let model = makeModel()
        model.selectedTargets = [0, 1]
        model.calibration = try? RoomCorrectionCore.Calibration(
            contents: "\"Sens Factor =-1.6dB, SERNO: 7012345\"\n20 0.0\n1000 1.5\n20000 -2.0\n")
        model.calibrationName = "UMIK-1_90deg.txt"

        let image = try render(RoomCorrectionView(model: model),
                               size: NSSize(width: 1080, height: 720),
                               name: "setup-populated")
        try assertHasContent(image, "Populated setup")
    }

    func testSetupRendersInBothAppearances() throws {
        // Light mode is not an afterthought: a view that only works in dark
        // mode is broken for half the users, and offscreen rendering is the
        // cheapest place to catch white-on-white.
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let model = makeModel()
            model.selectedTargets = [0, 1]
            let image = try render(RoomCorrectionView(model: model),
                                   size: NSSize(width: 1080, height: 720),
                                   name: "setup-theme",
                                   appearance: appearance)
            try assertHasContent(image, "Setup in \(appearance.rawValue)")
        }
    }

    func testInputDomainRendersBassManagedFanout() throws {
        // The 5.1 case: several program channels, each playing through its own
        // speaker and the subwoofer. The row has to make that visible rather
        // than leaving the user to infer it.
        let model = makeModel()
        model.domain = .inputs
        model.selectedTargets = [0, 1, 2]
        let image = try render(RoomCorrectionView(model: model),
                               size: NSSize(width: 1080, height: 720),
                               name: "setup-input-domain")
        try assertHasContent(image, "Input domain")
    }

    func testWindowMinimumSizeStillRenders() throws {
        // The window allows 900x620; the layout must survive its own minimum.
        let model = makeModel()
        model.selectedTargets = [0, 1, 2]
        let image = try render(RoomCorrectionView(model: model),
                               size: NSSize(width: 900, height: 620),
                               name: "setup-minimum")
        try assertHasContent(image, "Minimum size")
    }
}

import SwiftUI
import Combine

/// Graph band selection and hover, shared between the response graph and the
/// band list.  Published only when the set or the hovered band actually
/// changes, never per mouse movement, so the rows that observe it redraw on
/// a click or when the pointer crosses onto another dot.
final class PeqGraphSelection: ObservableObject {
    @Published var selected: Set<Int> = []
    /// The band under the pointer on the graph; its row lights up.
    @Published var graphHovered: Int?
    /// The row under the pointer in the list; its dot and lobe light up.
    @Published var listHovered: Int?

    func reset() {
        if !selected.isEmpty { selected = [] }
        if graphHovered != nil { graphHovered = nil }
        if listHovered != nil { listHovered = nil }
    }
}

/// One set of AppKit readouts per band row, driven by a graph drag exactly as
/// a `ParameterRow` drives its field: the row's own text fields hide and an
/// AppKit label shows the live value, so the list follows the drag at no
/// SwiftUI cost.  Plain class, not observable, on purpose.
final class PeqLiveReadouts {
    static let bands = 16
    let freq: [LiveValueReadout]
    let gain: [LiveValueReadout]
    let q: [LiveValueReadout]
    private var live: Set<Int> = []

    init() {
        func make(_ decimals: Int, _ strip: Bool) -> [LiveValueReadout] {
            (0..<Self.bands).map { _ in
                let r = LiveValueReadout()
                r.format = { ValueField.format($0, maxDecimals: decimals, stripTrailingZeros: strip) }
                return r
            }
        }
        // The same formats the row's fields use: freq 1 place, gain 3, Q 3
        // without trailing zeros.
        freq = make(1, false)
        gain = make(3, false)
        q = make(3, true)
    }

    /// Shows `p` in band `band`'s row, starting the live display if needed.
    func show(band: Int, _ p: FilterParams) {
        guard band < Self.bands else { return }
        if live.insert(band).inserted {
            freq[band].beginLive(showing: p.freq)
            if p.type.usesGain { gain[band].beginLive(showing: p.gain) }
            if p.type.usesQ { q[band].beginLive(showing: p.q) }
        }
        freq[band].show(p.freq)
        gain[band].show(p.gain)
        q[band].show(p.q)
    }

    func endAll() {
        for band in live {
            freq[band].endLive()
            gain[band].endLive()
            q[band].endLive()
        }
        live.removeAll()
    }
}

/// What the graph editor needs from the app: the shared selection and
/// readouts, and somewhere to send and commit bands.  The view model is the
/// real host; tests supply one that records instead of talking to a device.
protocol PeqGraphEditorHost: AnyObject {
    var peqSelection: PeqGraphSelection { get }
    var peqLive: PeqLiveReadouts { get }
    func commitGraphBands(ch: Int, _ changes: [(band: Int, params: FilterParams)])
    func sendGraphBandsToDevice(ch: Int, _ changes: [(band: Int, params: FilterParams)])
    func setGraphBandBypass(ch: Int, band: Int, bypass: Bool)
}

extension DSPViewModel: PeqGraphEditorHost {
    /// Commits graph edits to the model and device, mirrored onto the other
    /// half of a linked input pair as the band list does.
    func commitGraphBands(ch: Int, _ changes: [(band: Int, params: FilterParams)]) {
        let mirror = linkedPartner(of: ch)
        for change in changes {
            setFilter(ch: ch, band: change.band, p: change.params)
            if let mirror { setFilter(ch: mirror, band: change.band, p: change.params) }
        }
    }

    /// Drag-time device writes for the graph, mirrored like the commit.
    func sendGraphBandsToDevice(ch: Int, _ changes: [(band: Int, params: FilterParams)]) {
        let mirror = linkedPartner(of: ch)
        for change in changes {
            sendFilterToDevice(ch: ch, band: change.band, p: change.params)
            if let mirror { sendFilterToDevice(ch: mirror, band: change.band, p: change.params) }
        }
    }

    func setGraphBandBypass(ch: Int, band: Int, bypass: Bool) {
        setBandBypass(ch: ch, band: band, bypass: bypass)
        if let mirror = linkedPartner(of: ch) { setBandBypass(ch: mirror, band: band, bypass: bypass) }
    }
}

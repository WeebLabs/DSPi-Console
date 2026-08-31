import Foundation
import IOKit
import IOKit.usb
import AppKit

/// Vendor ID of a board sitting in BOOTSEL.  Deliberately not `USBDevice`'s
/// own `0x2E8B`: a board in bootloader mode is running Raspberry Pi's ROM
/// loader, which enumerates under Raspberry Pi's vendor ID, not ours.
let bootloaderVendorID: UInt16 = 0x2E8A

/// One board in BOOTSEL mode.
struct BootloaderBoard: Equatable {
    enum Chip: Equatable, CaseIterable {
        case rp2040, rp2350

        var bootloaderProductID: UInt16 {
            switch self {
            case .rp2040: return 0x0003
            case .rp2350: return 0x000F
            }
        }

        /// Volume the ROM loader mounts to receive a UF2.
        var volumeName: String {
            switch self {
            case .rp2040: return "RPI-RP2"
            case .rp2350: return "RP2350"
            }
        }

        /// Token in a release asset's filename, e.g. DSPi-RP2350-v1.1.7.uf2.
        var assetToken: String {
            switch self {
            case .rp2040: return "RP2040"
            case .rp2350: return "RP2350"
            }
        }

        var displayName: String {
            switch self {
            case .rp2040: return "RP2040 (Pico)"
            case .rp2350: return "RP2350 (Pico 2)"
            }
        }
    }

    let chip: Chip

    /// Where to write the UF2.  nil when the board is on the USB bus but its
    /// volume has not appeared - either the mount is still a moment away, or
    /// macOS refused us access to removable volumes.  Callers must not treat
    /// that as "no board"; the distinction is what lets the UI say something
    /// useful about a denied permission prompt.
    let volumeURL: URL?
}

/// Finds boards in BOOTSEL mode.  The protocol exists so tests and the
/// developer overrides can drive the installer with no hardware attached.
protocol BootloaderLocating: AnyObject {
    func currentBoards() -> [BootloaderBoard]
    var onChange: (([BootloaderBoard]) -> Void)? { get set }
    func start()
    func stop()
}

/// Locates real boards by pairing two independent signals.
///
/// USB tells us *which chip* with certainty; the mounted volume tells us
/// *where to write*.  Neither alone is enough: the volume name could in
/// principle belong to anything, and the USB match gives no path.  The mount
/// also lags enumeration by a moment, so a board is reported with a nil
/// `volumeURL` until its volume shows up rather than being hidden entirely.
final class SystemBootloaderLocator: BootloaderLocating {
    var onChange: (([BootloaderBoard]) -> Void)?

    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let centre = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.rescan()
            })
        }

        // Mount notifications cover the volume appearing, but nothing tells us
        // a board reached the USB bus without mounting (the permission-denied
        // case, and the moment between enumeration and mount).  A one-second
        // poll fills that gap.  It only runs while a flashing UI is on screen,
        // so the cost is bounded.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.rescan() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        rescan()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        let centre = NSWorkspace.shared.notificationCenter
        observers.forEach { centre.removeObserver($0) }
        observers.removeAll()
    }

    deinit { stop() }

    func currentBoards() -> [BootloaderBoard] {
        let volumes = mountedVolumesByName()
        return BootloaderBoard.Chip.allCases.flatMap { chip -> [BootloaderBoard] in
            let count = usbCount(of: chip)
            guard count > 0 else { return [] }
            // With two identical boards attached macOS renames the second
            // volume ("RPI-RP2 1"), so only the first pairs cleanly.  That is
            // fine: the caller refuses to act on more than one board anyway,
            // and it needs the true count to say so.
            return (0..<count).map { index in
                BootloaderBoard(chip: chip, volumeURL: index == 0 ? volumes[chip.volumeName] : nil)
            }
        }
    }

    /// Reports on every tick rather than only on change: a board sitting on
    /// the bus with no drive yet looks identical scan to scan, and the
    /// installer needs those ticks to decide the drive is not coming.  The
    /// installer drops states that did not change, so this costs no UI churn.
    private func rescan() {
        onChange?(currentBoards())
    }

    /// How many boards of this chip are on the USB bus in BOOTSEL.
    private func usbCount(of chip: BootloaderBoard.Chip) -> Int {
        guard let match = IOServiceMatching(kIOUSBDeviceClassName) as? NSMutableDictionary else { return 0 }
        match[kUSBVendorID] = NSNumber(value: bootloaderVendorID)
        match[kUSBProductID] = NSNumber(value: chip.bootloaderProductID)

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMasterPortDefault, match as CFDictionary, &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }

        var count = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            count += 1
            IOObjectRelease(service)
        }
        return count
    }

    private func mountedVolumesByName() -> [String: URL] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        var byName: [String: URL] = [:]
        for url in urls {
            guard let name = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName else { continue }
            // First writer wins, so an identically named second mount cannot
            // displace the one we already paired.
            if byName[name] == nil { byName[name] = url }
        }
        return byName
    }
}

/// Test and developer-override double.  Set `boards`, then call `emit()` to
/// drive the installer through any state without hardware.
final class FakeBootloaderLocator: BootloaderLocating {
    var onChange: (([BootloaderBoard]) -> Void)?
    var boards: [BootloaderBoard] = []
    private(set) var started = false

    init(boards: [BootloaderBoard] = []) { self.boards = boards }

    func currentBoards() -> [BootloaderBoard] { boards }
    func start() { started = true; onChange?(boards) }
    func stop() { started = false }
    func emit() { onChange?(boards) }
}

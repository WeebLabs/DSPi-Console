//
//  LinkDiscovery.swift
//  DSPi Console
//
//  Advertises the hub on the local network as a DNS-SD (Bonjour) service so
//  clients and other Consoles find it without a typed address.  Uses the
//  system dnssd API directly (DNSServiceRegister), which is dependency-free and
//  lets us update the TXT record as devices come and go.  See spec section 3.1.
//

import Foundation
import dnssd

/// The values that go in the service's TXT record (spec 3.1).  All are ASCII;
/// a client ignores keys it does not know.
struct LinkAdvertisement {
    var version: Int = 1                 // highest protocol major served
    var hubID: String                    // stable lowercase UUID
    var kind: String = "console"         // console or bridge
    var auth: String                     // none or pin
    var deviceCount: Int                 // devices currently shared
    var serials: [String]                // shared device serials, omitted if too long
    var tls: Bool = false
    var web: Bool = false
    var path: String? = nil              // WS path if not the default

    /// Build the TXT record.  The `d` (serials) key is dropped if it would push
    /// the record past a safe size, exactly as the spec allows.
    func txtData() -> Data {
        var pairs: [(String, String)] = [
            ("v", String(version)),
            ("hid", hubID),
            ("kind", kind),
            ("auth", auth),
            ("n", String(deviceCount)),
        ]
        if tls { pairs.append(("tls", "1")) }
        if web { pairs.append(("web", "1")) }
        if let path = path { pairs.append(("path", path)) }
        let joined = serials.joined(separator: ",")
        if !joined.isEmpty {
            // Each TXT entry is length-prefixed; keep the whole record modest.
            let tentative = pairs.reduce(0) { $0 + 1 + $1.0.count + 1 + $1.1.count } + 1 + 2 + joined.count
            if tentative < 400 { pairs.append(("d", joined)) }
        }
        return Self.encodeTXT(pairs)
    }

    /// DNS-SD TXT wire form: each entry is one length byte then "key=value".
    private static func encodeTXT(_ pairs: [(String, String)]) -> Data {
        var data = Data()
        for (k, v) in pairs {
            let entry = "\(k)=\(v)"
            let bytes = Array(entry.utf8).prefix(255)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data
    }
}

final class LinkDiscovery {
    private var serviceRef: DNSServiceRef?
    private let queue = DispatchQueue(label: "com.foxdac.link.dnssd")
    private(set) var isAdvertising = false

    /// Service type per spec 3.1.  The default port is the decimal of the USB
    /// VID 0x2E8B.
    static let serviceType = "_dspi._tcp"
    static let defaultPort = 11915

    /// Start advertising.  `name` is the user-visible instance name; `port` the
    /// listening port; `ad` the TXT record.  Safe to call again to replace an
    /// existing registration.
    func start(name: String, port: Int, ad: LinkAdvertisement) {
        stop()
        let txt = ad.txtData()
        var ref: DNSServiceRef?
        let result: DNSServiceErrorType = txt.withUnsafeBytes { raw in
            DNSServiceRegister(
                &ref,
                0,                                   // flags
                0,                                   // all interfaces
                name,                                // service name
                Self.serviceType,
                nil,                                 // default domain (.local)
                nil,                                 // this host
                UInt16(port).bigEndian,              // port in network byte order
                UInt16(txt.count),
                raw.baseAddress,
                nil, nil)                            // no callback
        }
        guard result == kDNSServiceErr_NoError, let ref = ref else { return }
        serviceRef = ref
        isAdvertising = true
        // Service the connection so the registration stays live.
        DNSServiceSetDispatchQueue(ref, queue)
    }

    /// Replace just the TXT record on the live registration (device count or
    /// serials changed), without tearing the service down.
    func updateTXT(_ ad: LinkAdvertisement) {
        guard let ref = serviceRef else { return }
        let txt = ad.txtData()
        _ = txt.withUnsafeBytes { raw in
            DNSServiceUpdateRecord(ref, nil, 0, UInt16(txt.count), raw.baseAddress, 0)
        }
    }

    func stop() {
        if let ref = serviceRef {
            DNSServiceRefDeallocate(ref)
            serviceRef = nil
        }
        isAdvertising = false
    }

    deinit { stop() }
}

//
//  LinkTokenStore.swift
//  DSPi Console
//
//  Keeps the pairing token for each hub in the login keychain, keyed by the
//  hub's id rather than its address, so a hub that moves to a new IP is still
//  recognised.  See spec 6.2.
//

import Foundation
import Security

final class LinkTokenStore {
    private let service: String

    /// `service` namespaces the keychain items; tests pass their own so they
    /// never touch the real tokens.
    init(service: String = "com.weeblabs.dspi-console.link") {
        self.service = service
    }

    func token(forHub hubID: String) -> String? {
        var query = baseQuery(hubID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setToken(_ token: String, forHub hubID: String) {
        let data = Data(token.utf8)
        var query = baseQuery(hubID)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    func removeToken(forHub hubID: String) {
        SecItemDelete(baseQuery(hubID) as CFDictionary)
    }

    private func baseQuery(_ hubID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: hubID.lowercased()]
    }
}

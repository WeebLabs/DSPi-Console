// Signs DSPi Console release zips so the in-app updater can tell a genuine
// release from a tampered one.  The private key lives only in the login
// keychain of the machine that cuts releases; the app embeds the public key
// (AppUpdateInstaller.publicKey).
//
//   swift Tools/UpdateSigning/update-signing.swift generate
//   swift Tools/UpdateSigning/update-signing.swift public-key
//   swift Tools/UpdateSigning/update-signing.swift sign <zip>     (writes <zip>.sig)
//   swift Tools/UpdateSigning/update-signing.swift verify <zip>
//   swift Tools/UpdateSigning/update-signing.swift export > backup.txt
//   swift Tools/UpdateSigning/update-signing.swift import < backup.txt
//
// Losing the key means users have to update by hand once, to a build that
// embeds a new public key, so keep a backup from `export` somewhere safe.

import CryptoKit
import Foundation
import Security

let service = "DSPi Console update signing key"
let account = "ed25519"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
}

func storeKey(_ key: Curve25519.Signing.PrivateKey) {
    let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrLabel as String: service,
        kSecValueData as String: key.rawRepresentation,
    ]
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Could not store the key in the keychain (OSStatus \(status)).") }
}

func requireKey() -> Curve25519.Signing.PrivateKey {
    guard let key = loadKey() else { fail("No signing key in the keychain. Run `generate`, or `import` a backup.") }
    return key
}

func read(_ path: String) -> Data {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { fail("Cannot read \(path)") }
    return data
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    if loadKey() != nil { fail("A signing key already exists; refusing to replace it.") }
    let key = Curve25519.Signing.PrivateKey()
    storeKey(key)
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "public-key":
    print(requireKey().publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard args.count == 2, let path = args.last else { fail("usage: sign <zip>") }
    let data = read(path)
    let signature = try requireKey().signature(for: data)
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: path + ".sig"))
    print("Wrote \(path).sig")

case "verify":
    guard args.count == 2, let path = args.last else { fail("usage: verify <zip>") }
    let data = read(path)
    let text = String(decoding: read(path + ".sig"), as: UTF8.self)
    guard let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("Bad signature file") }
    guard requireKey().publicKey.isValidSignature(signature, for: data) else { fail("Signature does NOT match.") }
    print("Signature OK")

case "export":
    print(requireKey().rawRepresentation.base64EncodedString())

case "import":
    if loadKey() != nil { fail("A signing key already exists; refusing to replace it.") }
    let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let raw = Data(base64Encoded: line),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("Not a valid key backup.") }
    storeKey(key)
    print(key.publicKey.rawRepresentation.base64EncodedString())

default:
    fail("usage: update-signing.swift generate | public-key | sign <zip> | verify <zip> | export | import")
}

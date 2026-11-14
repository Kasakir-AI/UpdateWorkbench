// Update Workbench release signing key (Ed25519, the format Sparkle uses).
//
//   xcrun swift tools/release-key.swift generate     create the key in the login Keychain, print the public key
//   xcrun swift tools/release-key.swift public-key   print the public key (base64)
//   xcrun swift tools/release-key.swift sign FILE    print the base64 signature of FILE
//
// The private key never leaves the login Keychain; only the public key is committed
// (Resources/release-public-key.txt) and written into Info.plist by build.sh. Losing the private key
// means installed copies can no longer update themselves in place: back it up with Keychain Access.
import CryptoKit
import Foundation
import Security

let service = "Update Workbench release signing key"
let account = "ed25519"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func storedKey() -> Curve25519.Signing.PrivateKey? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data, let raw = Data(base64Encoded: data) else {
        fail("Couldn't read the release key from the Keychain (status \(status)).")
    }
    do { return try Curve25519.Signing.PrivateKey(rawRepresentation: raw) } catch { fail("The stored release key is invalid.") }
}

func requireKey() -> Curve25519.Signing.PrivateKey {
    guard let key = storedKey() else { fail("No release key in the Keychain. Run: xcrun swift tools/release-key.swift generate") }
    return key
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate":
    guard storedKey() == nil else { fail("A release key already exists. Refusing to replace it.") }
    let key = Curve25519.Signing.PrivateKey()
    let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                               kSecAttrLabel as String: service, kSecValueData as String: Data(key.rawRepresentation.base64EncodedString().utf8),
                               kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Couldn't save the release key to the Keychain (status \(status)).") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public-key":
    print(requireKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard arguments.count == 2 else { fail("Usage: release-key.swift sign FILE") }
    let data: Data
    do { data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe) } catch { fail("Couldn't read \(arguments[1]).") }
    let key = requireKey()
    let signature = try! key.signature(for: data)
    guard key.publicKey.isValidSignature(signature, for: data) else { fail("The signature didn't verify.") }
    print(signature.base64EncodedString())
default:
    fail("Usage: release-key.swift generate | public-key | sign FILE")
}

// Exports one signing identity, its certificate and private key, as a .p12 for the release
// workflow. `security export` can only export every identity at once, which would ask once
// for each key in the keychain; this asks once.
//
//   P12_PASSWORD=… export-identity <SHA-1 of the certificate> <out.p12>
//
// It searches your keychains, or only the one at KEYCHAIN when that's set.
import CryptoKit
import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
let environment = ProcessInfo.processInfo.environment
guard arguments.count == 3, let password = environment["P12_PASSWORD"] else {
    fail("usage: P12_PASSWORD=… export-identity <SHA-1 of the certificate> <out.p12>")
}
let hash = arguments[1].uppercased()

var query: [CFString: Any] = [
    kSecClass: kSecClassIdentity,
    kSecMatchLimit: kSecMatchLimitAll,
    kSecReturnRef: true,
]
if let path = environment["KEYCHAIN"] {
    var keychain: SecKeychain?
    guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else {
        fail("Couldn't open the keychain at \(path).")
    }
    query[kSecMatchSearchList] = [keychain]
}

var found: CFTypeRef?
let identities = SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess
    ? found as? [SecIdentity] ?? [] : []
let identity = identities.first { identity in
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
        return false
    }
    let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
    return digest.map { String(format: "%02X", $0) }.joined() == hash
}
guard let identity else { fail("No identity with certificate \(hash) in your keychains.") }

var parameters = SecItemImportExportKeyParameters()
parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
parameters.passphrase = Unmanaged.passUnretained(password as CFString)
var exported: CFData?
let status = SecItemExport(identity, .formatPKCS12, [], &parameters, &exported)
guard status == errSecSuccess, let exported else {
    let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
    fail("Couldn't export the identity: \(reason)")
}

do {
    try (exported as Data).write(to: URL(fileURLWithPath: arguments[2]), options: .withoutOverwriting)
} catch {
    fail("Couldn't write \(arguments[2]): \(error.localizedDescription)")
}

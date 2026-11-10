import Foundation
import Security
import NachoComboCore

/// The TLS identity of the LAN mode: one self-signed ECDSA P-256 certificate whose private key lives in the user's
/// login Keychain (never in a file, never printed). Clients pin the SHA-256 fingerprint of the certificate, which the
/// settings card shows.
///
/// - Created on first use of the LAN mode and reused afterwards, so the fingerprint stays stable across restarts.
///   It lists this Mac's private addresses and `<name>.local` as subject alternative names. It is NOT renewed when
///   they change (that would change the fingerprint behind the clients' back); the card tells the owner to regenerate.
/// - `removeAll()` deletes key and certificate; the next start creates a new pair (new fingerprint).
/// - Any failure is returned as a message. There is no fallback to plain HTTP.
///
/// Not run on a Mac yet - written to compile. Keychain access from a freshly rebuilt, ad-hoc signed app may show a
/// system prompt once; that is unverified (see docs/COMPUTER-USE-MCP.md).
struct ComputerUseTLSIdentity {
    let identity: SecIdentity
    let certificateDER: Data
    /// SHA-256 of the DER certificate, lowercase hex without separators (64 characters).
    var fingerprint: String { SHA256.hex(of: certificateDER) }
    var fingerprintDisplay: String { ComputerUseCertificate.colonSeparated(hex: fingerprint) }
    var pem: String { ComputerUseCertificate.pem(der: certificateDER) }
    /// Names the certificate lists (addresses and `.local` name it was created for).
    var subjectAltNames: ComputerUseCertificate.SubjectAltNames? { ComputerUseCertificate.subjectAltNames(der: certificateDER) }
}

enum ComputerUseTLS {
    static let label = "Nacho Combo Computer Use (LAN TLS)"
    private static let keyTag = Data("com.mafianacho.nachocombo.computeruse.tls".utf8)
    private static let validityDays: TimeInterval = 3650

    /// The stored identity, or a new one when none exists. Returns a message on failure.
    static func loadOrCreate() -> (identity: ComputerUseTLSIdentity?, problem: String?) {
        if let existing = load() { return (existing, nil) }
        do { return (try create(), nil) } catch let error as TLSError { return (nil, error.message) } catch {
            return (nil, "Could not create the TLS certificate: \(error)")
        }
    }

    static func load() -> ComputerUseTLSIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item = item,
              CFGetTypeID(item) == SecIdentityGetTypeID() else { return nil }
        let identity = item as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let cert = certificate else { return nil }
        return ComputerUseTLSIdentity(identity: identity, certificateDER: SecCertificateCopyData(cert) as Data)
    }

    struct TLSError: Error { let message: String }

    static func create(names: (dns: [String], ips: [String]) = ComputerUseLAN.certificateNames()) throws -> ComputerUseTLSIdentity {
        removeAll()                                   // never leave two pairs behind

        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrLabel as String: label,
            ] as [String: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error) else {
            throw TLSError(message: "Could not create the TLS key: \(describe(error))")
        }
        // From here on a failure removes what was created.
        do {
            guard let publicKey = SecKeyCopyPublicKey(privateKey),
                  let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
                throw TLSError(message: "Could not read the TLS public key: \(describe(error))")
            }
            var serial = Data(count: 16)
            let status = serial.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            guard status == errSecSuccess else { throw TLSError(message: "Could not get random bytes for the TLS serial number") }

            let now = Date()
            let parameters = ComputerUseCertificate.Parameters(
                commonName: "Nacho Combo Computer Use",
                publicKeyPoint: point,
                notBefore: now.addingTimeInterval(-86_400),
                notAfter: now.addingTimeInterval(validityDays * 86_400),
                serial: serial,
                dnsNames: names.dns,
                ipAddresses: names.ips)
            var signError: Unmanaged<CFError>?
            guard let der = ComputerUseCertificate.makeDER(parameters, sign: { tbs in
                SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &signError) as Data?
            }) else {
                throw TLSError(message: "Could not sign the TLS certificate: \(describe(signError))")
            }
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw TLSError(message: "The TLS certificate format is invalid")
            }
            let add: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
                kSecAttrLabel as String: label,
            ]
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw TLSError(message: "Could not save the TLS certificate to the keychain (OSStatus \(added))") }
            guard let stored = load() else { throw TLSError(message: "Could not read the stored TLS certificate and key as a pair") }
            return stored
        } catch {
            removeAll()
            throw error
        }
    }

    /// Deletes the certificate and the private key of the LAN mode.
    static func removeAll() {
        let certificate: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label]
        _ = SecItemDelete(certificate as CFDictionary)
        let key: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        _ = SecItemDelete(key as CFDictionary)
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error = error else { return "Unknown error" }
        return (error.takeRetainedValue() as Error).localizedDescription
    }
}

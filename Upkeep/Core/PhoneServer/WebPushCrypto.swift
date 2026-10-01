import CryptoKit
import Foundation

/// Web Push message encryption (RFC 8291) and VAPID tokens (RFC 8292), independent of the app
/// so they can be checked against the RFC test vectors.
enum WebPushCrypto {
    /// RFC 8291 message encryption with a single `aes128gcm` record.
    static func encrypt(_ plaintext: Data, p256dh: Data, auth: Data,
                        ephemeral: P256.KeyAgreement.PrivateKey = .init(),
                        salt: Data = randomBytes(16)) throws -> Data {
        let uaPublic = try P256.KeyAgreement.PublicKey(x963Representation: p256dh)
        let asPublic = ephemeral.publicKey.x963Representation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: uaPublic)

        let keyInfo = Data("WebPush: info".utf8) + [0] + p256dh + asPublic
        let ikm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: auth, sharedInfo: keyInfo, outputByteCount: 32)
        let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                         info: Data("Content-Encoding: aes128gcm".utf8) + [0], outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                           info: Data("Content-Encoding: nonce".utf8) + [0], outputByteCount: 12)
        let sealed = try AES.GCM.seal(plaintext + [2], using: cek,
                                      nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }))

        var header = salt
        header.append(contentsOf: [0x00, 0x00, 0x10, 0x00]) // record size 4096
        header.append(UInt8(asPublic.count))
        header.append(asPublic)
        return header + sealed.ciphertext + sealed.tag
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// ES256 JWT valid for 12 hours, for the `Authorization: vapid t=…, k=…` header.
    static func vapidToken(audience: String, subject: String, key: P256.Signing.PrivateKey, now: Date = Date()) throws -> String {
        let header = base64URLEncode(Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8))
        let claims: [String: Any] = ["aud": audience, "exp": Int(now.timeIntervalSince1970) + 12 * 3600, "sub": subject]
        let payload = base64URLEncode(try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys, .withoutEscapingSlashes]))
        let input = "\(header).\(payload)"
        let signature = try key.signature(for: Data(input.utf8)).rawRepresentation
        return "\(input).\(base64URLEncode(signature))"
    }
}

func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

enum Base64URLError: Error { case invalid }

func base64URLDecode(_ text: String) throws -> Data {
    var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    guard let data = Data(base64Encoded: s) else { throw Base64URLError.invalid }
    return data
}

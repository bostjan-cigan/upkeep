import Foundation
import Security
import SystemConfiguration

/// The home certificate authority and the server certificate phones connect to.
///
/// iOS only runs a PWA's service worker from a trusted HTTPS origin, so this Mac acts as a tiny
/// private CA: phones install and trust its root once (a configuration profile), and the server
/// certificate it signs can then be replaced at will without touching the phones again.
/// Made with the system's `/usr/bin/openssl`; kept in Application Support › Upkeep › TLS.
enum Certificates {
    /// iOS rejects server certificates valid for longer than 825 days.
    static let serverDays = 825
    static let caDays = 3650
    private static let p12Password = "upkeep"

    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Upkeep/TLS", directoryHint: .isDirectory)
    }

    private static var caKey: URL { folder.appending(path: "ca.key") }
    private static var caPEM: URL { folder.appending(path: "ca.pem") }
    private static var caDER: URL { folder.appending(path: "ca.der") }
    private static var serverKey: URL { folder.appending(path: "server.key") }
    private static var serverPEM: URL { folder.appending(path: "server.pem") }
    private static var serverP12: URL { folder.appending(path: "server.p12") }
    private static var serverHosts: URL { folder.appending(path: "server.hosts") }

    /// "Bostjans-MacBook-Air.local", the Mac's own Bonjour name.
    static var localHostName: String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
    }

    /// Every name phones may reach this Mac at: its phone name first (the certificate's CN), then
    /// the rest. The same CA signs them all, so a phone that trusts it trusts every name.
    static func hostNames(phoneHost: String, legacy: Bool) -> [String] {
        var names = [phoneHost]
        if legacy { names.append(PhoneHostName.legacy) }
        if let local = localHostName, !names.contains(local) { names.append(local) }
        return names
    }

    enum CertError: LocalizedError {
        case openssl(String), noIdentity(OSStatus)
        var errorDescription: String? {
            switch self {
            case .openssl(let m): "Couldn't make the certificate: \(m)"
            case .noIdentity(let s): "Couldn't load the certificate (\(s))."
            }
        }
    }

    /// Makes the CA once and (re)issues the server certificate when it's missing, close to
    /// expiry or no longer covers this Mac's names. Returns the identity to serve TLS with.
    static func prepareIdentity(hostNames: [String]) throws -> SecIdentity {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: caKey.path) || !fm.fileExists(atPath: caPEM.path) {
            try makeCA()
        }
        let hosts = hostNames.joined(separator: ",")
        let currentHosts = (try? String(contentsOf: serverHosts, encoding: .utf8)) ?? ""
        let expiring = (try? openssl(["x509", "-in", serverPEM.path, "-noout", "-checkend", "\(30 * 24 * 3600)"])) == nil
        if !fm.fileExists(atPath: serverP12.path) || currentHosts != hosts || expiring {
            try makeServerCertificate(hostNames: hostNames)
            try hosts.write(to: serverHosts, atomically: true, encoding: .utf8)
        }
        return try loadIdentity()
    }

    /// The CA certificate (DER) for the configuration profile.
    static func caCertificateDER() throws -> Data {
        if !FileManager.default.fileExists(atPath: caDER.path) {
            try openssl(["x509", "-in", caPEM.path, "-outform", "der", "-out", caDER.path])
        }
        return try Data(contentsOf: caDER)
    }

    /// Starts over with a new CA; every phone has to trust the new one.
    static func reset() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Making

    private static func makeCA() throws {
        let config = folder.appending(path: "ca.cnf")
        let computer = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        try """
        [req]
        distinguished_name = dn
        x509_extensions = v3_ca
        prompt = no
        [dn]
        CN = Upkeep Home CA (\(computer.replacingOccurrences(of: "/", with: "-")))
        O = Upkeep
        [v3_ca]
        basicConstraints = critical, CA:TRUE
        keyUsage = critical, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        """.write(to: config, atomically: true, encoding: .utf8)
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "\(caDays)",
                     "-keyout", caKey.path, "-out", caPEM.path, "-config", config.path])
        try? FileManager.default.removeItem(at: caDER)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKey.path)
    }

    private static func makeServerCertificate(hostNames: [String]) throws {
        let reqConfig = folder.appending(path: "server.cnf")
        let extConfig = folder.appending(path: "server-ext.cnf")
        let csr = folder.appending(path: "server.csr")
        try """
        [req]
        distinguished_name = dn
        prompt = no
        [dn]
        CN = \(hostNames.first ?? PhoneHostName.legacy)
        O = Upkeep
        """.write(to: reqConfig, atomically: true, encoding: .utf8)
        let sans = hostNames.map { "DNS:\($0)" }.joined(separator: ",")
        try """
        [v3]
        basicConstraints = critical, CA:FALSE
        keyUsage = critical, digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = \(sans)
        authorityKeyIdentifier = keyid
        """.write(to: extConfig, atomically: true, encoding: .utf8)
        try openssl(["req", "-newkey", "rsa:2048", "-nodes", "-sha256", "-keyout", serverKey.path,
                     "-out", csr.path, "-config", reqConfig.path])
        try openssl(["x509", "-req", "-in", csr.path, "-CA", caPEM.path, "-CAkey", caKey.path,
                     "-set_serial", "\(Int.random(in: 1...Int(Int32.max)))", "-days", "\(serverDays)", "-sha256",
                     "-extfile", extConfig.path, "-extensions", "v3", "-out", serverPEM.path])
        try openssl(["pkcs12", "-export", "-inkey", serverKey.path, "-in", serverPEM.path, "-certfile", caPEM.path,
                     "-name", "Upkeep", "-out", serverP12.path, "-passout", "pass:\(p12Password)"])
        try? FileManager.default.removeItem(at: csr)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: serverKey.path)
    }

    private static func loadIdentity() throws -> SecIdentity {
        let data = try Data(contentsOf: serverP12)
        var items: CFArray?
        // In memory only: nothing is added to the user's keychain.
        let options: [String: Any] = [kSecImportExportPassphrase as String: p12Password,
                                      kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]],
              let first = array.first, let identity = first[kSecImportItemIdentity as String] else {
            throw CertError.noIdentity(status)
        }
        return identity as! SecIdentity
    }

    @discardableResult
    private static func openssl(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/openssl")
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CertError.openssl(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    // MARK: Profile

    /// A configuration profile that installs the CA on an iPhone or iPad.
    static func mobileConfig() throws -> Data {
        let der = try caCertificateDER()
        let computer = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        let certUUID = UUID(uuidString: stableUUID(from: der, salt: "cert")) ?? UUID()
        let profileUUID = UUID(uuidString: stableUUID(from: der, salt: "profile")) ?? UUID()
        let plist: [String: Any] = [
            "PayloadContent": [[
                "PayloadCertificateFileName": "upkeep-home-ca.cer",
                "PayloadContent": der,
                "PayloadDescription": "Lets this device open Upkeep served by \(computer) on your home network.",
                "PayloadDisplayName": "Upkeep Home CA",
                "PayloadIdentifier": "com.bostjancigan.upkeep.ca.\(certUUID.uuidString)",
                "PayloadType": "com.apple.security.root",
                "PayloadUUID": certUUID.uuidString,
                "PayloadVersion": 1,
            ]],
            "PayloadDescription": "Trust Upkeep on \(computer). After installing, turn it on in Settings › General › About › Certificate Trust Settings.",
            "PayloadDisplayName": "Upkeep on \(computer)",
            "PayloadIdentifier": "com.bostjancigan.upkeep.profile.\(profileUUID.uuidString)",
            "PayloadOrganization": "Upkeep",
            "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration",
            "PayloadUUID": profileUUID.uuidString,
            "PayloadVersion": 1,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// The same CA always yields the same profile ids, so reinstalling replaces rather than duplicates.
    private static func stableUUID(from data: Data, salt: String) -> String {
        let hex = SyncCoding.sha256(salt + data.base64EncodedString())
        let c = Array(hex.prefix(32))
        return "\(String(c[0..<8]))-\(String(c[8..<12]))-4\(String(c[13..<16]))-a\(String(c[17..<20]))-\(String(c[20..<32]))".uppercased()
    }
}

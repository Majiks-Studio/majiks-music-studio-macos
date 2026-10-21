import Foundation
import CryptoKit

enum LicenseTier: UInt8, Equatable {
    case free = 0x00
    case publisher = 0x02
}

@MainActor
final class LicenseManager: ObservableObject {
    @Published private(set) var tier: LicenseTier = .free
    @Published private(set) var licenseKey: String = ""

    var isLicensed: Bool { tier != .free }
    var canPublish: Bool { true }

    private let service = "com.majik.musicstudio.license"
    private let account = "license_key"

    /// Shared license file readable by all Majiks apps
    private var sharedLicenseURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("Majiks/license.json")
    }

    // Production Ed25519 public key for license verification
    // Corresponds to license_public.pem in project root
    private let productionPublicKey = "F96/Sz33tPUKErbD8mHg3Ib4TzC5YnVG3gDW2gGYi2w="

    private var publicKeyBase64: String {
#if DEBUG
        // Allow runtime override via environment variable (testing only)
        let envKey = ProcessInfo.processInfo.environment["MAJIK_LICENSE_PUBLIC_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !envKey.isEmpty { return envKey }
#endif
        return productionPublicKey
    }

    init() {
        load()
    }

    func load() {
#if DEBUG
        if ProcessInfo.processInfo.environment["MAJIKS_DEV_BYPASS_LICENSE"] == "1" {
            tier = .publisher
            licenseKey = "DEV-BYPASS"
            return
        }
#endif

        do {
            if let stored = try KeychainStore.get(account: account, service: service) {
                licenseKey = stored
                tier = validate(key: stored) ?? .free
            } else if let shared = readSharedLicense() {
                // Fallback: another Majiks app may have activated
                licenseKey = shared
                tier = validate(key: shared) ?? .free
                if tier != .free {
                    // Promote to Keychain for faster future loads
                    try? KeychainStore.set(shared, account: account, service: service)
                }
            } else {
                tier = .free
                licenseKey = ""
            }
        } catch {
            tier = .free
            licenseKey = ""
        }
    }

    func validateAndStore(key: String) -> Bool {
        let normalized = normalize(key: key)
        guard let validatedTier = validate(key: normalized) else {
            return false
        }
        do {
            try KeychainStore.set(normalized, account: account, service: service)
            writeSharedLicense(normalized)
            licenseKey = normalized
            tier = validatedTier
            return true
        } catch {
            return false
        }
    }

    func clearLicense() {
        try? KeychainStore.delete(account: account, service: service)
        if let url = sharedLicenseURL {
            try? FileManager.default.removeItem(at: url)
        }
        licenseKey = ""
        tier = .free
    }

    private func normalize(key: String) -> String {
        // Don't uppercase! Base64url is case-sensitive
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    private func validate(key: String) -> LicenseTier? {
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
              publicKeyData.count == 32
        else {
            return nil
        }

        // Ed25519 signatures are always 64 bytes = 86 chars in base64url (no padding)
        // Extract last 86 characters as signature (since base64url can contain hyphens)
        let signatureLength = 86
        guard key.count > signatureLength + 5 else { return nil } // MS1-X-sig minimum

        let signature = String(key.suffix(signatureLength))
        let prefixAndPayload = String(key.dropLast(signatureLength + 1)) // Drop signature + hyphen

        // Extract prefix and payload
        let parts = prefixAndPayload.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, parts[0] == "MS1" else {
            return nil
        }

        let payload = String(parts[1])

        guard let payloadData = Data(base64Encoded: base64URLToBase64(payload)),
              let signatureData = Data(base64Encoded: base64URLToBase64(signature))
        else {
            return nil
        }

        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            guard publicKey.isValidSignature(signatureData, for: payloadData) else {
                return nil
            }

            // Any valid signed key grants publisher access.
            // Tier byte 0x01 (legacy arteest) and 0x02 (publisher) both map to publisher.
            // Legacy keys without tier encoding are also grandfathered.
            return .publisher
        } catch {
            return nil
        }
    }

    // MARK: - Shared license file (cross-app)

    private func readSharedLicense() -> String? {
        guard let url = sharedLicenseURL,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["key"] as? String, !key.isEmpty
        else { return nil }
        return key
    }

    private func writeSharedLicense(_ key: String) {
        guard let url = sharedLicenseURL else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "key": key,
            "activated_at": ISO8601DateFormatter().string(from: Date()),
            "app": "music-studio"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func base64URLToBase64(_ value: String) -> String {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }
        return base64
    }
}

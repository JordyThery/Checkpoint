import Foundation

// The device record Checkpoint works in, and the value types it is built
// from. Product-neutral on purpose: each client maps its own API onto these,
// so a new product is a client and a capability set rather than a second
// shape for every view to handle. Fields only one product reports are
// optional and say so.

nonisolated enum DeviceKind: String, Sendable {
    case computer
    case mobileDevice
}

struct ManagedDeviceInfo: Sendable {
    /// The record's identifier in the product it came from: a Jamf Pro
    /// computer or mobile device ID, a Jamf School UDID, or an Intune managed
    /// device ID. Opaque here — only that product's client interprets it.
    var recordID: String
    var kind: DeviceKind
    var udid: String?
    /// UUID used by the modern /v2/mdm/commands endpoint.
    var managementID: String?
    var name: String?
    var siteID: String?
    var siteName: String?
    /// Escrowed unlock token (mobile devices), needed for Clear Passcode.
    var unlockToken: String?
    /// FileVault state (computers), from the inventory record rather than the
    /// recovery-key endpoint, so an ordinary lookup can show it. Intune fills
    /// only the flag, which the state reads as its fallback.
    var encryption: DiskEncryptionState?
    /// Passcode and encryption state (mobile devices).
    var security: MobileSecurityState?
    /// The installed OS, from inventory. Also what distinguishes an enforced
    /// update the device already has from one it still owes.
    var osVersion: String?
    /// Jamf Pro only; Jamf School reports no build.
    var osBuild: String?
    /// Jamf School only, which names the OS instead of reporting a build.
    var osName: String?
    var lastEnrolledDate: String?
    var reportDate: String?
    /// Last check-in (Jamf binary; computers only).
    var lastContactTime: String?
    /// Last Contact inventory attribute (Jamf Pro 11.30+, both kinds).
    var lastContact: String?
    var mdmProfileExpiration: String?
    var prestageID: String?
    var prestageName: String?
    var webURL: URL?
    /// Jamf School only: the location the record belongs to, which is that
    /// product's equivalent of a site.
    var locationID: String?
    var locationName: String?
    /// Jamf School and Intune: whether the device is still managed and
    /// supervised.
    var isManaged: Bool?
    var isSupervised: Bool?
    /// Intune only: the device's compliance verdict, already worded for
    /// display. No other product evaluates compliance.
    var complianceSummary: String?
}

/// A Mac's FileVault state, as reported by inventory.
struct DiskEncryptionState: Sendable {
    /// Jamf Pro's `fileVault2Enabled` flag. Not trustworthy on its own: it
    /// reports false for Macs encrypted by the user rather than through Jamf
    /// Pro, even with the boot partition fully encrypted and a valid key
    /// escrowed. Kept only as a fallback for when the partition state is
    /// missing or unknown.
    let fileVaultEnabled: Bool?
    /// Boot partition state, e.g. ENCRYPTED, ENCRYPTING or RESTART_NEEDED.
    /// This is the authoritative signal.
    let bootPartitionState: String?
    let bootPartitionPercent: Int?
    /// Jamf Pro's assessment of the escrowed personal key, e.g. VALID.
    let recoveryKeyValidity: String?

    nonisolated enum Status: Sendable {
        case enabled
        case notEnabled
        /// Encrypting, decrypting, or waiting for a restart.
        case inProgress
        case ineligible
        case unknown
    }

    var status: Status {
        switch bootPartitionState {
        case "ENCRYPTED": .enabled
        case "UNENCRYPTED", "DECRYPTED": .notEnabled
        case "INELIGIBLE": .ineligible
        case "ENCRYPTING", "DECRYPTING", "OPTIMIZING", "RESTART_NEEDED",
             "ENCRYPTING_PAUSED", "DECRYPTING_PAUSED": .inProgress
        default:
            // UNKNOWN or absent: the flag is all there is.
            switch fileVaultEnabled {
            case true: .enabled
            case false: .notEnabled
            default: .unknown
            }
        }
    }

    /// Whether FileVault is on, so far as can be told. Nil while in progress
    /// or unknown, which callers should treat as "do not disable anything".
    var isEncrypted: Bool? {
        switch status {
        case .enabled: true
        case .notEnabled, .ineligible: false
        case .inProgress, .unknown: nil
        }
    }

    var displaySummary: String {
        switch status {
        case .enabled: return "Enabled"
        case .notEnabled: return "Not enabled"
        case .ineligible: return "Ineligible"
        case .unknown: return "—"
        case .inProgress:
            // The state is the whole story here, e.g. Encrypting 42%.
            guard let state = bootPartitionState.map(DisplayText.sentenceCase) else { return "In progress" }
            guard let percent = bootPartitionPercent,
                  state.hasSuffix("ing") || state.hasSuffix("paused") else { return state }
            return "\(state) \(percent)%"
        }
    }

    /// Key validity only means something once the disk is encrypted: an
    /// unencrypted Mac reports UNKNOWN, which would read as a problem.
    var keyValidityWarning: String? {
        guard status == .enabled,
              let validity = recoveryKeyValidity,
              !["VALID", "NOT_APPLICABLE"].contains(validity) else { return nil }
        return "Recovery key \(validity.lowercased())"
    }
}

/// A mobile device's passcode and encryption state.
struct MobileSecurityState: Sendable {
    let passcodePresent: Bool?
    /// Compliant with Jamf Pro's own requirements.
    let passcodeCompliant: Bool?
    /// Compliant with the passcode profile scoped to the device.
    let passcodeCompliantWithProfile: Bool?
    let hardwareEncryption: Int?
}

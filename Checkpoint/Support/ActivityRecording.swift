import Foundation
import JTKit

// Checkpoint's entries in JTKit's activity log. Requests and sign-ins are
// recorded by JTKit's request recorder; this adds what the user asked for,
// in the app's own words ("Action" entries).

/// Which service an entry concerns. The log names it as JTKit names the
/// service (`ConnectionService.displayName`), so the app's entries and
/// JTKit's requests share one Source.
nonisolated enum ActivityService: Sendable {
    case appleBusiness
    case appleSchool
    case jamfPro
    case jamfSchool
    case intune

    /// The service's name in the log.
    var label: String {
        switch self {
        case .appleBusiness: ConnectionService.appleBusinessManager.displayName
        case .appleSchool: ConnectionService.appleSchoolManager.displayName
        case .jamfPro: ConnectionService.jamfPro.displayName
        case .jamfSchool: ConnectionService.jamfSchool.displayName
        case .intune: ConnectionService.intune.displayName
        }
    }

    /// Both Apple services, as opposed to the device management ones.
    /// Enumerated rather than tested against one case, because it decides
    /// which connection name an entry is attributed to: treating Jamf School
    /// as an Apple service would label its requests with the Apple
    /// organization.
    var isAppleOrganization: Bool {
        switch self {
        case .appleBusiness, .appleSchool: true
        case .jamfPro, .jamfSchool, .intune: false
        }
    }
}

extension MDMProduct {
    /// How traffic to this product is labeled in the log. Separate entries
    /// so a log cannot attribute a request to the wrong one.
    nonisolated var activityService: ActivityService {
        switch self {
        case .jamfPro: .jamfPro
        case .jamfSchool: .jamfSchool
        case .intune: .intune
        }
    }
}

extension AppleOrgKind {
    /// How traffic to this service is labeled in the log. The two are
    /// separate entries so a log cannot attribute a request to the wrong one.
    nonisolated var activityService: ActivityService {
        switch self {
        case .business: .appleBusiness
        case .school: .appleSchool
        }
    }
}

nonisolated enum ActivityOutcome: String, Sendable {
    case succeeded
    case failed
}

extension ActivityLog {
    /// Records an action the user asked for, with its overall result, as
    /// JTKit's shared Action entry. The serials it concerns are masked in the
    /// bug-report export. Commands are recorded by `recordCommand`.
    func recordAction(
        service: ActivityService,
        connection: String?,
        summary: String,
        outcome: ActivityOutcome,
        serials: [String] = []
    ) {
        recordAction(summary, failed: outcome == .failed, service: service.label,
                     connection: connection, devices: serials)
    }
}

import Foundation
import JTKit

// MARK: - Models

/// A device as the Jamf School list endpoint reports it.
///
/// Only the fields Checkpoint shows are kept. The record also carries battery,
/// capacity, iCloud backup state, network information and an owner; the owner
/// is a person, and in a school usually a pupil, so it is deliberately not
/// read into the app at all.
nonisolated struct JamfSchoolDevice: Sendable {
    let udid: String
    let serialNumber: String
    let name: String?
    let locationID: String?
    let modelName: String?
    let osPrefix: String?
    let osVersion: String?
    /// `ipad`, `iphone` or `mac`.
    let deviceClass: String?
    let isManaged: Bool?
    let isSupervised: Bool?
    /// `dep`, `manual`, `ac2` and so on.
    let enrollType: String?
    /// Name of the Apple ADE profile assigned to the device, not a Jamf
    /// PreStage. Jamf School has no PreStages.
    let depProfile: String?
    /// Wall-clock time in the instance's own zone, with no offset attached.
    let lastCheckin: String?
    let assetTag: String?
    let groupNames: [String]
    let inTrash: Bool

    /// Computer or mobile device.
    ///
    /// `class` and `os.prefix` agree on every device in the tenant this was
    /// verified against, cross-checked against `isBootstrapStored` appearing
    /// on exactly the Macs. `model.type` is not used: it is a string on this
    /// endpoint and an object on the per-device one, and is empty on some
    /// records. The iPad/iPhone distinction is unreliable too, but Checkpoint
    /// only needs to tell a Mac from everything else.
    var kind: DeviceKind {
        if deviceClass?.lowercased() == "mac" { return .computer }
        if osPrefix?.lowercased() == "macos" { return .computer }
        return .mobileDevice
    }
}

/// The per-device record, which is a different shape from the list entry.
///
/// Passcode state exists only here, so it is read when a device is selected
/// rather than during a lookup. The time zone comes from this endpoint too:
/// it reports `lastCheckin` as an object naming the instance's zone, while
/// the list endpoint gives the same wall-clock string with no zone at all.
struct JamfSchoolDeviceDetails: Sendable {
    let hasPasscode: Bool?
    let passcodeCompliant: Bool?
    let isBootstrapStored: Bool?
    let timeZone: TimeZone?
}

struct JamfSchoolLocation: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let isDistrict: Bool
}

// MARK: - Client

/// Checkpoint's Jamf School connection, on JTKit's `JamfSchool.Client`
/// (ROADMAP step 7): Network ID and API key, 429 retried for every request
/// and server errors for reads, failures read from the status and from the
/// answer itself (Jamf School can fail under HTTP 200), JTKit's error texts,
/// and an activity log entry per attempt. Commands, Move to Trash and moving
/// location are JTKit's too.
///
/// This layer keeps the shapes the rest of Checkpoint reads. The owner a
/// device record carries is a person, in a school usually a pupil, so it is
/// not read into Checkpoint at all.
actor JamfSchoolClient {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let client: JamfSchool.Client
    /// Refuses every MDM command under tests (a second check after the model's).
    private let commandGuard: ActionGuard

    init?(config: MDMConnection, secret: String, log: ActivityLog? = nil, session: URLSession = .shared,
          commandGuard: ActionGuard = .off) {
        self.commandGuard = commandGuard
        let recorder = RequestRecorder(session: session, log: log,
                                       service: ActivityService.jamfSchool.rawValue, connection: config.displayName)
        // The device list and a device's details are recorded also when they
        // succeed (ROADMAP step 5); personal blocks are hidden.
        guard let client = try? JamfSchool.Client(address: config.apiBaseURL, networkID: config.account, apiKey: secret,
                                                  recorder: recorder, recordsDeviceAnswers: true) else { return nil }
        self.client = client
    }

    // MARK: Devices

    /// Every device in the instance, keyed by serial number. Jamf School
    /// serves the whole fleet in one request, so a lookup of any size costs
    /// one request here.
    func fleet() async throws -> [String: JamfSchoolDevice] {
        try await client.fleet().compactMapValues(Self.device)
    }

    /// Members of a device group. The list answers with full records, so no
    /// second request is needed.
    func devices(inGroup groupID: String) async throws -> [JamfSchoolDevice] {
        try await client.devices(inGroups: [groupID]).compactMap(Self.device)
    }

    /// The per-device record, for what the list leaves out: the passcode
    /// state and the instance's time zone.
    func deviceDetails(udid: String) async throws -> JamfSchoolDeviceDetails? {
        guard let device = try await client.device(udid: udid) else { return nil }
        return JamfSchoolDeviceDetails(
            hasPasscode: device.hasPasscode,
            passcodeCompliant: device.passcodeCompliant,
            isBootstrapStored: device.isBootstrapStored,
            timeZone: device.timeZone.flatMap(TimeZone.init(identifier:))
        )
    }

    private static func device(_ device: JamfSchool.Device) -> JamfSchoolDevice? {
        guard let serial = device.serialNumber, !serial.isEmpty else { return nil }
        return JamfSchoolDevice(
            udid: device.udid,
            serialNumber: serial,
            name: device.name,
            locationID: device.locationID,
            modelName: device.modelName,
            osPrefix: device.osPrefix,
            osVersion: device.osVersion,
            deviceClass: device.deviceClass,
            isManaged: device.isManaged,
            isSupervised: device.isSupervised,
            enrollType: device.enrollType,
            depProfile: device.depProfile,
            lastCheckin: wallClock(device.lastCheckIn),
            assetTag: device.assetTag,
            groupNames: device.groups,
            inTrash: device.inTrash ?? false
        )
    }

    /// The list reports the check-in as the instance's wall clock without a
    /// zone; JTKit reads it in the Mac's zone, so it is written back the same
    /// way for Checkpoint to place in the instance's zone.
    private static func wallClock(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    // MARK: Automated Device Enrollment

    /// Serial numbers of every ADE placeholder that isn't removed: the devices
    /// Apple assigns to this server's token.
    func adeSerials() async throws -> Set<String> {
        Set(try await client.enrollmentPlaceholders().compactMap { placeholder in
            guard let serial = placeholder.serialNumber, !serial.isEmpty else { return nil }
            return serial.uppercased()
        })
    }

    // MARK: Locations and groups

    func locations() async throws -> [JamfSchoolLocation] {
        try await client.locations().map {
            JamfSchoolLocation(id: $0.id, name: $0.name ?? $0.id, isDistrict: $0.isDistrict ?? false)
        }
    }

    /// Device groups. Jamf School doesn't split them by device kind.
    func groups() async throws -> [JamfGroup] {
        try await client.groups().map {
            JamfGroup(id: $0.id, name: $0.name ?? $0.id, isSmart: $0.isSmartGroup ?? false, kind: nil, memberCount: $0.members)
        }
    }

    // MARK: Commands and record changes (JTKit)

    /// The approval comes from the confirmation.
    func send(_ command: MDMCommand, to targets: [MDMCommand.Target],
              approval: MDMCommand.Confirmation.Approval?) async throws -> MDMCommand.Result {
        try commandGuard.check("\(command.title) (Jamf School client), \(targets.count) device(s)")
        return try await client.send(command, to: targets, approval: approval)
    }

    /// Sets or clears the device's asset tag; only the tag is sent.
    func setAssetTag(udid: String, assetTag: String) async throws {
        try await client.setAssetTag(assetTag, udid: udid)
    }

    /// Moves the record to the trash. Unlike a Jamf Pro deletion this can be
    /// undone: Jamf School keeps the record and can restore it.
    func trash(udid: String) async throws {
        try await client.trash(udid: udid)
    }

    /// Moves devices to another location, twenty per request, reporting per
    /// device (a device that didn't move comes back inside a success).
    @discardableResult
    func move(udids: [String], toLocation locationID: String) async throws -> JamfSchool.MoveOutcome {
        try await client.move(udids: udids, toLocation: locationID)
    }

    // MARK: Connection test

    /// Confirms the credentials and that the key may read. Locations are the
    /// cheapest thing to ask for, and the count is worth showing back.
    func verify() async throws -> Int {
        try await locations().count
    }
}

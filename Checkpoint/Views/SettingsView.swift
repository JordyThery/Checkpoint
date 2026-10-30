import JTKit
import SwiftUI

// Checkpoint's parts of JTKit's Settings window: a section for its General
// tab, below JTKit's Appearance, then the Connections tab, before Updates.

/// How tall the Connections tab is: a list beside an editor has no natural
/// height, so it keeps the height the Apple and MDM tabs had.
private let connectionsTabHeight: CGFloat = 500

// MARK: - General

struct GeneralSettingsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            Toggle("Warn when a service is not configured", isOn: Binding(
                get: { !settings.configurationHintDismissed },
                set: { settings.configurationHintDismissed = !$0 }
            ))
            .help("Show the message above the table when an Apple organization or a device management connection is missing")
        }
    }
}

// MARK: - Connections

/// JTKit's shared Connections tab: the Apple organizations and the MDM
/// connections in one list, each still saved where it always was.
struct ConnectionsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LookupModel.self) private var model
    @Environment(ActivityLog.self) private var log

    var body: some View {
        ConnectionsSettingsTab(
            store: settings.connections,
            services: CheckpointConnection.services,
            optionalFields: [.jamfProWebURL],
            serviceGroups: CheckpointConnection.serviceGroups,
            signInMethods: CheckpointConnection.signInMethods,
            roles: [model.appleRole, model.mdmRole],
            height: connectionsTabHeight,
            newRecord: CheckpointConnection.new(for:),
            test: { record, typed in try await test(record, typed: typed) }
        ) { $record in
            ConnectionNotes(record: record, saved: settings.connections.record(id: record.id))
        }
    }

    /// Tests the values in the editor, saved or not, with the secret typed
    /// there or else the stored one.
    private func test(_ record: CheckpointConnection, typed: [ConnectionSecretKind: String]) async throws -> String {
        guard let secret = typed[.main] ?? settings.secret(for: record), !secret.isEmpty else {
            throw ConnectionTestError(record.connection.signIn == .applePrivateKey
                                      ? "Import the private key first."
                                      : "Enter the \(record.connection.signIn.secretName?.lowercased() ?? "secret") first.")
        }
        // Under tests the saved connections are never reached (step 11).
        let session = settings.testConnectionSession
        switch record {
        case .apple(let org):
            let client = ABMClient(clientID: org.clientID, keyID: org.keyID, privateKeyPEM: secret,
                                   kind: org.kind, connectionName: org.displayName, log: log, session: session)
            let count = try await client.verify()
            return "Connected · \(count) MDM server\(count == 1 ? "" : "s") visible"
        case .mdm(let server) where server.product == .intune:
            guard let client = LookupModel.intuneClient(for: server, secret: { secret }, log: log, session: session) else {
                throw ConnectionTestError("Enter a tenant ID, client ID and client secret first.")
            }
            try await client.intuneTestConnection()
            return "Connected"
        case .mdm(let server) where server.product == .jamfSchool:
            guard let client = JamfSchoolClient(config: server, secret: secret, log: log, session: session) else {
                throw ConnectionTestError("Enter a valid server URL, Network ID and API key first.")
            }
            let locations = try await client.verify()
            return "Connected · \(locations) location\(locations == 1 ? "" : "s")"
        case .mdm(let server):
            guard let client = JamfClient(config: server, secret: { secret }, log: log, session: session) else {
                throw ConnectionTestError("Enter a valid server URL first.")
            }
            try await client.verify()
            return "Connected"
        }
    }
}

private struct ConnectionTestError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension LookupModel {
    /// The Apple organization in use: the toolbar picker, the Connection menu
    /// and "Use This Connection" in Settings.
    var appleRole: ConnectionRole {
        ConnectionRole("Apple", useTitle: "Use This Connection", selection: Binding(
            get: { ConnectionChoiceResolver.single(saved: self.settings.appleChoiceID,
                                                   among: self.settings.abmOrgs.map(\.id)) },
            set: { self.settings.appleChoiceID = $0 }
        ), services: CheckpointConnection.appleServices, all: appleAll, demo: appleDemo)
    }

    /// The MDM connection in use, as for `appleRole`.
    var mdmRole: ConnectionRole {
        ConnectionRole("MDM", useTitle: "Use This Connection", selection: Binding(
            get: { ConnectionChoiceResolver.single(saved: self.settings.mdmChoiceID,
                                                   among: self.settings.mdmConnections.map(\.id)) },
            set: { self.settings.mdmChoiceID = $0 }
        ), services: CheckpointConnection.mdmServices, all: mdmAll, demo: mdmDemo)
    }
}

/// What Checkpoint explains below the shared fields: what each product can
/// and can't show, and how to set up its access.
private struct ConnectionNotes: View {
    let record: CheckpointConnection
    let saved: CheckpointConnection?

    var body: some View {
        if let savedService = saved?.connection.service, savedService != record.connection.service {
            Section {
                Label {
                    Text("This connection is saved as \(savedService.displayName). Changing the service keeps the address, account and stored secret, which the new service is unlikely to accept — check them before saving.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }
        }
        switch record {
        case .apple(let org):
            Section {
                note("Import the .pem private key downloaded when creating the API account in \(org.kind.label) (Settings → Integrations → API). The account needs the Device Enrollment Manager role or higher. The key is stored only in your keychain.")
                if !org.kind.supportsRelease {
                    note("\(org.kind.label) uses the same API as Apple Business, except that it provides no way to release devices from the organization. That action is dimmed.")
                }
            }
        case .mdm(let server):
            switch server.connection.service {
            case .jamfPlatform:
                Section {
                    note("Requires an environment-scoped integration created in Jamf Account, not a Jamf Pro API client. Copy the environment ID from its Integration details, and pick the region it is in. Requests go to the gateway; the Jamf Pro web address is still used to link devices to their Jamf Pro records.")
                    Label {
                        Text("Renew MDM Profile cannot be sent over the Platform API. Everything else works, including lookups, PreStages, sites, Lock, Clear Passcode, Wipe, Restart and Shut Down.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
            case .jamfSchool:
                Section {
                    note("The Network ID is under Devices → Enroll Device(s). Create the API key under Organization → Settings → API, and grant it the methods you intend to use: each key carries its own list, so a missing one refuses a single feature rather than the whole connection.")
                    note("Jamf School reports fewer attributes than Jamf Pro, so the columns and actions it has no source for are hidden: FileVault, MDM profile expiry, software update state, PreStage scope and the recovery secrets.")
                }
            case .intune:
                Section {
                    note("Requests go to Microsoft Graph, so no URL is needed. The tenant ID can be the GUID or a verified domain name.")
                    note("Create an app registration in Entra, add a client secret, and grant it the application permissions under Microsoft Graph — DeviceManagementManagedDevices.Read.All to look devices up, PrivilegedOperations.All to send commands, and ReadWrite.All to delete records. Application permissions need admin consent before any of them work.")
                    note("Intune reports one sync time rather than Jamf's four dates, and has no sites, PreStage scope, declarative update reporting or recovery secrets, so the columns and actions for those are hidden. The enrollment profile is hidden too, because Graph reports what a device enrolled with rather than what is assigned to it. Compliance is shown instead. Deleting a record leaves the device enrolled; Retire Device unmanages it.")
                }
            default:
                EmptyView()
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

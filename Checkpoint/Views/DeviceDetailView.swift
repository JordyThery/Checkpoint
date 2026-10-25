import SwiftUI

/// Inspector pane for a single device: the Apple organization and device
/// management detail, the actions on both, and the MDM remote commands the
/// connected product offers. Every action asks for confirmation first.
struct DeviceDetailView: View {
    @Environment(LookupModel.self) private var model
    let report: DeviceReport

    @State private var mdmSelection: String?
    @State private var migrationDeadline = Date().addingTimeInterval(7 * 24 * 60 * 60)
    @State private var revealedSecret: RevealedSecret?

    /// A recovery secret held only for as long as its sheet is on screen.
    private struct RevealedSecret: Identifiable {
        let id = UUID()
        let title: String
        let value: String
        let note: String?
    }
    @State private var prestageSelection: String?
    @State private var assetTagField = ""
    @State private var siteSelection = "-1"
    /// Jamf School location, that product's equivalent of a site.
    @State private var locationSelection: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var pending: PendingAction?
    @State private var pinCommand: MDMCommand?
    @State private var pin = ""
    @State private var localAdmins: [JamfLocalAdminAccount] = []
    @State private var rotationTime: TimeInterval?
    /// The device's declarative status report: software update state and the
    /// declarations it has processed, from one request.
    @State private var ddm: JamfDDMStatus?
    /// The software update target the device is held to, read back from the
    /// declaration itself because the status report does not carry it.
    @State private var enforcement: JamfUpdateEnforcement?
    /// The blueprint a declaration came from, named when the connection can.
    @State private var blueprintName: String?
    /// AppleCare coverage fetched on selection, when the lookup read Apple
    /// Business in bulk and therefore could not include it.
    @State private var loadedCoverage: [AppleCareCoverage]?
    /// Compliance fetched on selection, for the connection that serves it
    /// per device rather than with the lookup.
    @State private var compliance: JamfDeviceCompliance?
    /// Activation Lock state fetched on selection. Nil both while loading
    /// and when no answer came, which is why the row tracks loading
    /// separately.
    @State private var activationLock: ABMActivationLock?
    @State private var isLoadingActivationLock = false
    /// Jamf School's per-device record, which carries the passcode state its
    /// device list leaves out. Fetched on selection for the same reason
    /// AppleCare coverage is.
    @State private var schoolDetails: JamfSchoolDeviceDetails?
    /// The device's history from the organization's audit log. Fetched when
    /// the disclosure opens, not on selection, so showing a device does not
    /// spend a third Apple request; kept until the selection changes.
    @State private var historyExpanded = false
    @State private var historyEvents: [ABMAuditEvent] = []
    @State private var historyNextCursor: String?
    @State private var historyLoaded = false
    @State private var isLoadingHistory = false
    @State private var showingFullHistory = false
    /// Management state from Apple's built-in device management, for records
    /// it holds. Fetched on selection like the other per-device reads.
    @State private var appleDetail: ABMManagedDeviceDetail?

    private enum PendingAction {
        case applyMDM
        case unassignMDM
        case release
        case scheduleMigration
        case updateDeadline
        case cancelMigration
        case applyPrestage
        case applySite
        case applyLocation
        case applyAssetTag
        case deleteRecord
        case removeOtherRecord(ManagedDeviceInfo)
        case command(MDMCommand)
        case viewLocalAdminPassword(JamfLocalAdminAccount)
    }

    /// How long a viewed local administrator password stays valid, worded the
    /// way Jamf Pro words it. The interval is an instance setting, so it is
    /// read from the server rather than assumed.
    private var rotationDescription: String {
        guard let rotationTime else { return "shortly afterwards" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter.string(from: rotationTime).map { "in \($0)" } ?? "shortly afterwards"
    }



    /// One extra record's facts and its exit. Lean on purpose: the working
    /// record above carries the detail, and what matters here is where this
    /// one is, whether it is alive, and how to remove it.
    @ViewBuilder
    private func otherRecordRows(_ info: ManagedDeviceInfo) -> some View {
        let product = model.connection(for: info)?.product ?? .jamfPro
        LabeledContent("Device Name", value: info.name ?? "—")
        if let method = info.enrollmentMethod, !method.isEmpty {
            LabeledContent("Enrollment", value: method)
        }
        if let managed = info.isManaged {
            LabeledContent("Managed", value: managed ? "Yes" : "No")
        }
        LabeledContent("Last Contact", value: DateFormatting.short(info.lastContact ?? info.lastContactTime ?? info.reportDate))
        if let url = info.webURL {
            Link("Open in \(product.label)", destination: url)
        }
        Button(product.removeRecordLabel, role: .destructive) {
            pending = .removeOtherRecord(info)
        }
    }


    /// What Apple's built-in management reports about the device. Read on
    /// selection; read-only by nature of the API.
    @ViewBuilder
    private var appleManagementRows: some View {
        if let detail = appleDetail {
            if let os = detail.osVersion, !os.isEmpty {
                LabeledContent("OS Version", value: os)
            }
            LabeledContent("Last Check-in", value: DateFormatting.short(detail.lastCheckInDateTime))
            // Apple reports the flags as false on devices that have no such
            // feature, so both rows are for Macs only.
            if report.mdm.value?.kind == .computer {
                if let fileVault = detail.isFileVaultEnabled {
                    LabeledContent("FileVault") {
                        Text(fileVault ? "Enabled" : "Not enabled")
                            .foregroundStyle(fileVault ? Color.primary : Color.orange)
                    }
                }
                if let firewall = detail.isFirewallEnabled {
                    LabeledContent("Firewall", value: firewall ? "Enabled" : "Not enabled")
                }
            }
            if detail.deviceLockStatus?.uppercased() == "LOCKED" {
                LabeledContent("Locked") { Text("Yes").foregroundStyle(.orange) }
            }
            if detail.lostModeStatus?.uppercased() == "ENABLED" {
                LabeledContent("Lost Mode") { Text("Enabled").foregroundStyle(.orange) }
            }
            if detail.deviceEraseStatus?.uppercased() == "ERASED" {
                LabeledContent("Erased") { Text("Yes").foregroundStyle(.orange) }
            }
        } else {
            LabeledContent("Management State") { ProgressView().controlSize(.small) }
        }
    }

    /// The MDM section is titled for the record's product once there is a
    /// record, and for the scope before there is one.
    private var mdmSectionTitle: String {
        if report.mdm.value?.managedByApple == true { return "Apple Device Management" }
        return report.mdm.value != nil ? model.product(for: report).label : model.mdmScopeLabel
    }

    private var missingConnectionHint: String {
        model.readsAllConnections
            ? "Add a connection in Settings to see enrollment details."
            : model.mdmProduct.missingConnectionHint
    }

    private var noRecordHint: String {
        model.readsAllConnections
            ? "No device record was found on any configured connection."
            : model.mdmProduct.noRecordHint
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Serial Number") {
                    Text(report.serial).monospaced().textSelection(.enabled)
                }
                if let url = report.mdm.value?.webURL {
                    Link("Open in \(model.product(for: report).label)", destination: url)
                }
            }
            // Read-only detail and the actions that act on it are kept in
            // separate sections, so the form reads as facts then choices.
            Section(model.abmKind.label) { abmContent }
            if let info = report.abm.value, !info.isReleased {
                Section { abmActions(info) }
            }
            if let verdict = report.mdmVerdict, let summary = verdict.summary {
                Section("Finding") {
                    Label {
                        Text(summary)
                    } icon: {
                        Image(systemName: verdict.isFinding ? "exclamationmark.triangle.fill" : "questionmark.circle")
                            .foregroundStyle(verdict.isFinding ? .orange : .secondary)
                    }
                    .font(.callout)
                }
            }
            Section(mdmSectionTitle) { mdmContent }
            // Apple's built-in management takes no commands and no record
            // changes, so its records get the reporting section alone; the
            // Apple actions above are the ones that apply.
            if let info = report.mdm.value, !info.managedByApple {
                Section { mdmActions(info) }
                if !localAdmins.isEmpty {
                    Section("Managed Local Administrator Accounts") { localAdminRows }
                }
                Section("MDM Commands") { commandButtons(info) }
            }
            // Records beside the working one, each with the way out that
            // fits its product. This is where a stale record gets cleaned up
            // from the place it was discovered.
            ForEach(report.otherRecords, id: \.recordID) { info in
                Section("Also on \(model.connection(for: info)?.displayName ?? "another connection")") {
                    otherRecordRows(info)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .onAppear(perform: syncSelections)
        // Keyed on resolution as well as the serial: a row selected while its
        // lookup is still running resolves without changing serial, and the
        // fetch must re-run once there is a record to fetch detail for.
        .task(id: "\(report.serial)|\(report.abm.value != nil)|\(report.mdm.value?.recordID ?? "")") {
            await loadDeviceDetail()
        }
        // Kept out of loadDeviceDetail: it is server-wide, cached for the
        // session, and slow enough that the rows above should not wait on it.
        .task(id: report.mdm.value?.connectionID) {
            if let connection = model.connection(for: report) {
                await model.loadADEInstances(for: connection)
            }
        }
        .onChange(of: report.serial) {
            syncSelections()
            historyExpanded = false
            historyEvents = []
            historyNextCursor = nil
            historyLoaded = false
        }
        .onChange(of: historyExpanded) { _, expanded in
            if expanded, !historyLoaded { Task { await loadHistory() } }
        }
        .sheet(isPresented: $showingFullHistory) { fullHistorySheet }
        .onChange(of: report.abm.value?.mdmServerID) { syncSelections() }
        .onChange(of: report.mdm.value?.prestageID) { syncSelections() }
        .onChange(of: report.mdm.value?.assetTag) { syncSelections() }
        .onChange(of: report.mdm.value?.siteID) { syncSelections() }
        .onChange(of: report.mdm.value?.locationID) { syncSelections() }
        .sheet(item: $revealedSecret) { secret in
            VStack(alignment: .leading, spacing: 16) {
                Text(secret.title).font(.headline)
                Text(report.serial).font(.caption).foregroundStyle(.secondary)
                Text(secret.value)
                    .font(.title3.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                if let note = secret.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(secret.value, forType: .string)
                    }
                    Spacer()
                    Button("Done") { revealedSecret = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
        .alert(
            "Action Failed",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            "Command Sent",
            isPresented: Binding(get: { infoMessage != nil }, set: { if !$0 { infoMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
        }
        .alert(
            pinCommand.map { "\($0.title) — \(report.serial)" } ?? "",
            isPresented: Binding(get: { pinCommand != nil }, set: { if !$0 { pinCommand = nil } })
        ) {
            TextField("6-digit PIN", text: $pin)
            Button("Cancel", role: .cancel) {}
            Button(pinCommand?.title ?? "Send", role: .destructive) {
                if let command = pinCommand { executeWithPIN(command) }
            }
        } message: {
            Text("Enter the 6-digit PIN that will be required to unlock the Mac afterwards. \(pinCommand?.message(for: model.product(for: report)) ?? "")")
        }
        .confirmationDialog(
            pendingTitle,
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            dialogActions
        } message: {
            Text(pendingMessage)
        }
    }

    // MARK: Confirmation

    private var selectedServerName: String? {
        mdmSelection.map { id in model.mdmServers.first { $0.id == id }?.name ?? id }
    }

    /// PreStages the device can actually join: ones tied to the same
    /// device-enrollment (ADE) instance that synced this serial. Falls back
    /// to the full list when the instance is unknown.
    private var prestageChoices: [JamfPrestage] {
        let all = report.mdm.value?.kind == .mobileDevice ? model.mobilePrestages(for: report) : model.prestages(for: report)
        guard let instance = model.adeInstance(for: report) else { return all }
        let matching = all.filter { $0.enrollmentInstanceID == instance }
        return matching.isEmpty ? all : matching
    }

    private var selectedPrestageName: String? {
        prestageSelection.map { id in prestageChoices.first { $0.id == id }?.displayName ?? id }
    }

    private var selectedSiteName: String {
        model.sites(for: report).first { $0.id == siteSelection }?.name ?? "None"
    }

    private var selectedLocationName: String {
        locationSelection.map { id in
            model.locations(for: report).first { $0.id == id }?.name ?? id
        } ?? "None"
    }

    private var pendingTitle: String {
        switch pending {
        case .applyMDM:
            if let selectedServerName {
                "Assign \(report.serial) to “\(selectedServerName)”?"
            } else {
                "Unassign \(report.serial) from its MDM server?"
            }
        case .unassignMDM:
            "Unassign \(report.serial) from “\(report.abm.value?.mdmServerName ?? "its MDM server")”?"
        case .release:
            "Release \(report.serial) from \(model.abmKind.label)?"
        case .scheduleMigration:
            "Migrate \(report.serial) to “\(selectedServerName ?? "the selected server")”?"
        case .updateDeadline:
            "Change the migration deadline for \(report.serial)?"
        case .cancelMigration:
            "Cancel the migration for \(report.serial)?"
        case .applyPrestage:
            if let selectedPrestageName {
                "Move \(report.serial) to PreStage “\(selectedPrestageName)”?"
            } else {
                "Remove \(report.serial) from its PreStage?"
            }
        case .applySite:
            "Move \(report.serial) to site “\(selectedSiteName)”?"
        case .applyLocation:
            "Move \(report.serial) to location “\(selectedLocationName)”?"
        case .applyAssetTag:
            assetTagField.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Clear the asset tag on \(report.serial)?"
                : "Set the asset tag on \(report.serial) to “\(assetTagField.trimmingCharacters(in: .whitespaces))”?"
        case .deleteRecord:
            model.product(for: report).removeRecordPrompt(report.serial)
        case .removeOtherRecord(let info):
            (model.connection(for: info)?.product ?? .jamfPro).removeRecordPrompt(report.serial)
        case .command(let command):
            "\(command.title) — \(report.serial)?"
        case .viewLocalAdminPassword:
            "Rotation after viewing"
        case nil:
            ""
        }
    }

    private var pendingMessage: String {
        switch pending {
        case .applyMDM:
            "Apple processes MDM server assignments asynchronously, so allow a moment before the new state appears."
        case .unassignMDM:
            "The device stays in your organization but is no longer assigned to any MDM server, so it will not enrol automatically until it is assigned again."
        case .release:
            "The device will be removed from your organization and can no longer be assigned to an MDM server. This cannot be undone through the API."
        case .scheduleMigration:
            "The \(model.abmKind.label) assignment changes immediately. Nothing is erased: the device keeps running under its current service until it migrates, and Apple prompts the user to migrate before \(migrationDeadline.formatted(date: .abbreviated, time: .shortened))."
        case .updateDeadline:
            "A deadline earlier than the current one, or in the past, is enforced immediately without giving the user the option to delay."
        case .cancelMigration:
            "Only the scheduled migration is cancelled. The device stays assigned to \(report.abm.value?.mdmServerName ?? "its assigned server") in \(model.abmKind.label) and keeps running under its current service. To undo the assignment as well, assign it back to the previous server."
        case .applyPrestage:
            "The device will be removed from its current PreStage scope\(selectedPrestageName == nil ? "." : " and added to the selected one.")"
        case .applySite:
            "Only the Jamf Pro record moves to the other site. The PreStages the device can join stay the same, because they follow the ADE token that synced it."
        case .applyLocation:
            "The device record moves to the other location. Its groups and the profiles scoped to it are re-evaluated for the new location."
        case .applyAssetTag:
            "The tag is written to the \(model.product(for: report).label) record."
        case .deleteRecord:
            model.product(for: report).removeRecordConsequence
        case .removeOtherRecord(let info):
            (model.connection(for: info)?.product ?? .jamfPro).removeRecordConsequence
        case .command(let command):
            command.message(for: model.product(for: report))
        case .viewLocalAdminPassword(let account):
            "Viewing the password for \(account.username) will cause Jamf Pro to rotate it \(rotationDescription)."
        case nil:
            ""
        }
    }

    @ViewBuilder
    private var dialogActions: some View {
        switch pending {
        case .applyMDM:
            Button(mdmSelection == nil ? "Unassign Device" : "Assign Device") {
                run { try await model.setMDMServer(reports: [report], to: mdmSelection) }
            }
        case .unassignMDM:
            Button("Unassign Device") {
                run { try await model.setMDMServer(reports: [report], to: nil) }
            }
        case .release:
            Button("Release Device", role: .destructive) {
                run { try await model.releaseFromABM(reports: [report]) }
            }
        case .scheduleMigration:
            Button("Schedule Migration") {
                let server = mdmSelection
                let deadline = migrationDeadline
                run {
                    guard let server else { return }
                    try await model.scheduleMigration(reports: [report], to: server, deadline: deadline)
                }
            }
        case .updateDeadline:
            Button("Update Deadline") {
                let deadline = migrationDeadline
                run { try await model.updateMigrationDeadline(reports: [report], deadline: deadline) }
            }
        case .cancelMigration:
            Button("Cancel Migration", role: .destructive) {
                run { try await model.cancelMigration(reports: [report]) }
            }
        case .applyPrestage:
            Button("Change PreStage") {
                let kind = report.mdm.value?.kind ?? .computer
                run { try await model.setPrestage(reports: [report], to: prestageSelection, kind: kind) }
            }
        case .applySite:
            Button("Change Site") {
                let siteID = siteSelection
                run { try await model.setSite(reports: [report], to: siteID) }
            }
        case .applyLocation:
            Button("Change Location") {
                let locationID = locationSelection
                run {
                    guard let locationID else { return }
                    try await model.setLocation(reports: [report], to: locationID)
                }
            }
        case .applyAssetTag:
            Button(assetTagField.trimmingCharacters(in: .whitespaces).isEmpty ? "Clear Asset Tag" : "Set Asset Tag") {
                let tag = assetTagField
                run { try await model.setAssetTag(tag, for: report) }
            }
        case .deleteRecord:
            Button(
                model.product(for: report).removeRecordAction,
                role: .destructive
            ) {
                run { try await model.deleteMDMRecord(reports: [report]) }
            }
        case .removeOtherRecord(let info):
            Button(
                (model.connection(for: info)?.product ?? .jamfPro).removeRecordAction,
                role: .destructive
            ) {
                run { try await model.removeRecord(info, serial: report.serial) }
            }
        case .command(let command):
            Button(command.title, role: command.isDestructive ? .destructive : nil) {
                execute(command, pin: nil)
            }
        case .viewLocalAdminPassword(let account):
            Button("Continue") {
                reveal(title: "Password for \(account.username)") {
                    let password = try await model.localAdminPassword(for: report, account: account)
                    return (password, "Jamf Pro will rotate this password \(rotationDescription).")
                }
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: ABM


    /// The device's life in the organization — added, assigned, released —
    /// from the audit log. Collapsed until asked: it is the one Apple read
    /// the inspector does not need for its rows, and the per-minute budget
    /// is better spent on the reads it does.
    private var historyDisclosure: some View {
        DisclosureGroup("History", isExpanded: $historyExpanded) {
            if isLoadingHistory && historyEvents.isEmpty {
                ProgressView().controlSize(.small)
            } else if historyEvents.isEmpty {
                Text("No events in the organization's audit log for this device.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(historyEvents.prefix(4)) { event in
                    historyRow(event, withTime: false)
                }
                Button("Show Full History") { showingFullHistory = true }
            }
        }
    }

    /// A timeline row: the sentence first, the date and actor as a caption.
    /// Left-aligned on purpose — server names are long, and a trailing
    /// column wraps them into a ragged block.
    private func historyRow(_ event: ABMAuditEvent, withTime: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.summary + (event.isFailure ? " — failed" : ""))
                .foregroundStyle(event.isFailure ? Color.orange : Color.primary)
            Text(
                [
                    withTime ? DateFormatting.short(event.dateTime) : DateFormatting.dateOnly(event.dateTime),
                    event.actorName ?? "",
                ]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The complete timeline, paged backwards through the organization's log.
    private var fullHistorySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device History").font(.headline)
            Text(report.serial).font(.caption).foregroundStyle(.secondary)
            Form {
                ForEach(historyEvents) { event in
                    historyRow(event, withTime: true)
                }
                if historyNextCursor != nil {
                    Button("Load Earlier Events") { Task { await loadHistory() } }
                        .disabled(isLoadingHistory)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { showingFullHistory = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: min(max(180 + CGFloat(historyEvents.count) * 56, 280), 560))
    }

    private func loadHistory() async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        if let page = await model.deviceHistory(for: report, cursor: historyLoaded ? historyNextCursor : nil) {
            if historyLoaded {
                historyEvents += page.events
            } else {
                historyEvents = page.events
            }
            historyNextCursor = page.nextCursor
        }
        historyLoaded = true
    }

    /// The hardware identifiers Apple reports, folded away because they are
    /// looked up rarely and read like noise beside the status rows. The
    /// disclosure only exists when at least one is present.
    @ViewBuilder
    private func identifiersDisclosure(_ device: ABMDevice) -> some View {
        let rows: [(String, String)] = [
            ("Product Type", device.productType ?? ""),
            ("Part Number", device.partNumber ?? ""),
            ("IMEI", device.imeiDisplay ?? ""),
            ("MEID", device.meid?.joined(separator: ", ") ?? ""),
            ("EID", device.eid ?? ""),
            ("Wi-Fi MAC", device.wifiMacAddress ?? ""),
            ("Bluetooth MAC", device.bluetoothMacAddress ?? ""),
            ("Ethernet MAC", device.ethernetMacAddress?.joined(separator: ", ") ?? ""),
        ].filter { !$0.1.isEmpty }
        if !rows.isEmpty {
            DisclosureGroup("Identifiers") {
                ForEach(rows, id: \.0) { row in
                    LabeledContent(row.0) {
                        Text(row.1).monospaced().textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var abmContent: some View {
        switch report.abm {
        case .pending:
            ProgressView().controlSize(.small)
        case .notConfigured:
            Text("Add your \(model.abmKind.label) API credentials in Settings to see device status, warranty, and MDM assignment.")
                .foregroundStyle(.secondary)
        case .notFound:
            Text("This serial number is not part of your organization. It was never added, or it has been released.")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case .found(let info):
            abmDetails(info)
        }
    }

    @ViewBuilder
    private func abmDetails(_ info: ABMInfo) -> some View {
        LabeledContent("Status") {
            if info.isReleased {
                Text("Released \(DateFormatting.short(info.device.releasedFromOrgDateTime))")
                    .foregroundStyle(.red)
            } else if info.device.status?.uppercased() == "ASSIGNED" {
                Text("Assigned").foregroundStyle(.green)
            } else {
                Text("Unassigned").foregroundStyle(.orange)
            }
        }
        if model.readsAllABMOrgs, let org = info.orgName {
            LabeledContent("Organization", value: org)
        }
        // Colour and capacity belong to the model rather than to rows of
        // their own, so the model row carries them.
        LabeledContent("Model") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(info.device.deviceModel ?? "—")
                if let detail = [info.device.color, info.device.deviceCapacity]
                    .compactMap({ $0?.isEmpty == false ? $0 : nil })
                    .joined(separator: " · ") as String?, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if !info.isReleased {
            activationLockRow
        }
        LabeledContent("Date added", value: DateFormatting.short(info.device.addedToOrgDateTime))
        LabeledContent("Order") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(info.device.orderNumber ?? "—")
                if let ordered = info.device.orderDateTime, !ordered.isEmpty {
                    Text("Ordered \(DateFormatting.dateOnly(ordered))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        LabeledContent("Purchase Source") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(info.device.purchaseSourceType ?? "—")
                if let id = info.device.purchaseSourceId, !id.isEmpty {
                    Text(id).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        identifiersDisclosure(info.device)
        if model.supportsDeviceHistory(for: report) {
            historyDisclosure
        }

        let coverage = loadedCoverage ?? info.coverage
        if !info.coverageLoaded && loadedCoverage == nil {
            LabeledContent("Warranty Coverage") {
                ProgressView().controlSize(.small)
            }
        } else if coverage.isEmpty {
            LabeledContent("Warranty Coverage", value: "No coverage found")
        } else {
            ForEach(coverage) { coverage in
                LabeledContent("Warranty Coverage") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(coverage.displayStatus)
                            .foregroundStyle(
                                coverage.displayStatus == "Expired" ? Color.red
                                    : coverage.displayStatus == "Active" ? Color.green
                                    : Color.primary
                            )
                        if let description = coverage.description {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(DateFormatting.dateOnly(coverage.startDateTime)) – \(DateFormatting.dateOnly(coverage.endDateTime))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if info.device.hasActiveMigration {
            LabeledContent("Migration") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(info.device.mdmMigrationStatus?.capitalized ?? "In progress")
                        .foregroundStyle(.orange)
                    Text("by \(DateFormatting.short(info.device.mdmMigrationDeadlineDateTime))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if let outcome = info.device.migrationOutcome {
            LabeledContent("Migration", value: outcome)
        }

    }

    /// Activation Lock, from the Apple organization rather than the MDM.
    ///
    /// Unknown rather than Disabled when the organization gave no answer:
    /// Apple fails this read for a device reporting an internal-only lock
    /// state, and Disabled would be the wrong conclusion from a failure.
    @ViewBuilder
    private var activationLockRow: some View {
        LabeledContent("Activation Lock") {
            if isLoadingActivationLock {
                ProgressView().controlSize(.small)
            } else if let lock = activationLock {
                VStack(alignment: .trailing, spacing: 2) {
                    // Orange for enabled, plain for disabled: a lock can
                    // stand in the way of reusing a device, but neither
                    // state is a fault.
                    Text(lock.summary)
                        .foregroundStyle(lock.isLocked ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    if let detail = lock.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Unknown")
                    .foregroundStyle(.secondary)
                    .help("The organization did not report a lock state for this device.")
            }
        }
        .help("Reported by the Apple organization. Checkpoint does not read bypass codes or clear locks.")
    }

    @ViewBuilder
    private func abmActions(_ info: ABMInfo) -> some View {
        Picker("MDM Server", selection: $mdmSelection) {
            Text("Unassigned").tag(String?.none)
            // The device's own organization: a service ID from another one
            // would be rejected.
            ForEach(model.mdmServers(for: model.appleActionOrg(for: [report]))) { server in
                Text(server.name).tag(Optional(server.id))
            }
        }
        Button("Apply MDM Assignment") { pending = .applyMDM }
            .disabled(mdmSelection == info.mdmServerID)
        Button("Unassign from MDM Server") { pending = .unassignMDM }
            .disabled(info.mdmServerID == nil)

        if info.device.hasActiveMigration {
            DatePicker("New Deadline", selection: $migrationDeadline, in: migrationDeadlineRange)
            Button("Update Deadline") { pending = .updateDeadline }
            Button("Cancel Migration", role: .destructive) { pending = .cancelMigration }
            Text("The device is already assigned to \(info.mdmServerName ?? "the new server"). Cancelling stops the migration only, it does not return the assignment.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if info.device.isMdmMigrationCapable == true {
            DatePicker("Migration Deadline", selection: $migrationDeadline, in: migrationDeadlineRange)
            Button("Assign with Migration Deadline") { pending = .scheduleMigration }
                .disabled(mdmSelection == nil || mdmSelection == info.mdmServerID)
        }

        let releaseUnavailable = model.releaseUnavailabilityReason(for: [report])
        Button("Release from \(info.orgName ?? model.abmKind.label)", role: .destructive) { pending = .release }
            .disabled(releaseUnavailable != nil)
            .help(releaseUnavailable ?? "")
    }

    /// Apple rejects anything beyond 90 days.
    private var migrationDeadlineRange: ClosedRange<Date> {
        let now = Date()
        return now...now.addingTimeInterval(ABMClient.maximumMigrationDeadline)
    }

    // MARK: Jamf

    @ViewBuilder
    private var mdmContent: some View {
        switch report.mdm {
        case .pending:
            ProgressView().controlSize(.small)
        case .notConfigured:
            Text(missingConnectionHint)
                .foregroundStyle(.secondary)
        case .notFound:
            Text(noRecordHint)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case .found(let info):
            mdmDetails(info)
        }
    }

    /// The device management side of the inspector.
    ///
    /// Rows are gated on what the connected product reports, and a product
    /// that reports nothing for one gets no row at all rather than a row
    /// reading "—". Jamf School has no source for FileVault, MDM profile
    /// expiry, software update state or any enrollment date, so on a Jamf
    /// School server those five rows do not exist.
    @ViewBuilder
    private func mdmDetails(_ info: ManagedDeviceInfo) -> some View {
        let capabilities = model.capabilities(for: report)
        LabeledContent(info.kind == .computer ? "Computer Name" : "Device Name", value: info.name ?? "—")
        if let os = info.osDisplay {
            LabeledContent("OS Version", value: os)
        }
        if capabilities.contains(.sites), model.sites(for: report).isEmpty {
            LabeledContent("Site", value: info.siteName ?? "None")
        }
        if capabilities.contains(.locations), model.locations(for: report).isEmpty {
            LabeledContent("Location", value: info.locationName ?? "None")
        }
        // Shown only where there is something to show: a device with no
        // assignment, or a product that reports none, gets no row.
        if let department = info.department, !department.isEmpty {
            LabeledContent("Department", value: department)
        }
        if let building = info.building, !building.isEmpty {
            LabeledContent("Building", value: building)
        }
        if let room = info.room, !room.isEmpty {
            LabeledContent("Room", value: room)
        }
        if info.managedByApple {
            appleManagementRows
        }
        // No read-only asset tag row: the editable field among the actions
        // shows the current value, and one label should not appear twice.
        if capabilities.contains(.enrollmentDate) {
            LabeledContent("Last Enrollment Date", value: DateFormatting.short(info.lastEnrolledDate))
        }
        if capabilities.contains(.inventoryDates) {
            LabeledContent("Last Inventory Update", value: DateFormatting.short(info.reportDate))
        }
        if capabilities.contains(.compliance), let summary = info.complianceSummary {
            LabeledContent("Compliance", value: summary)
        }
        if capabilities.contains(.complianceOnDemand), let summary = compliance?.summary {
            LabeledContent("Compliance") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(summary)
                        .foregroundStyle(compliance?.state == "NON_COMPLIANT" ? Color.orange : Color.primary)
                    // Named because Jamf Pro relays the verdict rather than
                    // reaching it, so the vendor is who to ask about it.
                    if let vendor = compliance?.vendor, !vendor.isEmpty {
                        Text("Reported by \(DisplayText.sentenceCase(vendor))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        if !info.managedByApple, info.kind == .mobileDevice || info.lastContact != nil {
            LabeledContent(model.product(for: report).lastContactLabel, value: DateFormatting.short(info.lastContact))
        }
        if capabilities.contains(.inventoryDates), info.kind == .computer {
            LabeledContent("Last Check-in", value: DateFormatting.short(info.lastContactTime))
        }
        if capabilities.contains(.mdmProfileExpiry) {
            LabeledContent("MDM Profile Expiration") {
                let expired = info.mdmProfileExpiration
                    .flatMap(DateFormatting.parseISO)
                    .map { $0 < Date() } ?? false
                Text(DateFormatting.short(info.mdmProfileExpiration))
                    .foregroundStyle(expired ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
        }
        // Jamf School reports whether a device is still managed and
        // supervised, which is the nearest it comes to an enrollment state.
        if let managed = info.isManaged {
            LabeledContent("Managed") {
                Text(managed ? "Yes" : "No")
                    .foregroundStyle(managed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
        }
        if let supervised = info.isSupervised {
            LabeledContent("Supervised", value: supervised ? "Yes" : "No")
        }
        if let encryption = info.encryption {
            encryptionRow(encryption, kind: info.kind)
        }
        if let security = info.security {
            passcodeRow(security)
                .help(model.product(for: report) == .intune
                      ? "Derived from data protection, which iPhone and iPad enable exactly when a passcode is set."
                      : "")
        }
        if capabilities.contains(.passcodeOnDemand), info.kind == .mobileDevice {
            schoolPasscodeRow
        }
        if capabilities.contains(.softwareUpdate) {
            // Always shown for a device with a Jamf Pro record: "no update
            // plan" is itself the answer, and leaving the row out looked like
            // a feature that did not work.
            softwareUpdateRow(ddm?.softwareUpdate)
            betaProgramRow(ddm?.softwareUpdate)
        }
        if capabilities.contains(.declarations) {
            declarationRows
        }
    }

    /// Passcode state on Jamf School, which serves it only per device.
    ///
    /// The row shows that it is still loading rather than appearing late, so
    /// an empty passcode state is never mistaken for "no passcode".
    @ViewBuilder
    private var schoolPasscodeRow: some View {
        LabeledContent("Passcode") {
            if let details = schoolDetails {
                VStack(alignment: .trailing, spacing: 2) {
                    switch details.hasPasscode {
                    case true: Text("Set").foregroundStyle(.green)
                    case false: Text("Not set").foregroundStyle(.orange)
                    case nil: Text("—")
                    }
                    if details.passcodeCompliant == false {
                        Text("Does not meet requirements")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// Encryption state from inventory, labelled by device kind: FileVault on
    /// a computer, plain encryption on a mobile device. The mobile case is
    /// only ever an Intune device on a non-Apple platform — on iPhone and
    /// iPad the same flag reports data protection and fills the Passcode row
    /// instead. Distinct from the recovery key, which is fetched only on
    /// request.
    @ViewBuilder
    private func encryptionRow(_ encryption: DiskEncryptionState, kind: DeviceKind) -> some View {
        LabeledContent(kind == .computer ? "FileVault" : "Encryption") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(encryption.displaySummary)
                    .foregroundStyle(encryptionTint(encryption.status))
                if let warning = encryption.keyValidityWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .help(kind == .mobileDevice ? "Storage encryption, as Intune reports it." : "")
    }

    private func encryptionTint(_ status: DiskEncryptionState.Status) -> AnyShapeStyle {
        switch status {
        case .enabled: AnyShapeStyle(.green)
        case .notEnabled, .inProgress: AnyShapeStyle(.orange)
        case .ineligible, .unknown: AnyShapeStyle(.secondary)
        }
    }

    /// Passcode state for a mobile device. Presence and compliance are shown
    /// together: a device with no passcode can still be compliant when no
    /// profile requires one, so either alone would mislead.
    @ViewBuilder
    private func passcodeRow(_ security: MobileSecurityState) -> some View {
        if security.passcodePresent != nil || security.passcodeCompliant != nil {
            LabeledContent("Passcode") {
                VStack(alignment: .trailing, spacing: 2) {
                    if security.passcodePresent == true {
                        Text("Set").foregroundStyle(.green)
                    } else if security.passcodePresent == false {
                        Text("Not set").foregroundStyle(.orange)
                    } else {
                        Text("—")
                    }
                    if security.passcodeCompliantWithProfile == false {
                        Text("Does not meet the scoped profile")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if security.passcodeCompliant == false {
                        Text("Does not meet requirements")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    /// What the device last reported about software updates.
    ///
    /// The version and deadline appear only while an update is outstanding,
    /// and a failure the report still remembers appears as history: the
    /// report keeps all three long after they stop being true.
    @ViewBuilder
    private func softwareUpdateRow(_ update: JamfSoftwareUpdateStatus?) -> some View {
        LabeledContent("Software Update") {
            if let update {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(update.displayState)
                        .foregroundStyle(updateStateTint(update))
                    if let version = update.pendingVersion {
                        Text(version).font(.caption).foregroundStyle(.secondary)
                    }
                    if update.hasPendingUpdate, let deadline = update.deadline {
                        let overdue = deadline < Date()
                        Text("\(overdue ? "Was due" : "Due") \(DateFormatting.short(deadline))")
                            .font(.caption)
                            .foregroundStyle(overdue ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    // Enforcement is not restated here: the deadline above
                    // only exists while an update is enforced, and the
                    // Update Enforcement row below says what by and when.
                    if update.hasPendingUpdate, let reported = update.offerReportedAt {
                        Text("Reported \(DateFormatting.short(reported))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if update.hasCurrentFailure {
                        // The readable sentence, with the whole NSError text
                        // kept in the tooltip for diagnosis.
                        Text(update.failureSummary ?? "Software update failed.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                            .help(update.lastFailureReason ?? "")
                        if let at = update.lastFailureAt {
                            Text("Failed \(DateFormatting.short(at))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    } else if update.hasPastFailure, let at = update.lastFailureAt {
                        // Deliberately tertiary and past tense: this is a
                        // record of an attempt that is no longer current.
                        Text("Last failed \(DateFormatting.short(at))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .help(update.failureSummary ?? "Software update failed.")
                    }
                }
            } else {
                Text("Not reported")
                    .foregroundStyle(.secondary)
                    .help("The device has sent no declarative status report, so it is either not managed declaratively or has not reported yet.")
            }
        }
    }

    /// Whether the device is on a beta release, stated either way.
    ///
    /// Its own row rather than a line under Software Update: it is a standing
    /// fact about the device rather than part of a pending update, and "not
    /// enrolled" is worth saying rather than leaving to be inferred from an
    /// absent line.
    @ViewBuilder
    private func betaProgramRow(_ update: JamfSoftwareUpdateStatus?) -> some View {
        if let update, let beta = update.betaDisplay {
            LabeledContent("Beta Program") {
                Text(beta)
                    .foregroundStyle(update.isInBetaProgram ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    /// Red is reserved for the state that is itself a failure. Painting
    /// "Ready to install" red because a later attempt failed labels a sound
    /// state as a broken one, and the failure below already carries the
    /// colour.
    private func updateStateTint(_ update: JamfSoftwareUpdateStatus) -> AnyShapeStyle {
        if update.isFailedState { return AnyShapeStyle(.red) }
        return update.hasPendingUpdate ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    /// What the device made of the declarations sent to it, and when it last
    /// said so.
    ///
    /// Its own rows because the server's view and the device's can disagree:
    /// Jamf Pro reports a blueprint as deployed once it has handed the
    /// declaration over, while the device decides whether it can be applied.
    /// A rejected software update declaration means nothing is enforcing
    /// updates, however healthy the blueprint looks.
    @ViewBuilder
    private var declarationRows: some View {
        if let ddm, !ddm.declarations.isEmpty {
            // Once the declaration has been read back, its identifier settles
            // which one enforces updates. Without it, the device's own
            // wording is the only clue.
            let rejected = ddm.invalidDeclarations.first { $0.identifier == enforcement?.declarationID }
                ?? ddm.rejectedUpdateEnforcement
            if rejected != nil || enforcement != nil {
                let installed = report.mdm.value?.osVersion
                let satisfied = enforcement?.isSatisfied(
                    byOSVersion: installed,
                    build: report.mdm.value?.osBuild
                ) ?? false
                LabeledContent("Update Enforcement") {
                    VStack(alignment: .trailing, spacing: 2) {
                        if rejected != nil {
                            Text("Rejected by the device").foregroundStyle(.red)
                        } else if satisfied {
                            Text("Satisfied").foregroundStyle(.secondary)
                        } else {
                            Text("Outstanding").foregroundStyle(.primary)
                        }
                        // The target, read from the declaration. It is the
                        // version a device is actually held to, which is not
                        // the same as the one it has been offered.
                        if let target = enforcement?.targetVersion {
                            Text(target).font(.caption).foregroundStyle(.secondary)
                        }
                        // A date in the past means a missed deadline only
                        // while the target is still owed. On a device that
                        // complied it is just when it had to comply by.
                        if !satisfied, let due = enforcement?.targetLocalDateTime {
                            let overdue = due < Date()
                            Text("\(overdue ? "Was due" : "Due") \(DateFormatting.short(due))")
                                .font(.caption)
                                .foregroundStyle(overdue ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        }
                        if !satisfied, let installed, !installed.isEmpty {
                            Text("Installed \(installed)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        if !satisfied, enforcement?.isMajorUpgrade(fromOSVersion: installed) == true {
                            Text("Major upgrade")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        // Apple's own words: they name the version that no
                        // longer applies, which is the actionable part.
                        ForEach(Array((rejected?.reasons ?? []).prefix(2)), id: \.self) { reason in
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        if let declaration = rejected { blueprintLink(for: declaration) }
                    }
                }
            }
            LabeledContent("Declarations") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(declarationSummary(ddm))
                        .foregroundStyle(ddm.invalidDeclarations.isEmpty && ddm.notAppliedDeclarations.isEmpty
                                         ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    // Ones already spelled out above are not repeated.
                    ForEach(otherInvalidDeclarations(ddm)) { declaration in
                        Text(declaration.reasons.first ?? declaration.identifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                }
            }
        }
        if let reported = ddm?.reportedAt {
            LabeledContent("Status Reported") {
                // A report months old describes a device that has stopped
                // talking, not one that is in the state shown above.
                let stale = reported < Date().addingTimeInterval(-30 * 24 * 60 * 60)
                Text(DateFormatting.short(reported))
                    .foregroundStyle(stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .help(stale ? "Over a month old, so everything above may have changed since." : "")
            }
        }
    }

    /// Counts every outcome, not just the good one. A device can hold two
    /// dozen declarations with only one in effect, and reporting the active
    /// count alone would read as healthy.
    private func declarationSummary(_ ddm: JamfDDMStatus) -> String {
        var parts = ["\(ddm.activeDeclarations.count) active"]
        if !ddm.invalidDeclarations.isEmpty {
            parts.append("\(ddm.invalidDeclarations.count) invalid")
        }
        if !ddm.notAppliedDeclarations.isEmpty {
            parts.append("\(ddm.notAppliedDeclarations.count) not applied")
        }
        return parts.joined(separator: ", ")
    }

    private func otherInvalidDeclarations(_ ddm: JamfDDMStatus) -> [JamfDeclaration] {
        let named = ddm.rejectedUpdateEnforcement?.identifier
        return ddm.invalidDeclarations.filter { $0.identifier != named }
    }

    /// Links a declaration back to the blueprint that produced it, named when
    /// the connection can resolve one and identified by UUID otherwise.
    ///
    /// The link is built from the server URL rather than the API host, since
    /// the gateway serves no web interface.
    @ViewBuilder
    private func blueprintLink(for declaration: JamfDeclaration) -> some View {
        if let blueprint = declaration.blueprintID,
           let base = model.selectedConnection?.normalizedBaseURL,
           let url = URL(string: "\(base)/view/mfe/blueprints/\(blueprint)") {
            Link(blueprintName ?? "Open blueprint", destination: url)
                .font(.caption)
                .help(blueprintName == nil ? blueprint : "Blueprint \(blueprint)")
        }
    }

    @ViewBuilder
    private func mdmActions(_ info: ManagedDeviceInfo) -> some View {
        let capabilities = model.capabilities(for: report)
        if capabilities.contains(.sites), !model.sites(for: report).isEmpty {
            Picker("Site", selection: $siteSelection) {
                Text("None").tag("-1")
                ForEach(model.sites(for: report)) { site in
                    Text(site.name).tag(site.id)
                }
            }
            Button("Apply Site Change") { pending = .applySite }
                .disabled(siteSelection == (info.siteID ?? "-1"))
        }
        if capabilities.contains(.locations), !model.locations(for: report).isEmpty {
            Picker("Location", selection: $locationSelection) {
                Text("None").tag(String?.none)
                ForEach(model.locations(for: report)) { location in
                    Text(location.name).tag(Optional(location.id))
                }
            }
            Button("Apply Location Change") { pending = .applyLocation }
                .disabled(locationSelection == nil || locationSelection == info.locationID)
        }
        if capabilities.contains(.prestageScope) {
            Picker("PreStage", selection: $prestageSelection) {
                Text("None").tag(String?.none)
                ForEach(prestageChoices) { prestage in
                    Text(prestage.displayName).tag(Optional(prestage.id))
                }
            }
            Button("Apply PreStage Change") { pending = .applyPrestage }
                .disabled(prestageSelection == info.prestageID)
        }
        if capabilities.contains(.assetTag) {
            TextField("Asset Tag", text: $assetTagField, prompt: Text("None"))
            Button("Apply Asset Tag") { pending = .applyAssetTag }
                .disabled(assetTagField.trimmingCharacters(in: .whitespaces) == (info.assetTag ?? ""))
        }
        // Recovery secrets are read on demand and never kept on the report, so
        // they are not fetched by a lookup and do not appear in the table.
        if capabilities.contains(.recoverySecrets), info.kind == .computer {
            // Dimmed only when the disk is known not to be encrypted. While
            // encrypting, or when the state cannot be read, the key may still
            // exist, so the button stays available.
            let noKeyExpected = info.encryption?.isEncrypted == false
            Button("Show FileVault Recovery Key") {
                reveal(title: "FileVault Recovery Key") {
                    let key = try await model.fileVaultRecoveryKey(for: report)
                    return (key.personalRecoveryKey, key.validityStatus.map { "Key status: \($0)" })
                }
            }
            .disabled(noKeyExpected)
            .help(noKeyExpected ? "FileVault is not enabled on this Mac." : "")
            Button("Show Recovery Lock Password") {
                reveal(title: "Recovery Lock Password") {
                    (try await model.recoveryLockPassword(for: report), nil)
                }
            }
            Button("Show Device Lock PIN") {
                reveal(title: "Device Lock PIN") {
                    (try await model.deviceLockPIN(for: report), "Set when the Mac was locked through Jamf Pro.")
                }
            }
        }
        // Destructive action last, matching Release in the Apple Business block.
        Button(model.product(for: report).removeRecordLabel, role: .destructive) { pending = .deleteRecord }
    }

    /// One row per managed local administrator account Jamf Pro holds, in the
    /// shape the Jamf Pro interface uses. Accounts are enumerated rather than
    /// assumed: a Mac may carry the PreStage account, the one the Jamf binary
    /// created, both, or neither, under any username.
    @ViewBuilder
    private var localAdminRows: some View {
        ForEach(localAdmins) { account in
            LabeledContent(account.username) {
                HStack(spacing: 12) {
                    Text(account.sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("View") { pending = .viewLocalAdminPassword(account) }
                }
            }
        }
        Text("Viewing a password causes Jamf Pro to rotate it \(rotationDescription).")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Loads the detail that is fetched per device rather than per lookup.
    /// Failures are silent: both are supplementary, the LAPS privilege is
    /// optional, and this runs every time a device is selected.
    private func loadDeviceDetail() async {
        localAdmins = []
        rotationTime = nil
        ddm = nil
        enforcement = nil
        blueprintName = nil
        loadedCoverage = nil
        schoolDetails = nil
        compliance = nil
        activationLock = nil
        isLoadingActivationLock = report.abm.value?.isReleased == false
        loadedCoverage = await model.appleCareCoverage(for: report)
        activationLock = await model.activationLock(for: report)
        isLoadingActivationLock = false
        guard report.mdm.value != nil else { return }
        // Only ask each product for what it actually serves: a Jamf School
        // server has none of the endpoints below, and a Jamf Pro one carries
        // passcode state in the lookup already.
        if model.capabilities(for: report).contains(.passcodeOnDemand) {
            schoolDetails = await model.jamfSchoolDetails(for: report)
            return
        }
        appleDetail = report.mdm.value?.managedByApple == true
            ? await model.appleManagementDetail(for: report) : nil
        compliance = await model.deviceCompliance(for: report)
        // Gated rather than left to the client factory to refuse: a product
        // with no declarative reporting should not be asked in the first
        // place, and the same goes for the recovery secrets below.
        guard model.capabilities(for: report).contains(.declarations) else { return }
        ddm = await model.ddmStatus(for: report)
        // Both need the status first, and neither is worth a request for a
        // device with nothing declarative to say.
        if let ddm {
            enforcement = await model.updateEnforcement(in: ddm, for: report)
            if let blueprint = ddm.rejectedUpdateEnforcement?.blueprintID
                ?? ddm.declarations.compactMap(\.blueprintID).first {
                blueprintName = await model.blueprintName(for: blueprint, report: report)
            }
        }
        guard report.mdm.value?.kind == .computer,
              model.capabilities(for: report).contains(.recoverySecrets) else { return }
        localAdmins = await model.localAdminAccounts(for: report)
        if !localAdmins.isEmpty {
            rotationTime = await model.localAdminRotationTime(for: report)
        }
    }

    /// Fetches a secret and shows it in a sheet. Nothing is retained after the
    /// sheet is dismissed.
    private func reveal(title: String, _ fetch: @escaping () async throws -> (String, String?)) {
        isWorking = true
        Task {
            do {
                let (value, note) = try await fetch()
                revealedSecret = RevealedSecret(title: title, value: value, note: note)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    // MARK: MDM commands

    @ViewBuilder
    private func commandButtons(_ info: ManagedDeviceInfo) -> some View {
        let product = model.product(for: report)
        ForEach(MDMCommand.commands(for: info.kind, product: product), id: \.self) { command in
            let unavailable = model.unavailabilityReason(for: command, reports: [report])
                ?? command.inapplicabilityReason(for: info)
            Button(command.title, role: command.isDestructive ? .destructive : nil) {
                if command.needsPIN(product: product) {
                    pin = ""
                    pinCommand = command
                } else {
                    pending = .command(command)
                }
            }
            .disabled(unavailable != nil)
            .help(unavailable ?? command.message(for: product))
        }
        let blocked = MDMCommand.commands(for: info.kind, product: product)
            .filter { model.unavailabilityReason(for: $0, reports: [report]) != nil }
            .map(\.title)
        if !blocked.isEmpty {
            Text("\(blocked.formatted(.list(type: .and))) need an API client connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func executeWithPIN(_ command: MDMCommand) {
        let enteredPIN = pin
        guard enteredPIN.count == 6, enteredPIN.allSatisfy(\.isNumber) else {
            errorMessage = "The PIN must be exactly 6 digits."
            return
        }
        execute(command, pin: enteredPIN)
    }

    private func execute(_ command: MDMCommand, pin: String?) {
        run(successMessage: "\(command.title) was queued in \(model.product(for: report).label).") {
            try await model.sendCommand(command, reports: [report], passcode: pin)
        }
    }

    // MARK: Helpers

    /// Reads the report fresh from the model rather than from this view
    /// value: the async `run` closure captures the view (and its `report`)
    /// from before the action, so syncing from `self.report` there would
    /// reset the pickers to the pre-action values.
    private func syncSelections() {
        let current = model.reports.first { $0.serial == report.serial } ?? report
        mdmSelection = current.abm.value?.mdmServerID
        prestageSelection = current.mdm.value?.prestageID
        assetTagField = current.mdm.value?.assetTag ?? ""
        siteSelection = current.mdm.value?.siteID ?? "-1"
        locationSelection = current.mdm.value?.locationID
    }

    private func run(successMessage: String? = nil, _ operation: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            do {
                try await operation()
                if let successMessage { infoMessage = successMessage }
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
            syncSelections()
        }
    }
}

import SwiftUI

/// Inspector pane for a single device: full ABM and Jamf Pro details plus
/// the actions (assign/unassign MDM, release, change PreStage, delete record)
/// and Jamf Pro MDM remote commands. Every action asks for confirmation
/// before executing.
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
    /// Jamf School's per-device record, which carries the passcode state its
    /// device list leaves out. Fetched on selection for the same reason
    /// AppleCare coverage is.
    @State private var schoolDetails: JamfSchoolDeviceDetails?

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
        case deleteRecord
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

    var body: some View {
        Form {
            Section {
                LabeledContent("Serial Number") {
                    Text(report.serial).monospaced().textSelection(.enabled)
                }
                if let url = report.mdm.value?.webURL {
                    Link("Open in \(model.mdmProduct.label)", destination: url)
                }
            }
            // Read-only detail and the actions that act on it are kept in
            // separate sections, so the form reads as facts then choices.
            Section(model.abmKind.label) { abmContent }
            if let info = report.abm.value, !info.isReleased {
                Section { abmActions(info) }
            }
            Section(model.mdmProduct.label) { mdmContent }
            if let info = report.mdm.value {
                Section { mdmActions(info) }
                if !localAdmins.isEmpty {
                    Section("Managed Local Administrator Accounts") { localAdminRows }
                }
                Section("MDM Commands") { commandButtons(info) }
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
        .task { await model.loadADEInstances() }
        .onChange(of: report.serial) { syncSelections() }
        .onChange(of: report.abm.value?.mdmServerID) { syncSelections() }
        .onChange(of: report.mdm.value?.prestageID) { syncSelections() }
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
            Text("Enter the 6-digit PIN that will be required to unlock the Mac afterwards. \(pinCommand?.message(for: model.mdmProduct) ?? "")")
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
        let all = report.mdm.value?.kind == .mobileDevice ? model.mobilePrestages : model.prestages
        guard let instance = model.adeInstance(forSerial: report.serial) else { return all }
        let matching = all.filter { $0.enrollmentInstanceID == instance }
        return matching.isEmpty ? all : matching
    }

    private var selectedPrestageName: String? {
        prestageSelection.map { id in prestageChoices.first { $0.id == id }?.displayName ?? id }
    }

    private var selectedSiteName: String {
        model.sites.first { $0.id == siteSelection }?.name ?? "None"
    }

    private var selectedLocationName: String {
        locationSelection.map { id in
            model.jamfLocations.first { $0.id == id }?.name ?? id
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
        case .deleteRecord:
            model.mdmProduct.removeRecordPrompt(report.serial)
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
        case .deleteRecord:
            model.mdmProduct.removeRecordConsequence
        case .command(let command):
            command.message(for: model.mdmProduct)
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
        case .deleteRecord:
            Button(
                model.mdmProduct.removeRecordAction,
                role: .destructive
            ) {
                run { try await model.deleteMDMRecord(reports: [report]) }
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
            } else if info.device.status == "ASSIGNED" {
                Text("Assigned").foregroundStyle(.green)
            } else {
                Text("Unassigned").foregroundStyle(.orange)
            }
        }
        LabeledContent("Model", value: info.device.deviceModel ?? "—")
        LabeledContent("Date added", value: DateFormatting.short(info.device.addedToOrgDateTime))
        LabeledContent("Order", value: info.device.orderNumber ?? "—")
        LabeledContent("Purchase Source", value: info.device.purchaseSourceType ?? "—")

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

    @ViewBuilder
    private func abmActions(_ info: ABMInfo) -> some View {
        Picker("MDM Server", selection: $mdmSelection) {
            Text("Unassigned").tag(String?.none)
            ForEach(model.mdmServers) { server in
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

        let releaseUnavailable = model.releaseUnavailabilityReason
        Button("Release from \(model.abmKind.label)", role: .destructive) { pending = .release }
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
            Text(model.mdmProduct.missingConnectionHint)
                .foregroundStyle(.secondary)
        case .notFound:
            Text(model.mdmProduct.noRecordHint)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case .found(let info):
            mdmDetails(info)
        }
    }

    /// The Jamf side of the inspector.
    ///
    /// Rows are gated on what the connected product reports, and a product
    /// that reports nothing for one gets no row at all rather than a row
    /// reading "—". Jamf School has no source for FileVault, MDM profile
    /// expiry, software update state or any enrollment date, so on a Jamf
    /// School server those five rows do not exist.
    @ViewBuilder
    private func mdmDetails(_ info: ManagedDeviceInfo) -> some View {
        let capabilities = model.mdmCapabilities
        LabeledContent(info.kind == .computer ? "Computer Name" : "Device Name", value: info.name ?? "—")
        if let os = info.osDisplay {
            LabeledContent("OS Version", value: os)
        }
        if capabilities.contains(.sites), model.sites.isEmpty {
            LabeledContent("Site", value: info.siteName ?? "None")
        }
        if capabilities.contains(.locations), model.jamfLocations.isEmpty {
            LabeledContent("Location", value: info.locationName ?? "None")
        }
        if capabilities.contains(.enrollmentDate) {
            LabeledContent("Last Enrollment Date", value: DateFormatting.short(info.lastEnrolledDate))
        }
        if capabilities.contains(.inventoryDates) {
            LabeledContent("Last Inventory Update", value: DateFormatting.short(info.reportDate))
        }
        if capabilities.contains(.compliance), let compliance = info.complianceSummary {
            LabeledContent("Compliance", value: compliance)
        }
        if info.kind == .mobileDevice || info.lastContact != nil {
            LabeledContent(model.mdmProduct.lastContactLabel, value: DateFormatting.short(info.lastContact))
        }
        if capabilities.contains(.inventoryDates), info.kind == .computer {
            LabeledContent("Last check-in", value: DateFormatting.short(info.lastContactTime))
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
            fileVaultRow(encryption)
        }
        if let security = info.security {
            passcodeRow(security)
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

    /// FileVault state from inventory. Shown for every Mac, unlike the
    /// recovery key, which is fetched only on request.
    @ViewBuilder
    private func fileVaultRow(_ encryption: DiskEncryptionState) -> some View {
        LabeledContent("FileVault") {
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
        let capabilities = model.mdmCapabilities
        if capabilities.contains(.sites), !model.sites.isEmpty {
            Picker("Site", selection: $siteSelection) {
                Text("None").tag("-1")
                ForEach(model.sites) { site in
                    Text(site.name).tag(site.id)
                }
            }
            Button("Apply Site Change") { pending = .applySite }
                .disabled(siteSelection == (info.siteID ?? "-1"))
        }
        if capabilities.contains(.locations), !model.jamfLocations.isEmpty {
            Picker("Location", selection: $locationSelection) {
                Text("None").tag(String?.none)
                ForEach(model.jamfLocations) { location in
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
        Button(model.mdmProduct.removeRecordLabel, role: .destructive) { pending = .deleteRecord }
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
        loadedCoverage = await model.appleCareCoverage(for: report)
        guard report.mdm.value != nil else { return }
        // Only ask each product for what it actually serves: a Jamf School
        // server has none of the endpoints below, and a Jamf Pro one carries
        // passcode state in the lookup already.
        if model.mdmCapabilities.contains(.passcodeOnDemand) {
            schoolDetails = await model.jamfSchoolDetails(for: report)
            return
        }
        // Gated rather than left to the client factory to refuse: a product
        // with no declarative reporting should not be asked in the first
        // place, and the same goes for the recovery secrets below.
        guard model.mdmCapabilities.contains(.declarations) else { return }
        ddm = await model.ddmStatus(for: report)
        // Both need the status first, and neither is worth a request for a
        // device with nothing declarative to say.
        if let ddm {
            enforcement = await model.updateEnforcement(in: ddm)
            if let blueprint = ddm.rejectedUpdateEnforcement?.blueprintID
                ?? ddm.declarations.compactMap(\.blueprintID).first {
                blueprintName = await model.blueprintName(for: blueprint)
            }
        }
        guard report.mdm.value?.kind == .computer,
              model.mdmCapabilities.contains(.recoverySecrets) else { return }
        localAdmins = await model.localAdminAccounts(for: report)
        if !localAdmins.isEmpty {
            rotationTime = await model.localAdminRotationTime()
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
        let product = model.mdmProduct
        ForEach(MDMCommand.commands(for: info.kind, product: product), id: \.self) { command in
            let unavailable = model.unavailabilityReason(for: command)
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
            .filter { model.unavailabilityReason(for: $0) != nil }
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
        run(successMessage: "\(command.title) was queued in \(model.mdmProduct.label).") {
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

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
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var pending: PendingAction?
    @State private var pinCommand: MDMCommand?
    @State private var pin = ""
    @State private var localAdmins: [JamfLocalAdminAccount] = []
    @State private var rotationTime: TimeInterval?
    @State private var softwareUpdate: JamfSoftwareUpdateStatus?

    private enum PendingAction {
        case applyMDM
        case unassignMDM
        case release
        case scheduleMigration
        case updateDeadline
        case cancelMigration
        case applyPrestage
        case applySite
        case deleteJamf
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
            }
            // Read-only detail and the actions that act on it are kept in
            // separate sections, so the form reads as facts then choices.
            Section("Apple Business") { abmContent }
            if let info = report.abm.value, !info.isReleased {
                Section { abmActions(info) }
            }
            Section("Jamf Pro") { jamfContent }
            if let info = report.jamf.value {
                Section { jamfActions(info) }
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
        .task(id: report.jamf.value?.computerID) { await loadDeviceDetail() }
        .onChange(of: report.serial) { syncSelections() }
        .onChange(of: report.abm.value?.mdmServerID) { syncSelections() }
        .onChange(of: report.jamf.value?.prestageID) { syncSelections() }
        .onChange(of: report.jamf.value?.siteID) { syncSelections() }
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
            Text("Enter the 6-digit PIN that will be required to unlock the Mac afterwards. \(pinCommand?.message ?? "")")
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
        let all = report.jamf.value?.kind == .mobileDevice ? model.mobilePrestages : model.prestages
        guard let instance = report.jamf.value?.adeInstanceID else { return all }
        let matching = all.filter { $0.enrollmentInstanceID == instance }
        return matching.isEmpty ? all : matching
    }

    private var selectedPrestageName: String? {
        prestageSelection.map { id in prestageChoices.first { $0.id == id }?.displayName ?? id }
    }

    private var selectedSiteName: String {
        model.sites.first { $0.id == siteSelection }?.name ?? "None"
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
            "Release \(report.serial) from Apple Business?"
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
        case .deleteJamf:
            "Delete the Jamf Pro record for \(report.serial)?"
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
            "The Apple Business assignment changes immediately. Nothing is erased: the device keeps running under its current service until it migrates, and Apple prompts the user to migrate before \(migrationDeadline.formatted(date: .abbreviated, time: .shortened))."
        case .updateDeadline:
            "A deadline earlier than the current one, or in the past, is enforced immediately without giving the user the option to delay."
        case .cancelMigration:
            "Only the scheduled migration is cancelled. The device stays assigned to \(report.abm.value?.mdmServerName ?? "its assigned server") in Apple Business and keeps running under its current service. To undo the assignment as well, assign it back to the previous server."
        case .applyPrestage:
            "The device will be removed from its current PreStage scope\(selectedPrestageName == nil ? "." : " and added to the selected one.")"
        case .applySite:
            "Only the Jamf Pro record moves to the other site. The PreStages the device can join stay the same, because they follow the ADE token that synced it."
        case .deleteJamf:
            "The record will be deleted from the selected Jamf Pro server."
        case .command(let command):
            command.message
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
                let kind = report.jamf.value?.kind ?? .computer
                run { try await model.setPrestage(reports: [report], to: prestageSelection, kind: kind) }
            }
        case .applySite:
            Button("Change Site") {
                let siteID = siteSelection
                run { try await model.setSite(reports: [report], to: siteID) }
            }
        case .deleteJamf:
            Button("Delete Record", role: .destructive) {
                run { try await model.deleteFromJamf(reports: [report]) }
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
            Text("Add your Apple Business API credentials in Settings to see device status, warranty, and MDM assignment.")
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

        if info.coverage.isEmpty {
            LabeledContent("Warranty Coverage", value: "No coverage found")
        } else {
            ForEach(info.coverage) { coverage in
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

        Button("Release from Apple Business", role: .destructive) { pending = .release }
    }

    /// Apple rejects anything beyond 90 days.
    private var migrationDeadlineRange: ClosedRange<Date> {
        let now = Date()
        return now...now.addingTimeInterval(ABMClient.maximumMigrationDeadline)
    }

    // MARK: Jamf

    @ViewBuilder
    private var jamfContent: some View {
        switch report.jamf {
        case .pending:
            ProgressView().controlSize(.small)
        case .notConfigured:
            Text("Add a Jamf Pro server in Settings to see enrollment details and PreStage scope.")
                .foregroundStyle(.secondary)
        case .notFound:
            Text("No computer or mobile device record was found on the selected Jamf Pro server.")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case .found(let info):
            jamfDetails(info)
        }
    }

    @ViewBuilder
    private func jamfDetails(_ info: JamfInfo) -> some View {
        LabeledContent(info.kind == .computer ? "Computer Name" : "Device Name", value: info.name ?? "—")
        if model.sites.isEmpty {
            LabeledContent("Site", value: info.siteName ?? "None")
        }
        LabeledContent("Last Enrollment Date", value: DateFormatting.short(info.lastEnrolledDate))
        LabeledContent("Last Inventory Update", value: DateFormatting.short(info.reportDate))
        if info.kind == .mobileDevice || info.lastContact != nil {
            LabeledContent("Last Contact", value: DateFormatting.short(info.lastContact))
        }
        if info.kind == .computer {
            LabeledContent("Last check-in", value: DateFormatting.short(info.lastContactTime))
        }
        LabeledContent("MDM Profile Expiration") {
            let expired = info.mdmProfileExpiration
                .flatMap(DateFormatting.parseISO)
                .map { $0 < Date() } ?? false
            Text(DateFormatting.short(info.mdmProfileExpiration))
                .foregroundStyle(expired ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        if let encryption = info.encryption {
            fileVaultRow(encryption)
        }
        if let security = info.security {
            passcodeRow(security)
        }
        if let softwareUpdate {
            softwareUpdateRow(softwareUpdate)
        }
    }

    /// FileVault state from inventory. Shown for every Mac, unlike the
    /// recovery key, which is fetched only on request.
    @ViewBuilder
    private func fileVaultRow(_ encryption: JamfDiskEncryption) -> some View {
        LabeledContent("FileVault") {
            VStack(alignment: .trailing, spacing: 2) {
                if encryption.fileVaultEnabled == true {
                    Text("Enabled").foregroundStyle(.green)
                } else if encryption.fileVaultEnabled == false {
                    Text("Not enabled").foregroundStyle(.orange)
                } else {
                    Text("—")
                }
                if encryption.stateAddsDetail, let state = encryption.displayState {
                    // A percentage only means something mid-flight; a settled
                    // partition always reads 0 or 100.
                    let percent = encryption.bootPartitionPercent
                    let suffix = (!encryption.isSettled && percent != nil) ? " \(percent!)%" : ""
                    Text(state + suffix)
                        .font(.caption)
                        .foregroundStyle(encryption.isSettled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
                if let warning = encryption.keyValidityWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// Passcode state for a mobile device. Presence and compliance are shown
    /// together: a device with no passcode can still be compliant when no
    /// profile requires one, so either alone would mislead.
    @ViewBuilder
    private func passcodeRow(_ security: JamfMobileSecurity) -> some View {
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

    @ViewBuilder
    private func softwareUpdateRow(_ update: JamfSoftwareUpdateStatus) -> some View {
        LabeledContent("Software Update") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(update.displayStatus)
                if let remaining = update.deferralsRemaining, let maximum = update.maxDeferrals {
                    Text("\(remaining) of \(maximum) deferrals left")
                        .font(.caption)
                        .foregroundStyle(remaining == 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                if let next = update.nextScheduledInstall {
                    Text("Installs \(DateFormatting.short(next))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func jamfActions(_ info: JamfInfo) -> some View {
        if !model.sites.isEmpty {
            Picker("Site", selection: $siteSelection) {
                Text("None").tag("-1")
                ForEach(model.sites) { site in
                    Text(site.name).tag(site.id)
                }
            }
            Button("Apply Site Change") { pending = .applySite }
                .disabled(siteSelection == (info.siteID ?? "-1"))
        }
        Picker("PreStage", selection: $prestageSelection) {
            Text("None").tag(String?.none)
            ForEach(prestageChoices) { prestage in
                Text(prestage.displayName).tag(Optional(prestage.id))
            }
        }
        Button("Apply PreStage Change") { pending = .applyPrestage }
            .disabled(prestageSelection == info.prestageID)
        // Recovery secrets are read on demand and never kept on the report, so
        // they are not fetched by a lookup and do not appear in the table.
        if info.kind == .computer {
            Button("Show FileVault Recovery Key") {
                reveal(title: "FileVault Recovery Key") {
                    let key = try await model.fileVaultRecoveryKey(for: report)
                    return (key.personalRecoveryKey, key.validityStatus.map { "Key status: \($0)" })
                }
            }
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
        if let url = info.webURL {
            Link("Open in Jamf Pro", destination: url)
        }
        // Destructive action last, matching Release in the Apple Business block.
        Button("Remove from Jamf Pro", role: .destructive) { pending = .deleteJamf }
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
        softwareUpdate = nil
        guard report.jamf.value != nil else { return }
        softwareUpdate = await model.softwareUpdateStatus(for: report)
        guard report.jamf.value?.kind == .computer else { return }
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
    private func commandButtons(_ info: JamfInfo) -> some View {
        ForEach(MDMCommand.commands(for: info.kind), id: \.self) { command in
            let unavailable = model.unavailabilityReason(for: command)
            Button(command.title, role: command.isDestructive ? .destructive : nil) {
                if command.needsPIN {
                    pin = ""
                    pinCommand = command
                } else {
                    pending = .command(command)
                }
            }
            .disabled(unavailable != nil)
            .help(unavailable ?? command.message)
        }
        let blocked = MDMCommand.commands(for: info.kind)
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
        run(successMessage: "\(command.title) was queued in Jamf Pro.") {
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
        prestageSelection = current.jamf.value?.prestageID
        siteSelection = current.jamf.value?.siteID ?? "-1"
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

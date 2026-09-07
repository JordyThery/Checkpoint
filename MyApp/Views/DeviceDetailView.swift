import SwiftUI

/// Inspector pane for a single device: full ABM and Jamf Pro details plus
/// the actions (assign/unassign MDM, release, change PreStage, delete record)
/// and Jamf Pro MDM remote commands. Every action asks for confirmation
/// before executing.
struct DeviceDetailView: View {
    @Environment(LookupModel.self) private var model
    let report: DeviceReport

    @State private var mdmSelection: String?
    @State private var prestageSelection: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var pending: PendingAction?
    @State private var pinCommand: MDMCommand?
    @State private var pin = ""

    private enum PendingAction {
        case applyMDM
        case release
        case applyPrestage
        case deleteJamf
        case command(MDMCommand)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Serial Number") {
                    Text(report.serial).monospaced().textSelection(.enabled)
                }
            }
            Section("Apple Business Manager") { abmContent }
            Section("Jamf Pro") { jamfContent }
            if let info = report.jamf.value {
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
        .onChange(of: report.serial) { syncSelections() }
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

    private var prestageChoices: [JamfPrestage] {
        report.jamf.value?.kind == .mobileDevice ? model.mobilePrestages : model.prestages
    }

    private var selectedPrestageName: String? {
        prestageSelection.map { id in prestageChoices.first { $0.id == id }?.displayName ?? id }
    }

    private var pendingTitle: String {
        switch pending {
        case .applyMDM:
            if let selectedServerName {
                "Assign \(report.serial) to “\(selectedServerName)”?"
            } else {
                "Unassign \(report.serial) from its MDM server?"
            }
        case .release:
            "Release \(report.serial) from Apple Business Manager?"
        case .applyPrestage:
            if let selectedPrestageName {
                "Move \(report.serial) to PreStage “\(selectedPrestageName)”?"
            } else {
                "Remove \(report.serial) from its PreStage?"
            }
        case .deleteJamf:
            "Delete the Jamf Pro record for \(report.serial)?"
        case .command(let command):
            "\(command.title) — \(report.serial)?"
        case nil:
            ""
        }
    }

    private var pendingMessage: String {
        switch pending {
        case .applyMDM:
            "Apple processes MDM server assignments asynchronously — allow a moment before the new state appears."
        case .release:
            "The device will be removed from your organization and can no longer be assigned to an MDM server. This cannot be undone through the API."
        case .applyPrestage:
            "The device will be removed from its current PreStage scope\(selectedPrestageName == nil ? "." : " and added to the selected one.")"
        case .deleteJamf:
            "The record will be deleted from the selected Jamf Pro server."
        case .command(let command):
            command.message
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
        case .release:
            Button("Release Device", role: .destructive) {
                run { try await model.releaseFromABM(reports: [report]) }
            }
        case .applyPrestage:
            Button("Change PreStage") {
                let kind = report.jamf.value?.kind ?? .computer
                run { try await model.setPrestage(reports: [report], to: prestageSelection, kind: kind) }
            }
        case .deleteJamf:
            Button("Delete Record", role: .destructive) {
                run { try await model.deleteFromJamf(reports: [report]) }
            }
        case .command(let command):
            Button(command.title, role: command.isDestructive ? .destructive : nil) {
                execute(command, pin: nil)
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
            Text("Add your Apple Business Manager API credentials in Settings to see device status, warranty, and MDM assignment.")
                .foregroundStyle(.secondary)
        case .notFound:
            Text("This serial number is not part of your organization — it was never added, or it has been released.")
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

        if !info.isReleased {
            Picker("MDM Server", selection: $mdmSelection) {
                Text("Unassigned").tag(String?.none)
                ForEach(model.mdmServers) { server in
                    Text(server.name).tag(Optional(server.id))
                }
            }
            Button("Apply MDM Assignment") { pending = .applyMDM }
                .disabled(mdmSelection == info.mdmServerID)
            Button("Release from Apple Business Manager", role: .destructive) { pending = .release }
        }
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
        if let url = info.webURL {
            Link("Open in Jamf Pro", destination: url)
        }

        Picker("PreStage", selection: $prestageSelection) {
            Text("None").tag(String?.none)
            ForEach(prestageChoices) { prestage in
                Text(prestage.displayName).tag(Optional(prestage.id))
            }
        }
        Button("Apply PreStage Change") { pending = .applyPrestage }
            .disabled(prestageSelection == info.prestageID)
        Button("Remove from Jamf Pro", role: .destructive) { pending = .deleteJamf }
    }

    // MARK: MDM commands

    @ViewBuilder
    private func commandButtons(_ info: JamfInfo) -> some View {
        ForEach(MDMCommand.commands(for: info.kind), id: \.self) { command in
            Button(command.title, role: command.isDestructive ? .destructive : nil) {
                if command.needsPIN {
                    pin = ""
                    pinCommand = command
                } else {
                    pending = .command(command)
                }
            }
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

    private func syncSelections() {
        mdmSelection = report.abm.value?.mdmServerID
        prestageSelection = report.jamf.value?.prestageID
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

import SwiftUI

/// Inspector pane shown when several devices are selected: runs the same
/// actions as the single-device view against the whole selection at once,
/// including MDM remote commands. Every action asks for confirmation and
/// states how many devices it affects.
struct BulkActionsView: View {
    @Environment(LookupModel.self) private var model
    let reports: [DeviceReport]

    @State private var mdmSelection: BulkChoice = .none
    @State private var computerPrestageSelection: BulkChoice = .none
    @State private var mobilePrestageSelection: BulkChoice = .none
    @State private var siteSelection: BulkChoice = .none
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var pending: PendingAction?
    @State private var pinCommand: MDMCommand?
    @State private var pin = ""

    /// A picker value for a mixed selection: a concrete target, explicitly
    /// none, or "Multiple" when the selected devices currently differ.
    private enum BulkChoice: Hashable {
        case mixed
        case none
        case value(String)

        var appliedID: String? {
            if case .value(let id) = self { return id }
            return nil
        }
    }

    private enum PendingAction {
        case applyMDM
        case release
        case applyComputerPrestage
        case applyMobilePrestage
        case applySite
        case deleteJamf
        case command(MDMCommand)
    }

    /// Devices that are in ABM and not released — the ones ABM actions can touch.
    private var abmCount: Int {
        reports.filter { $0.abm.value.map { !$0.isReleased } ?? false }.count
    }

    /// Devices with a Jamf Pro record (computer or mobile device).
    private var jamfCount: Int {
        reports.filter { $0.jamf.value != nil }.count
    }

    private var computerCount: Int {
        reports.filter { $0.deviceKind == .computer }.count
    }

    private var mobileCount: Int {
        reports.filter { $0.deviceKind == .mobileDevice }.count
    }

    private var reportIDs: [String] {
        reports.map(\.id)
    }

    private func commandCount(_ command: MDMCommand) -> Int {
        reports.filter { report in
            report.jamf.value.map { command.applies(to: $0.kind) } ?? false
        }.count
    }

    // MARK: Current shared state across the selection

    private var currentMDMState: BulkChoice {
        var values = Set<String?>()
        for report in reports {
            if let abm = report.abm.value, !abm.isReleased {
                values.insert(abm.mdmServerID)
            }
        }
        if values.isEmpty { return .none }
        if values.count == 1 { return values.first!.map(BulkChoice.value) ?? .none }
        return .mixed
    }

    /// PreStages every selected device of the kind can join: filtered to the
    /// shared device-enrollment (ADE) instance when the selection has exactly
    /// one, the full list otherwise.
    private func prestageOptions(kind: JamfDeviceKind) -> [JamfPrestage] {
        let all = kind == .computer ? model.prestages : model.mobilePrestages
        let instances = Set(reports.filter { $0.deviceKind == kind }.compactMap { $0.jamf.value?.adeInstanceID })
        guard instances.count == 1, let instance = instances.first else { return all }
        let matching = all.filter { $0.enrollmentInstanceID == instance }
        return matching.isEmpty ? all : matching
    }

    private func currentPrestageState(kind: JamfDeviceKind) -> BulkChoice {
        var values = Set<String?>()
        for report in reports where report.deviceKind == kind {
            values.insert(report.jamf.value?.prestageID)
        }
        if values.isEmpty { return .none }
        if values.count == 1 { return values.first!.map(BulkChoice.value) ?? .none }
        return .mixed
    }

    private var currentSiteState: BulkChoice {
        var values = Set<String>()
        for report in reports {
            if let info = report.jamf.value {
                values.insert(info.siteID ?? "-1")
            }
        }
        if values.isEmpty { return .none }
        if values.count == 1 { return values.first == "-1" ? .none : .value(values.first!) }
        return .mixed
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Selected Devices", value: "\(reports.count)")
                LabeledContent("Computers", value: "\(computerCount)")
                LabeledContent("Mobile Devices", value: "\(mobileCount)")
                LabeledContent("In Apple Business", value: "\(abmCount)")
                LabeledContent("With Jamf Pro Record", value: "\(jamfCount)")
            }
            Section("Apple Business") {
                bulkPicker("MDM Server", selection: $mdmSelection, currentState: currentMDMState, noneLabel: "Unassigned", options: model.mdmServers.map { ($0.id, $0.name) })
                Button("Apply MDM Assignment to \(count(abmCount))") { pending = .applyMDM }
                    .disabled(abmCount == 0 || mdmSelection == .mixed || mdmSelection == currentMDMState)
                Button("Release \(count(abmCount)) from Apple Business", role: .destructive) { pending = .release }
                    .disabled(abmCount == 0)
            }
            if computerCount > 0 {
                Section("Computer PreStage") {
                    bulkPicker("PreStage", selection: $computerPrestageSelection, currentState: currentPrestageState(kind: .computer), noneLabel: "None", options: prestageOptions(kind: .computer).map { ($0.id, $0.displayName) })
                    Button("Apply PreStage to \(count(computerCount))") { pending = .applyComputerPrestage }
                        .disabled(computerPrestageSelection == .mixed || computerPrestageSelection == currentPrestageState(kind: .computer))
                }
            }
            if mobileCount > 0 {
                Section("Mobile Device PreStage") {
                    bulkPicker("PreStage", selection: $mobilePrestageSelection, currentState: currentPrestageState(kind: .mobileDevice), noneLabel: "None", options: prestageOptions(kind: .mobileDevice).map { ($0.id, $0.displayName) })
                    Button("Apply PreStage to \(count(mobileCount))") { pending = .applyMobilePrestage }
                        .disabled(mobilePrestageSelection == .mixed || mobilePrestageSelection == currentPrestageState(kind: .mobileDevice))
                }
            }
            if jamfCount > 0 && !model.sites.isEmpty {
                Section("Jamf Pro Site") {
                    bulkPicker("Site", selection: $siteSelection, currentState: currentSiteState, noneLabel: "None", options: model.sites.map { ($0.id, $0.name) })
                    Button("Apply Site to \(count(jamfCount))") { pending = .applySite }
                        .disabled(siteSelection == .mixed || siteSelection == currentSiteState)
                }
            }
            Section("MDM Commands") {
                ForEach(MDMCommand.allInDisplayOrder.filter { commandCount($0) > 0 }, id: \.self) { command in
                    let unavailable = model.unavailabilityReason(for: command)
                    Button("\(command.title) (\(commandCount(command)))", role: command.isDestructive ? .destructive : nil) {
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
                Button("Remove \(count(jamfCount)) from Jamf Pro", role: .destructive) { pending = .deleteJamf }
                    .disabled(jamfCount == 0)
                if model.isUsingPlatformAPI {
                    Text("Some MDM commands are unavailable over the Platform API. Hover a dimmed command to see why.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .onChange(of: reportIDs) { syncSelections() }
        .onChange(of: currentMDMState) { _, newValue in mdmSelection = newValue }
        .onChange(of: currentPrestageState(kind: .computer)) { _, newValue in computerPrestageSelection = newValue }
        .onChange(of: currentPrestageState(kind: .mobileDevice)) { _, newValue in mobilePrestageSelection = newValue }
        .onChange(of: currentSiteState) { _, newValue in siteSelection = newValue }
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
            pinCommand.map { "\($0.title) — \(count(commandCount($0)))" } ?? "",
            isPresented: Binding(get: { pinCommand != nil }, set: { if !$0 { pinCommand = nil } })
        ) {
            TextField("6-digit PIN", text: $pin)
            Button("Cancel", role: .cancel) {}
            Button(pinCommand?.title ?? "Send", role: .destructive) {
                if let command = pinCommand { executeWithPIN(command) }
            }
        } message: {
            Text("Enter the 6-digit PIN that will be required to unlock the Macs afterwards. The same PIN is used for every selected computer. \(pinCommand?.message ?? "")")
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

    /// Picker that shows a "Multiple" entry when the selected devices
    /// currently have differing values.
    @ViewBuilder
    private func bulkPicker(
        _ title: String,
        selection: Binding<BulkChoice>,
        currentState: BulkChoice,
        noneLabel: String,
        options: [(id: String, name: String)]
    ) -> some View {
        Picker(title, selection: selection) {
            if currentState == .mixed {
                Text("Multiple").tag(BulkChoice.mixed)
            }
            Text(noneLabel).tag(BulkChoice.none)
            ForEach(options, id: \.id) { option in
                Text(option.name).tag(BulkChoice.value(option.id))
            }
        }
    }

    // MARK: Confirmation

    private func count(_ n: Int) -> String {
        "\(n) Device\(n == 1 ? "" : "s")"
    }

    private var selectedServerName: String? {
        mdmSelection.appliedID.map { id in model.mdmServers.first { $0.id == id }?.name ?? id }
    }

    private func selectedPrestageName(_ choice: BulkChoice, in prestages: [JamfPrestage]) -> String? {
        choice.appliedID.map { id in prestages.first { $0.id == id }?.displayName ?? id }
    }

    private var pendingTitle: String {
        switch pending {
        case .applyMDM:
            if let selectedServerName {
                "Assign \(count(abmCount)) to “\(selectedServerName)”?"
            } else {
                "Unassign \(count(abmCount)) from their MDM server?"
            }
        case .release:
            "Release \(count(abmCount)) from Apple Business?"
        case .applyComputerPrestage:
            if let name = selectedPrestageName(computerPrestageSelection, in: model.prestages) {
                "Move \(count(computerCount)) to PreStage “\(name)”?"
            } else {
                "Remove \(count(computerCount)) from their PreStage?"
            }
        case .applyMobilePrestage:
            if let name = selectedPrestageName(mobilePrestageSelection, in: model.mobilePrestages) {
                "Move \(count(mobileCount)) to PreStage “\(name)”?"
            } else {
                "Remove \(count(mobileCount)) from their PreStage?"
            }
        case .applySite:
            "Move \(count(jamfCount)) to site “\(selectedSiteName)”?"
        case .deleteJamf:
            "Delete \(count(jamfCount)) from Jamf Pro?"
        case .command(let command):
            "\(command.title) — \(count(commandCount(command)))?"
        case nil:
            ""
        }
    }

    private var selectedSiteName: String {
        siteSelection.appliedID.flatMap { id in model.sites.first { $0.id == id }?.name } ?? "None"
    }

    private var pendingMessage: String {
        switch pending {
        case .applyMDM:
            "Devices that are released or not in Apple Business are skipped. Apple processes assignments asynchronously."
        case .release:
            "The devices will be removed from your organization and can no longer be assigned to an MDM server. This cannot be undone through the API."
        case .applyComputerPrestage, .applyMobilePrestage:
            "Devices are removed from their current PreStage scope and added to the selected one. Devices already in the selected PreStage, and devices of the other type, are skipped."
        case .applySite:
            "Only the Jamf Pro records move to the other site. The PreStages each device can join stay the same — they follow the ADE token that synced it."
        case .deleteJamf:
            "The computer and mobile device records will be deleted from the selected Jamf Pro server."
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
            Button(mdmSelection == .none ? "Unassign Devices" : "Assign Devices") {
                run { try await model.setMDMServer(reports: reports, to: mdmSelection.appliedID) }
            }
        case .release:
            Button("Release Devices", role: .destructive) {
                run { try await model.releaseFromABM(reports: reports) }
            }
        case .applyComputerPrestage:
            Button("Change PreStage") {
                run { try await model.setPrestage(reports: reports, to: computerPrestageSelection.appliedID, kind: .computer) }
            }
        case .applyMobilePrestage:
            Button("Change PreStage") {
                run { try await model.setPrestage(reports: reports, to: mobilePrestageSelection.appliedID, kind: .mobileDevice) }
            }
        case .applySite:
            Button("Change Site") {
                let siteID = siteSelection.appliedID ?? "-1"
                run { try await model.setSite(reports: reports, to: siteID) }
            }
        case .deleteJamf:
            Button("Delete Records", role: .destructive) {
                run { try await model.deleteFromJamf(reports: reports) }
            }
        case .command(let command):
            Button(command.title, role: command.isDestructive ? .destructive : nil) {
                execute(command, pin: nil)
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: Execution

    private func syncSelections() {
        mdmSelection = currentMDMState
        computerPrestageSelection = currentPrestageState(kind: .computer)
        mobilePrestageSelection = currentPrestageState(kind: .mobileDevice)
        siteSelection = currentSiteState
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
        run(successMessage: "\(command.title) was queued for \(count(commandCount(command))) in Jamf Pro.") {
            try await model.sendCommand(command, reports: reports, passcode: pin)
        }
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
        }
    }
}

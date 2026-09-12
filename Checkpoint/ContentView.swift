import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LookupModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @State private var serialsText = ""
    @State private var selection = Set<DeviceReport.ID>()
    @State private var showingImporter = false
    @State private var importMessage: String?
    @State private var deviceFilter: DeviceFilter = .all
    @State private var showingGroupPicker = false
    @State private var pendingGroup: PendingGroup?

    /// A chosen group, held until its size has been confirmed. A group can
    /// hold several hundred devices, which the name alone does not reveal.
    private struct PendingGroup: Identifiable {
        let id = UUID()
        let group: JamfGroup
        let serials: [String]
    }

    /// Above this, a group lookup asks first. Small groups go straight
    /// through: a confirmation nobody can answer usefully is just a delay.
    private static let confirmGroupLookupAbove = 25

    private enum DeviceFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case computers = "Computers"
        case mobileDevices = "Mobile Devices"
        var id: String { rawValue }
    }

    private var visibleReports: [DeviceReport] {
        switch deviceFilter {
        case .all: model.reports
        case .computers: model.reports.filter { $0.deviceKind == .computer }
        case .mobileDevices: model.reports.filter { $0.deviceKind == .mobileDevice }
        }
    }

    private var selectedReports: [DeviceReport] {
        visibleReports.filter { selection.contains($0.id) }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 0) {
                inputBar
                if !model.isABMConfigured || settings.jamfServers.isEmpty {
                    configurationHint
                }
                Divider()
                if model.reports.isEmpty {
                    ContentUnavailableView(
                        "No Devices",
                        systemImage: "laptopcomputer.and.iphone",
                        description: Text("Enter serial numbers above, or import a text/CSV list, to check their status in Apple Business and Jamf Pro.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    filterBar
                    resultsTable
                }
            }
            .navigationTitle("Checkpoint")
            .toolbar {
                // Hidden until something is configured: an empty popup button is
                // unexplained chrome, and the hint below already points at Settings.
                if !settings.abmOrgs.isEmpty {
                    ToolbarItem {
                        // Reads through selectedABMOrg so the popup shows the
                        // organization in use, including the implicit first one.
                        Picker("Apple Business organization", selection: Binding(
                            get: { model.selectedABMOrg?.id },
                            set: { model.selectedABMOrgID = $0 }
                        )) {
                            ForEach(settings.abmOrgs) { org in
                                Text(org.displayName).tag(Optional(org.id))
                            }
                        }
                        .help("Apple Business organization used for lookups and actions")
                    }
                }
                if !settings.jamfServers.isEmpty {
                    ToolbarItem {
                        Picker("Jamf Pro server", selection: Binding(
                            get: { model.selectedJamfServer?.id },
                            set: { model.selectedJamfServerID = $0 }
                        )) {
                            ForEach(settings.jamfServers) { server in
                                Text(server.displayName).tag(Optional(server.id))
                            }
                        }
                        .help("Jamf Pro server used for lookups and actions")
                    }
                }
                ToolbarItem {
                    Button {
                        openSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Configure Apple Business and Jamf Pro credentials")
                }
            }
        }
        .inspector(isPresented: Binding(
            get: { !selection.isEmpty },
            set: { if !$0 { selection.removeAll() } }
        )) {
            if selectedReports.count > 1 {
                BulkActionsView(reports: selectedReports)
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 500)
            } else if let report = selectedReports.first {
                DeviceDetailView(report: report)
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 500)
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item]) { result in
            handleImport(result)
        }
        .sheet(isPresented: $showingGroupPicker) {
            GroupPickerView { group, serials in
                handleGroup(group, serials: serials)
            }
            .environment(model)
        }
        .alert(
            pendingGroup.map { "Look up \(LookupModel.deviceCount($0.serials)) from “\($0.group.name)”?" } ?? "",
            isPresented: Binding(get: { pendingGroup != nil }, set: { if !$0 { pendingGroup = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Look Up") {
                pendingGroup = nil
                lookUp()
            }
        } message: {
            Text("Each device is checked against both Apple Business and Jamf Pro, so a group this size takes a while.")
        }
        .alert(
            "Import",
            isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
    }

    private var inputBar: some View {
        HStack(alignment: .top, spacing: 12) {
            TextField(
                "Serial numbers (separate with spaces, commas, or new lines)",
                text: $serialsText,
                axis: .vertical
            )
            .lineLimit(1...6)
            .textFieldStyle(.roundedBorder)
            .onSubmit(lookUp)
            Button("Import…") { showingImporter = true }
                .help("Import a text or CSV file with one serial number per line")
                .disabled(model.isLoading)
            Button("Group…") { showingGroupPicker = true }
                .help("Look up every device in a Jamf Pro group")
                .disabled(model.isLoading || settings.jamfServers.isEmpty)
            Button("Clear") { clear() }
                .help("Remove every device from the list")
                .disabled(model.isLoading || (model.reports.isEmpty && serialsText.isEmpty))
            Button(action: lookUp) {
                Text("Look Up")
                    .frame(minWidth: 60)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isLoading || serialsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if model.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    // Lookups run through a fixed window, so a large list
                    // takes long enough to be worth counting down.
                    if model.totalLookups > Self.confirmGroupLookupAbove {
                        Text("\(model.completedLookups) of \(model.totalLookups)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
    }

    private var configurationHint: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if !model.isABMConfigured && settings.jamfServers.isEmpty {
                Text("Apple Business and Jamf Pro are not configured yet.")
            } else if !model.isABMConfigured {
                Text("Apple Business is not configured, so its columns will be empty.")
            } else {
                Text("No Jamf Pro server is configured, so its columns will be empty.")
            }
            Button("Open Settings…") { openSettings() }
                .buttonStyle(.link)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var filterBar: some View {
        HStack {
            Picker("Show", selection: $deviceFilter) {
                ForEach(DeviceFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .onChange(of: deviceFilter) {
                let visibleIDs = Set(visibleReports.map(\.id))
                selection = selection.intersection(visibleIDs)
            }
            Spacer()
            Text("\(visibleReports.count) of \(model.reports.count) device\(model.reports.count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var resultsTable: some View {
        Table(visibleReports, selection: $selection) {
            Group {
                TableColumn("Serial Number") { (report: DeviceReport) in
                    Text(report.serial).monospaced()
                }
                TableColumn("Apple Business") { (report: DeviceReport) in
                    ABMStatusCell(state: report.abm)
                }
                TableColumn("MDM Server Assignment") { (report: DeviceReport) in
                    FetchText(state: report.abm) { $0.mdmServerName ?? ($0.isReleased ? "—" : "None") }
                }
                TableColumn("Migration") { (report: DeviceReport) in
                    MigrationCell(state: report.abm)
                }
                TableColumn("Warranty Coverage") { (report: DeviceReport) in
                    FetchText(state: report.abm) { Self.coverageSummary($0) }
                }
                TableColumn("Jamf Pro Device Name") { (report: DeviceReport) in
                    JamfStatusCell(state: report.jamf)
                }
                TableColumn("PreStage") { (report: DeviceReport) in
                    FetchText(state: report.jamf) { $0.prestageName ?? "None" }
                }
            }
            Group {
                TableColumn("Last Enrollment Date") { (report: DeviceReport) in
                    FetchText(state: report.jamf) { DateFormatting.short($0.lastEnrolledDate) }
                }
                TableColumn("Last Inventory Update") { (report: DeviceReport) in
                    FetchText(state: report.jamf) { DateFormatting.short($0.reportDate) }
                }
                TableColumn("Last Contact") { (report: DeviceReport) in
                    FetchText(state: report.jamf) { DateFormatting.short($0.lastContact) }
                }
                TableColumn("Last check-in") { (report: DeviceReport) in
                    FetchText(state: report.jamf) { DateFormatting.short($0.lastContactTime) }
                }
                TableColumn("MDM Profile Expiration") { (report: DeviceReport) in
                    FetchText(state: report.jamf) { DateFormatting.dateOnly($0.mdmProfileExpiration) }
                }
                TableColumn("") { (report: DeviceReport) in
                    if let url = report.jamf.value?.webURL {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .help("Open in Jamf Pro")
                    }
                }
                .width(28)
            }
        }
        .contextMenu(forSelectionType: DeviceReport.ID.self) { ids in
            Button("Open in Jamf Pro") { openInJamf(ids) }
        } primaryAction: { ids in
            openInJamf(ids)
        }
    }

    private func lookUp() {
        selection.removeAll()
        let text = serialsText
        Task { await model.lookUp(serialsText: text) }
    }

    /// Puts a group's serials in the field, then either looks them up or asks
    /// first, depending on how many there are. The field is filled either way,
    /// so declining the confirmation leaves the serials ready to run manually.
    private func handleGroup(_ group: JamfGroup, serials: [String]) {
        serialsText = serials.joined(separator: "\n")
        if serials.count > Self.confirmGroupLookupAbove {
            pendingGroup = PendingGroup(group: group, serials: serials)
        } else {
            lookUp()
        }
    }

    private func clear() {
        serialsText = ""
        selection.removeAll()
        model.clearReports()
    }

    private func openInJamf(_ ids: Set<DeviceReport.ID>) {
        for id in ids {
            if let url = model.reports.first(where: { $0.id == id })?.jamf.value?.webURL {
                openURL(url)
            }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            importMessage = "Could not read the file as text."
            return
        }
        let serials = LookupModel.parseImportedList(contents)
        guard !serials.isEmpty else {
            importMessage = "No serial numbers were found in the file. Expected one serial per line, or a CSV with serials in the first column."
            return
        }
        serialsText = serials.joined(separator: "\n")
        lookUp()
    }

    static func coverageSummary(_ info: ABMInfo) -> String {
        guard let coverage = info.coverage.first else { return "No coverage found" }
        let status = coverage.displayStatus
        guard let end = coverage.endDateTime else { return status }
        return status == "Expired"
            ? "Expired \(DateFormatting.dateOnly(end))"
            : "\(status) until \(DateFormatting.dateOnly(end))"
    }
}

// MARK: - Cells

struct FetchText<Value: Sendable>: View {
    let state: FetchState<Value>
    let text: (Value) -> String

    var body: some View {
        switch state {
        case .pending:
            Text("…").foregroundStyle(.tertiary)
        case .notConfigured, .notFound:
            Text("—").foregroundStyle(.tertiary)
        case .failed(let message):
            Label("Error", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(message)
        case .found(let value):
            Text(text(value))
        }
    }
}

/// Device management service migration state. Blank for the common case of a
/// device that has never had one scheduled, so the column only draws attention
/// when there is something to act on.
struct MigrationCell: View {
    let state: FetchState<ABMInfo>

    var body: some View {
        switch state {
        case .pending:
            Text("…").foregroundStyle(.tertiary)
        case .notConfigured, .notFound:
            Text("—").foregroundStyle(.tertiary)
        case .failed(let message):
            Label("Error", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(message)
        case .found(let info):
            let device = info.device
            if device.hasActiveMigration {
                let due = DateFormatting.short(device.mdmMigrationDeadlineDateTime)
                Text(due == "—" ? (device.mdmMigrationStatus?.capitalized ?? "In progress") : due)
                    .foregroundStyle(.orange)
                    .help("Migration \(device.mdmMigrationStatus?.lowercased() ?? "in progress"), due by this date.")
            } else if let outcome = device.migrationOutcome {
                Text(outcome)
                    .foregroundStyle(outcome == "Migrated" ? Color.green : Color.secondary)
                    .help(outcome == "Migrated"
                          ? "The device migrated to its assigned service."
                          : "No migration is scheduled. Apple reports a cancelled migration and an unsuccessful one the same way, so this covers both. The Apple Business assignment is unaffected.")
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }
}

struct ABMStatusCell: View {
    let state: FetchState<ABMInfo>

    var body: some View {
        switch state {
        case .pending:
            ProgressView().controlSize(.small)
        case .notConfigured:
            Text("Not configured").foregroundStyle(.tertiary)
        case .notFound:
            Text("Not in org").foregroundStyle(.red)
        case .failed(let message):
            Label("Error", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(message)
        case .found(let info):
            if info.isReleased {
                Text("Released").foregroundStyle(.red)
            } else if info.device.status == "ASSIGNED" {
                Text("Assigned").foregroundStyle(.green)
            } else {
                Text("Unassigned").foregroundStyle(.orange)
            }
        }
    }
}

struct JamfStatusCell: View {
    let state: FetchState<JamfInfo>

    var body: some View {
        switch state {
        case .pending:
            ProgressView().controlSize(.small)
        case .notConfigured:
            Text("Not configured").foregroundStyle(.tertiary)
        case .notFound:
            Text("No record").foregroundStyle(.red)
        case .failed(let message):
            Label("Error", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(message)
        case .found(let info):
            Text(info.name ?? "Record #\(info.computerID)")
                .foregroundStyle(.green)
        }
    }
}

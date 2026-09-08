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
                // Both pickers stay hidden until something is configured — an
                // empty popup button is just unexplained chrome, and the
                // configuration hint below already points at Settings.
                if !settings.abmOrgs.isEmpty {
                    ToolbarItem {
                        // Reads through selectedABMOrg so the popup shows the
                        // organization actually in use, including the implicit
                        // first one when nothing has been picked yet.
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
                ProgressView()
                    .controlSize(.small)
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
                Text("Apple Business is not configured — ABM columns will be empty.")
            } else {
                Text("No Jamf Pro server is configured — Jamf columns will be empty.")
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

import SwiftUI
import UniformTypeIdentifiers

/// Shows what Checkpoint asked the two services to do and how they answered.
/// Held in memory only: closing the app discards it.
struct ActivityLogView: View {
    @Environment(ActivityLog.self) private var log

    @State private var searchText = ""
    @State private var selection: ActivityEntry.ID?
    @State private var exportDocument: PlainTextDocument?
    @State private var isExporting = false
    @State private var statusMessage: String?

    /// Newest first, which is the order a log is read in.
    private var visible: [ActivityEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let newestFirst = Array(log.entries.reversed())
        guard !query.isEmpty else { return newestFirst }
        return newestFirst.filter { $0.matches(query) }
    }

    private var selectedEntry: ActivityEntry? {
        log.entries.first { $0.id == selection }
    }

    var body: some View {
        VSplitView {
            table
                .frame(minHeight: 180)
            detail
                .frame(minHeight: 140)
        }
        .frame(minWidth: 720, minHeight: 420)
        .searchable(text: $searchText, prompt: "Search the log")
        .toolbar { toolbarContent }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "Checkpoint Activity Log"
        ) { result in
            if case .failure(let error) = result {
                statusMessage = error.localizedDescription
            }
        }
    }

    // MARK: Table

    @ViewBuilder
    private var table: some View {
        if log.entries.isEmpty {
            ContentUnavailableView(
                "No Activity Yet",
                systemImage: "list.bullet.rectangle",
                description: Text("Look up a device or send a command and the requests will appear here. The log is kept in memory only and is discarded when Checkpoint quits.")
            )
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            Table(visible, selection: $selection) {
                TableColumn("") { entry in
                    Image(systemName: entry.outcome == .succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(entry.outcome == .succeeded ? .green : .red)
                        .help(entry.outcome == .succeeded ? "Succeeded" : "Failed")
                }
                .width(20)

                TableColumn("Time") { entry in
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 80, max: 110)

                TableColumn("Event") { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.summary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let connection = entry.connection, !connection.isEmpty {
                            Text("\(entry.service.rawValue) · \(connection)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(entry.service.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                TableColumn("Kind") { entry in
                    Text(entry.kind.rawValue)
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 70, max: 90)

                TableColumn("Status") { entry in
                    Text(entry.statusText)
                        .monospacedDigit()
                        .foregroundStyle(entry.outcome == .succeeded ? Color.secondary : Color.red)
                }
                .width(min: 48, ideal: 56, max: 72)

                TableColumn("Took") { entry in
                    Text(entry.durationText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 52, ideal: 60, max: 80)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Details")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let message = statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let entry = selectedEntry {
                    Button {
                        copy(text(for: entry))
                    } label: {
                        Image(systemName: "document.on.document")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy this entry")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            if let entry = selectedEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.summary)
                            .font(.body.weight(.medium))
                            .textSelection(.enabled)

                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                            ForEach(facts(for: entry), id: \.label) { fact in
                                GridRow {
                                    Text(fact.label)
                                        .foregroundStyle(.secondary)
                                        .gridColumnAlignment(.trailing)
                                    Text(fact.value)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .font(.callout)

                        if let note = entry.bodyNote {
                            Label(note, systemImage: "lock.fill")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if let body = entry.requestBody {
                            bodyBlock("Request body", body)
                        }
                        if let body = entry.responseBody {
                            bodyBlock("Response body", body)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            } else {
                Text("Select an entry to see its request and response.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
    }

    private func facts(for entry: ActivityEntry) -> [(label: String, value: String)] {
        var facts: [(label: String, value: String)] = [
            ("Time", entry.date.formatted(date: .abbreviated, time: .standard)),
            ("Kind", entry.kind.rawValue),
            ("Service", entry.service.rawValue),
        ]
        if let connection = entry.connection, !connection.isEmpty {
            facts.append(("Connection", connection))
        }
        if entry.status != nil { facts.append(("Status", entry.statusText)) }
        if entry.duration != nil { facts.append(("Took", entry.durationText)) }
        return facts
    }

    private func bodyBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(body)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("Copy Log") { copy(log.exportText(maskingIdentifiers: false)) }
                Button("Copy Log, Devices Masked") { copy(log.exportText(maskingIdentifiers: true)) }
                Divider()
                Button("Export Log…") { export(maskingIdentifiers: false) }
                Button("Export Log, Devices Masked…") { export(maskingIdentifiers: true) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(log.entries.isEmpty)
            .help("Copy or export the log. The masked versions replace serial numbers, UDIDs and hardware addresses with placeholders.")
        }
        ToolbarItem {
            Button {
                log.clear()
                selection = nil
                statusMessage = nil
            } label: {
                Image(systemName: "trash")
            }
            .disabled(log.entries.isEmpty)
            .help("Clear the log")
        }
    }

    // MARK: Sharing

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied."
    }

    private func export(maskingIdentifiers: Bool) {
        exportDocument = PlainTextDocument(text: log.exportText(maskingIdentifiers: maskingIdentifiers))
        statusMessage = nil
        isExporting = true
    }

    /// One entry rendered on its own, for the copy button in the details pane.
    private func text(for entry: ActivityEntry) -> String {
        var lines = [
            entry.date.formatted(date: .abbreviated, time: .standard),
            "\(entry.kind.rawValue) · \(entry.service.rawValue)" + (entry.connection.map { " · \($0)" } ?? ""),
            entry.summary,
        ]
        if entry.status != nil { lines.append("Status: \(entry.statusText)") }
        if entry.duration != nil { lines.append("Took: \(entry.durationText)") }
        if let note = entry.bodyNote { lines.append(note) }
        if let body = entry.requestBody { lines += ["Request body:", body] }
        if let body = entry.responseBody { lines += ["Response body:", body] }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Search

extension ActivityEntry {
    /// Matches the query against everything shown for the entry, so searching a
    /// serial number finds the requests that mention it as well as the action.
    func matches(_ query: String) -> Bool {
        let haystack = [
            summary,
            connection,
            service.rawValue,
            kind.rawValue,
            status.map(String.init),
            requestBody,
            responseBody,
            bodyNote,
        ].compactMap { $0 }.joined(separator: "\n")
        return haystack.localizedCaseInsensitiveContains(query)
    }
}

// MARK: - Export document

/// Minimal plain-text document, used only to hand the exported log to
/// `fileExporter`.
nonisolated struct PlainTextDocument: FileDocument {
    static let readableContentTypes = [UTType.plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

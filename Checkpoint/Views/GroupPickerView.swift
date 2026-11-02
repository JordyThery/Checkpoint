import JTKit
import SwiftUI

/// Picks a Jamf group and hands back its serial numbers, so a group can be
/// used as the input to a lookup. On Jamf Pro, smart and static groups of
/// both device kinds are listed together; Jamf School keeps one list.
struct GroupPickerView: View {
    @Environment(LookupModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Called with the group's serial numbers once one is chosen.
    let onPick: (JamfGroup, [String]) -> Void

    @State private var groups: [JamfGroup] = []
    @State private var searchText = ""
    @State private var selection: JamfGroup.ID?
    @State private var isLoading = true
    @State private var isFetchingMembers = false
    @State private var errorMessage: String?

    private var visible: [JamfGroup] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return groups }
        return groups.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var selectedGroup: JamfGroup? {
        groups.first { $0.id == selection }
    }

    var body: some View {
        SheetFrame(title: "Look Up a \(model.mdmProduct.label) Group", systemImage: "rectangle.3.group",
                   isBusy: isFetchingMembers) {
            content
                .frame(minHeight: 260)
        } footer: {
                if let errorMessage {
                    WarningLabel(errorMessage)
                        .font(.callout)
                        .lineLimit(2)
                } else if !groups.isEmpty {
                    Text("\(visible.count) group\(visible.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Look Up Group") { pick() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedGroup == nil || isFetchingMembers)
        }
        .frame(width: 460, height: 420)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading groups…")
                .accessibilityLabel("Loading groups")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            ContentUnavailableView(
                "No Groups",
                systemImage: "rectangle.3.group",
                description: Text(model.mdmProduct == .jamfSchool
                                  ? "The selected Jamf School server has no device groups, or the API key can’t read them."
                                  : "The selected Jamf Pro server has no computer or mobile device groups, or the connection can’t read them.")

            )
        } else {
            // A field of its own: a sheet has no toolbar to hold a search field.
            VStack(spacing: 8) {
                PickerSearchField(prompt: "Search groups", text: $searchText)
                List(visible, selection: $selection) { group in
                HStack(spacing: 8) {
                    // Jamf School keeps one list of device groups rather than
                    // splitting them by kind, so there is no kind to show.
                    Image(systemName: groupIcon(group))
                        .foregroundStyle(.secondary)
                    Text(group.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(group.memberCount.map { "\(group.typeLabel) · \(LookupModel.deviceCount($0))" } ?? group.typeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(group.id)
            }
            // Double-clicking a group looks it up, as the default button does.
            .contextMenu(forSelectionType: JamfGroup.ID.self, menu: { _ in }) { ids in
                guard let id = ids.first, !isFetchingMembers else { return }
                selection = id
                pick()
            }
            }
        }
    }

    private func groupIcon(_ group: JamfGroup) -> String {
        switch group.kind {
        case .computer: "laptopcomputer"
        case .mobileDevice: "iphone"
        case nil: "rectangle.3.group"
        }
    }

    private func load() async {
        isLoading = true
        do {
            groups = try await model.jamfGroups()
        } catch {
            errorMessage = describe(error)
        }
        isLoading = false
    }

    private func pick() {
        guard let group = selectedGroup else { return }
        isFetchingMembers = true
        errorMessage = nil
        Task {
            do {
                let serials = try await model.serials(in: group)
                guard !serials.isEmpty else {
                    errorMessage = "\(group.name) has no members with a serial number."
                    isFetchingMembers = false
                    return
                }
                onPick(group, serials)
                dismiss()
            } catch {
                errorMessage = describe(error)
            }
            isFetchingMembers = false
        }
    }
}

/// The search field above a picker sheet's list.
struct PickerSearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel(prompt)
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Label("Clear Search", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        // Typing starts a search as soon as the sheet opens.
        .onAppear { isFocused = true }
    }
}

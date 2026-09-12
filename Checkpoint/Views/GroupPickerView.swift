import SwiftUI

/// Picks a Jamf Pro group and hands back its serial numbers, so a group can
/// be used as the input to a lookup. Smart and static groups of both device
/// kinds are listed together.
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
        VStack(spacing: 0) {
            HStack {
                Text("Look Up a Jamf Pro Group")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            content
                .frame(minHeight: 260)

            Divider()
            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if !groups.isEmpty {
                    Text("\(visible.count) group\(visible.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isFetchingMembers { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Look Up Group") { pick() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedGroup == nil || isFetchingMembers)
            }
            .padding(16)
        }
        .frame(width: 460, height: 420)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading groups…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            ContentUnavailableView(
                "No Groups",
                systemImage: "rectangle.3.group",
                description: Text("The selected Jamf Pro server has no computer or mobile device groups, or the connection cannot read them.")
            )
        } else {
            List(visible, selection: $selection) { group in
                HStack(spacing: 8) {
                    Image(systemName: group.kind == .computer ? "laptopcomputer" : "iphone")
                        .foregroundStyle(.secondary)
                    Text(group.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(group.typeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(group.id)
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search groups")
        }
    }

    private func load() async {
        isLoading = true
        do {
            groups = try await model.jamfGroups()
        } catch {
            errorMessage = error.localizedDescription
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
                errorMessage = error.localizedDescription
            }
            isFetchingMembers = false
        }
    }
}

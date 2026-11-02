import JTKit
import SwiftUI

/// Picks an Apple order and hands back the serial numbers on it. Both Apple
/// services report order numbers the same way, and with several
/// organizations in scope the orders of all of them are listed together.
///
/// Apple cannot filter devices by order, so the orders come from the same
/// organization snapshot a large lookup already reads. Once that has been
/// read, picking an order costs nothing.
struct OrderPickerView: View {
    @Environment(LookupModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let onPick: (String, [String]) -> Void

    @State private var orders: [(number: String, count: Int)] = []
    @State private var searchText = ""
    @State private var selection: String?
    @State private var isLoading = true
    /// The organizations to read before any order can be listed, asked
    /// about first, as a large lookup asks. Empty once they are in hand.
    @State private var awaitingConsent: [String] = []
    @State private var errorMessage: String?

    private var visible: [(number: String, count: Int)] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return orders }
        return orders.filter { $0.number.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        SheetFrame(title: "Look Up an \(model.abmKind.label) Order", systemImage: "shippingbox") {
            content
                .frame(minHeight: 260)
        } footer: {
                if let errorMessage {
                    WarningLabel(errorMessage)
                        .font(.callout)
                        .lineLimit(2)
                } else if !isLoading && !orders.isEmpty {
                    Text("\(visible.count) order\(visible.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    // The list is reused for the session, so it needs a way
                    // to pick up devices added to the organization meanwhile.
                    Button {
                        Task { await load(refresh: true) }
                    } label: {
                        Label("Read Again", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Read the organization again")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Look Up Order") { pick() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
        }
        .frame(width: 460, height: 420)
        .task {
            let unread = model.organizationsAwaitingRead.map(\.displayName)
            if unread.isEmpty {
                await load()
            } else {
                awaitingConsent = unread
                isLoading = false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !awaitingConsent.isEmpty {
            ContentUnavailableView {
                Label("Read the Organization First", systemImage: "shippingbox")
            } description: {
                Text("Apple can’t search devices by order number, so \(awaitingConsent.formatted(.list(type: .and))) \(awaitingConsent.count == 1 ? "is" : "are") read in full first. That takes about a minute each; later lookups reuse it.")
            } actions: {
                Button(awaitingConsent.count == 1 ? "Read Organization" : "Read Organizations") {
                    awaitingConsent = []
                    Task { await load() }
                }
            }
        } else if isLoading {
            VStack(spacing: 10) {
                ProgressView().accessibilityLabel("In progress")
                Text(model.snapshotStatus ?? "Reading the organization…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("This takes a minute or two. Apple can’t search devices by order number and limits how often it can be asked, so Checkpoint reads the organization once and reuses it until you change something or quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if orders.isEmpty {
            ContentUnavailableView(
                "No Orders",
                systemImage: "shippingbox",
                description: Text("No device in this \(model.abmKind.label) organization has an order number, or the organization couldn’t be read.")
            )
        } else {
            // A field of its own: a sheet has no toolbar to hold a search field.
            VStack(spacing: 8) {
                PickerSearchField(prompt: "Search orders", text: $searchText)
                List(visible, id: \.number, selection: $selection) { order in
                HStack {
                    Text(order.number)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(LookupModel.deviceCount(order.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(order.number)
            }
            // Double-clicking an order looks it up, as the default button does.
            .contextMenu(forSelectionType: String.self, menu: { _ in }) { numbers in
                guard let number = numbers.first else { return }
                selection = number
                pick()
            }
            }
        }
    }

    private func load(refresh: Bool = false) async {
        isLoading = true
        if refresh {
            selection = nil
            await model.refreshOrganizationsInScope()
        }
        orders = await model.abmOrders()
        isLoading = false
    }

    private func pick() {
        guard let number = selection else { return }
        Task {
            errorMessage = nil
            let serials = await model.serials(inOrder: number)
            guard !serials.isEmpty else {
                errorMessage = "Order \(number) has no devices with a serial number."
                return
            }
            onPick(number, serials)
            dismiss()
        }
    }
}

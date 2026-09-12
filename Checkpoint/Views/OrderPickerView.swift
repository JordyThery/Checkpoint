import SwiftUI

/// Picks an Apple Business order and hands back the serial numbers on it.
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

    private var visible: [(number: String, count: Int)] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return orders }
        return orders.filter { $0.number.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Look Up an Apple Business Order")
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
                if !isLoading && !orders.isEmpty {
                    Text("\(visible.count) order\(visible.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    // The list is reused for the session, so it needs a way
                    // to pick up devices added in Apple Business meanwhile.
                    Button {
                        Task { await load(refresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
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
            .padding(16)
        }
        .frame(width: 460, height: 420)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text(model.snapshotStatus ?? "Reading the organization…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("This takes a minute or two. Apple cannot search devices by order number and limits how often it can be asked, so Checkpoint reads the organization once and reuses it until you change something or quit.")
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
                description: Text("No device in this Apple Business organization has an order number, or the organization could not be read.")
            )
        } else {
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
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search orders")
        }
    }

    private func load(refresh: Bool = false) async {
        isLoading = true
        if refresh {
            selection = nil
            await model.organizationSnapshot(forceRefresh: true)
        }
        orders = await model.abmOrders()
        isLoading = false
    }

    private func pick() {
        guard let number = selection else { return }
        Task {
            let serials = await model.serials(inOrder: number)
            guard !serials.isEmpty else { return }
            onPick(number, serials)
            dismiss()
        }
    }
}

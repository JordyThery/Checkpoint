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
            VStack(spacing: 8) {
                ProgressView()
                Text(model.snapshotProgress > 0
                     ? "Reading the organization… \(model.snapshotProgress) devices"
                     : "Reading the organization…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Apple cannot search by order number, so Checkpoint reads the device list once and reuses it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
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

    private func load() async {
        isLoading = true
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

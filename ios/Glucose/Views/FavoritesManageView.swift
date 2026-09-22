import SwiftUI

/// Create and manage frequent meals (the one-tap chips in meal logging).
struct FavoritesManageView: View {
    @Environment(AppState.self) private var state

    @State private var name = ""
    @State private var carbs = ""
    @State private var fpu = 0.0
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var typing: Bool

    var body: some View {
        Form {
            Section("New favorite") {
                TextField("Name (e.g. Oats + milk)", text: $name)
                    .focused($typing)
                HStack {
                    TextField("carbs (g)", text: $carbs)
                        .keyboardType(.decimalPad)
                        .focused($typing)
                    Text("g carbs").foregroundStyle(.secondary)
                }
                Stepper(value: $fpu, in: 0...10, step: 0.5) {
                    Text(verbatim: String(format: "%.1f FPU", fpu)).monospacedDigit()
                }
                Button(saving ? "…" : "Add") { Task { await add() } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || parseDecimal(carbs) == nil || saving)
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }

            Section("Your favorites") {
                if state.favorites.isEmpty {
                    Text("You have no favorites yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.favorites) { fav in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fav.name)
                            Text(String(localized: "\(Int(fav.carbsG)) g carbs") +
                                 (fav.fpu > 0 ? String(format: " · %.1f FPU", fav.fpu) : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("used \(fav.useCount)×")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    Task { await delete(offsets) }
                }
            }
        }
        .navigationTitle("Frequent meals")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { typing = false }
            }
        }
    }

    private func add() async {
        guard let c = parseDecimal(carbs) else { return }
        saving = true
        errorMessage = nil
        do {
            try await APIClient.addFavorite(
                name: name.trimmingCharacters(in: .whitespaces), carbs: c, fpu: fpu
            )
            await state.refresh()
            name = ""
            carbs = ""
            fpu = 0
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }

    private func delete(_ offsets: IndexSet) async {
        for index in offsets {
            let fav = state.favorites[index]
            try? await APIClient.deleteFavorite(id: fav.id)
        }
        await state.refresh()
    }
}

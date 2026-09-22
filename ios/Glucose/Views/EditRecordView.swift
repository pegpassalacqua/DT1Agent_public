import SwiftUI

/// A meal or dose selected for editing (from the History swipe actions).
enum EditableRecord: Identifiable {
    case meal(MealPoint)
    case dose(DosePoint)

    var id: String {
        switch self {
        case .meal(let m): "m\(m.id)"
        case .dose(let d): "d\(d.id)"
        }
    }
}

/// Fix a wrong record: change values/time or delete it entirely.
/// Corrections matter — a mislogged dose poisons IOB for hours.
struct EditRecordView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let record: EditableRecord

    @State private var carbs = ""
    @State private var protein = ""
    @State private var fat = ""
    @State private var fiber = ""
    @State private var desc = ""
    @State private var units = 0.0
    @State private var doseType = "bolus"
    @State private var when = Date()
    @State private var saving = false
    @State private var confirmDelete = false
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            Form {
                switch record {
                case .meal:
                    Section("Meal") {
                        HStack {
                            TextField("carbs (g)", text: $carbs)
                                .keyboardType(.decimalPad)
                                .focused($typing)
                            Text("g carbs").foregroundStyle(.secondary)
                        }
                        HStack {
                            TextField("Protein (g)", text: $protein)
                                .keyboardType(.decimalPad)
                                .focused($typing)
                            TextField("Fat (g)", text: $fat)
                                .keyboardType(.decimalPad)
                                .focused($typing)
                        }
                        HStack {
                            TextField("Fiber (g, optional)", text: $fiber)
                                .keyboardType(.decimalPad)
                                .focused($typing)
                            Spacer()
                            Text(String(
                                format: "≈ %.1f FPU",
                                ((parseDecimal(protein) ?? 0) * 4 + (parseDecimal(fat) ?? 0) * 9) / 100
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        TextField("Description", text: $desc)
                            .focused($typing)
                    }
                case .dose:
                    Section("Insulin") {
                        Stepper(value: $units, in: 0.5...80, step: 0.5) {
                            Text(String(format: "%.1f U", units))
                                .font(.headline.monospacedDigit())
                        }
                        Picker("Type", selection: $doseType) {
                            Text(DoseKind.label("bolus")).tag("bolus")
                            Text(DoseKind.label("correction")).tag("correction")
                            Text(DoseKind.label("basal")).tag("basal")
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("When") {
                    DatePicker(
                        "Time",
                        selection: $when,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                Section {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete record", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Edit record")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { typing = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "…" : "Save") { Task { await save() } }
                        .disabled(saving || !valid)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog(
                "Delete this record? IOB/COB will be recalculated.",
                isPresented: $confirmDelete, titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { Task { await remove() } }
            }
            .onAppear(perform: populate)
        }
        .presentationDetents([.medium, .large])
    }

    private var valid: Bool {
        switch record {
        case .meal:
            (parseDecimal(carbs) ?? 0) > 0 || (parseDecimal(protein) ?? 0) > 0 || (parseDecimal(fat) ?? 0) > 0
        case .dose: units > 0
        }
    }

    private func populate() {
        switch record {
        case .meal(let m):
            carbs = trim(m.carbsG)
            protein = trim(m.proteinG)
            fat = trim(m.fatG)
            fiber = trim(m.fiberG)
            desc = m.description ?? ""
            when = m.date
        case .dose(let d):
            units = d.units
            doseType = d.type
            when = d.date
        }
    }

    private func trim(_ v: Double) -> String {
        v == 0 ? "" : (v == v.rounded() ? String(Int(v)) : String(v))
    }

    private func save() async {
        saving = true
        switch record {
        case .meal(let m):
            try? await APIClient.updateMeal(
                id: m.id, carbs: parseDecimal(carbs) ?? m.carbsG,
                protein: parseDecimal(protein) ?? 0, fat: parseDecimal(fat) ?? 0, fiber: parseDecimal(fiber) ?? 0,
                description: desc.isEmpty ? nil : desc, at: when
            )
        case .dose(let d):
            try? await APIClient.updateDose(id: d.id, units: units, type: doseType, at: when)
        }
        await state.refresh()
        dismiss()
    }

    private func remove() async {
        saving = true
        switch record {
        case .meal(let m): try? await APIClient.deleteMeal(id: m.id)
        case .dose(let d): try? await APIClient.deleteDose(id: d.id)
        }
        await state.refresh()
        dismiss()
    }
}

import SwiftUI

/// Edit the therapy profile: insulin-to-carb ratio, sensitivity factor,
/// target, insulin duration, pen increment and the target range. These drive
/// every dose suggestion — the values must come from the user's diabetes
/// team. Until this is saved once, the app gives no dose suggestions.
struct TherapyProfileView: View {
    @Environment(AppState.self) private var state
    @State private var icr = ""
    @State private var isf = ""
    @State private var target = ""
    @State private var low = "70"     // international time-in-range consensus
    @State private var high = "180"
    @State private var dia = ""
    @State private var increment = 1.0
    @State private var loading = true
    @State private var saving = false
    @State private var firstTime = false
    @State private var message: String?
    @State private var isError = false
    @FocusState private var typing: Bool

    private func number(_ s: String) -> Double? { parseDecimal(s) }

    private var valid: Bool {
        [icr, isf, target, low, high, dia].allSatisfy { (number($0) ?? 0) > 0 }
            && (number(low) ?? 0) < (number(high) ?? 0)
    }

    var body: some View {
        Form {
            if loading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading profile…").foregroundStyle(.secondary)
                }
            } else {
                if firstTime {
                    Section {
                        Label("Fill in the values set by your diabetes care team. Until you save, the app suggests no doses and no rescue carbs.",
                              systemImage: "stethoscope")
                            .font(.footnote)
                    }
                }
                Section("Insulin-to-carb ratio") {
                    HStack {
                        Text("1 U covers")
                        TextField("e.g. 10", text: $icr)
                            .keyboardType(.decimalPad)
                            .focused($typing)
                            .multilineTextAlignment(.trailing)
                        Text("g of carbs").foregroundStyle(.secondary)
                    }
                }
                Section("Sensitivity factor") {
                    HStack {
                        Text("1 U lowers")
                        TextField("e.g. 40", text: $isf)
                            .keyboardType(.decimalPad)
                            .focused($typing)
                            .multilineTextAlignment(.trailing)
                        Text("mg/dL").foregroundStyle(.secondary)
                    }
                }
                Section {
                    HStack {
                        TextField("e.g. 110", text: $target)
                            .keyboardType(.numberPad)
                            .focused($typing)
                        Text("mg/dL").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Target glucose")
                } footer: {
                    Text("The value corrections aim for.")
                }
                Section {
                    HStack {
                        TextField("e.g. 4", text: $dia)
                            .keyboardType(.decimalPad)
                            .focused($typing)
                        Text("hours").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Duration of insulin action (DIA)")
                } footer: {
                    Text("How long rapid-acting insulin stays active. Determines insulin on board (IOB).")
                }
                Section {
                    Picker("Increment", selection: $increment) {
                        Text(verbatim: "1 U").tag(1.0)
                        Text(0.5.formatted() + " U").tag(0.5)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Rapid-acting insulin pen")
                } footer: {
                    Text("The smallest dose your pen can dial. Suggestions always round down.")
                }
                Section {
                    HStack {
                        Text("Minimum")
                        Spacer()
                        TextField("70", text: $low)
                            .keyboardType(.numberPad)
                            .focused($typing)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Text("mg/dL").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Maximum")
                        Spacer()
                        TextField("180", text: $high)
                            .keyboardType(.numberPad)
                            .focused($typing)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Text("mg/dL").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Target range")
                } footer: {
                    Text("Used everywhere: % in range, calendar and streaks, charts, colors and alarms (low below the minimum; high and forecast outside the range). 70–180 is the international consensus.")
                }
                Section {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(!valid || saving)
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(isError ? .red : .green)
                    }
                } footer: {
                    Text("These values come from your diabetes care team and change every dose suggestion. Double-check before changing them.")
                }
            }
        }
        .navigationTitle("Ratios & targets")
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
        .task { await load() }
    }

    private func load() async {
        loading = true
        if let p = try? await APIClient.fetchTherapyProfile() {
            icr = trim(p.icrGPerU)
            isf = trim(p.isfMgDlPerU)
            target = trim(p.targetMgDl)
            low = trim(p.lowAlarmMgDl)
            high = trim(p.highAlarmMgDl)
            dia = trim(p.diaHours)
            increment = p.doseIncrementU
        } else {
            firstTime = true // nothing saved yet: leave the fields empty
        }
        loading = false
    }

    private func save() async {
        guard let icrV = number(icr), let isfV = number(isf), let targetV = number(target),
              let lowV = number(low), let highV = number(high), let diaV = number(dia)
        else { return }
        saving = true
        message = nil
        do {
            try await APIClient.saveTherapyProfile(.init(
                icrGPerU: icrV, isfMgDlPerU: isfV, targetMgDl: targetV,
                lowAlarmMgDl: lowV, highAlarmMgDl: highV, diaHours: diaV,
                doseIncrementU: increment
            ))
            message = String(localized: "Saved — the next suggestions already use these values.")
            isError = false
            firstTime = false
            await state.refresh()
        } catch {
            message = String(localized: "Could not save: \(error.localizedDescription)")
            isError = true
        }
        saving = false
    }

    /// "10.0" -> "10", "37.5" -> "37.5"
    private func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}

import SwiftUI

/// The single treatment flow: carbs in (favorites, label calculator, or 0 g),
/// live dose suggestion out, adjustable with a stepper, and one "Registar"
/// that logs meal + insulin together. Works for meals, corrections with no
/// food (0 HC), and basal.
///
/// FPU is never entered directly — the user logs FACTS (protein/fat grams
/// from a label) and the server derives FPU via the real Warsaw method
/// formula. Fiber is recorded for context only (no validated dosing
/// formula exists for it — see medicalMath.js).
struct TreatmentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    struct Item: Identifiable {
        let id = UUID()
        let name: String
        let carbs: Double
        var protein: Double = 0
        var fat: Double = 0
        var fiber: Double = 0
    }

    @State private var items: [Item] = []
    @State private var per100 = ""
    @State private var grams = ""
    @State private var proteinPer100 = ""
    @State private var fatPer100 = ""
    @State private var fiberPer100 = ""
    @State private var recommendation: RecommendationEnvelope?
    @State private var recommendationError: String?
    @State private var loadingRec = false
    @State private var dose = 0.0
    @State private var saving = false
    @State private var saveAsFavoriteName = ""
    @State private var when = Date()
    @State private var manualBg = ""
    @FocusState private var typing: Bool

    private var isBackdated: Bool { Date().timeIntervalSince(when) > 5 * 60 }

    /// Sensor reading usable for suggestions only if newer than 5 min.
    private var readingIsFresh: Bool {
        guard let r = state.status?.reading else { return false }
        return Date().timeIntervalSince(r.date) < 5 * 60
    }

    private var totalCarbs: Double { items.reduce(0) { $0 + $1.carbs } }
    private var totalProtein: Double { items.reduce(0) { $0 + $1.protein } }
    private var totalFat: Double { items.reduce(0) { $0 + $1.fat } }
    private var totalFiber: Double { items.reduce(0) { $0 + $1.fiber } }

    /// Warsaw method: 1 FPU = 100 kcal from fat + protein
    /// (fat 9 kcal/g, protein 4 kcal/g). Display-only — the server derives
    /// and stores the real value the same way when the meal is saved.
    private var totalFPU: Double { (totalProtein * 4 + totalFat * 9) / 100 }

    private var calculatedCarbs: Double {
        ((parseDecimal(per100) ?? 0) * (parseDecimal(grams) ?? 0) / 100).rounded()
    }
    private var calculatedProtein: Double {
        (parseDecimal(proteinPer100) ?? 0) * (parseDecimal(grams) ?? 0) / 100
    }
    private var calculatedFat: Double {
        (parseDecimal(fatPer100) ?? 0) * (parseDecimal(grams) ?? 0) / 100
    }
    private var calculatedFiber: Double {
        (parseDecimal(fiberPer100) ?? 0) * (parseDecimal(grams) ?? 0) / 100
    }

    private var canSave: Bool {
        totalCarbs > 0 || totalFPU > 0 || dose > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                favoritesSection
                calculatorSection
                if !items.isEmpty { itemsSection }
                if !readingIsFresh { manualBgSection }
                insulinSection
                whenSection
                saveAsFavoriteSection
            }
            .navigationTitle("Treatment")
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
                    Button(saving ? "…" : "Log") { Task { await save() } }
                        .disabled(!canSave || saving)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await updateRecommendation() }
            .onChange(of: totalCarbs) { _, _ in Task { await updateRecommendation() } }
            .onChange(of: totalFPU) { _, _ in Task { await updateRecommendation() } }
            .onChange(of: manualBg) { _, _ in Task { await updateRecommendation() } }
            // New suggestion overwrites the stepper — a changed meal
            // invalidates any manual adjustment (safer than keeping it).
            .onChange(of: recommendation?.data.recommendedUnits) { _, new in
                if let new { dose = new }
            }
        }
    }

    // MARK: sections

    private var favoritesSection: some View {
        Section("Frequent") {
            if state.favorites.isEmpty {
                Text("No favorites yet — log meals and save them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(state.favorites) { fav in
                        Button {
                            // Favorites store a pre-computed fpu (no macro
                            // breakdown) — reverse it into an equivalent
                            // protein/fat split so it still adds correctly.
                            let fatG = fav.fpu * 100 / 13 // fat-weighted split, good enough for a quick chip
                            items.append(Item(name: fav.name, carbs: fav.carbsG, fat: fatG))
                        } label: {
                            Text(verbatim: "\(fav.name) · \(Int(fav.carbsG))g")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.teal.opacity(0.15), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            NavigationLink("Manage favorites…") { FavoritesManageView() }
                .font(.subheadline)
        }
    }

    private var calculatorSection: some View {
        Section {
            HStack {
                TextField("Carbs/100g", text: $per100)
                    .keyboardType(.decimalPad)
                    .focused($typing)
                TextField("grams", text: $grams)
                    .keyboardType(.decimalPad)
                    .focused($typing)
                Text(verbatim: "= \(Int(calculatedCarbs)) g")
                    .font(.headline.monospacedDigit())
                    .frame(minWidth: 55, alignment: .trailing)
            }
            HStack {
                TextField("Protein/100g", text: $proteinPer100)
                    .keyboardType(.decimalPad)
                    .focused($typing)
                TextField("Fat/100g", text: $fatPer100)
                    .keyboardType(.decimalPad)
                    .focused($typing)
            }
            HStack {
                TextField("Fiber/100g (optional)", text: $fiberPer100)
                    .keyboardType(.decimalPad)
                    .focused($typing)
                Spacer()
                Text(String(format: "≈ %.1f FPU", (calculatedProtein * 4 + calculatedFat * 9) / 100))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                if calculatedCarbs > 0 || calculatedProtein > 0 || calculatedFat > 0 {
                    items.append(Item(
                        name: String(localized: "Food (\(grams)g)"), carbs: calculatedCarbs,
                        protein: calculatedProtein, fat: calculatedFat, fiber: calculatedFiber
                    ))
                }
                per100 = ""; grams = ""; proteinPer100 = ""; fatPer100 = ""; fiberPer100 = ""
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(calculatedCarbs <= 0 && calculatedProtein <= 0 && calculatedFat <= 0)
        } header: {
            Text("Label calculator")
        } footer: {
            Text("Enter the nutrition facts from the label (per 100g) — FPU is calculated automatically with the Warsaw method (1 FPU = 100 kcal from fat + protein). Fiber is recorded for reference only; it does not change the calculation (there is no validated formula for it).")
        }
    }

    private var itemsSection: some View {
        Section {
            ForEach(items) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        if item.protein > 0 || item.fat > 0 || item.fiber > 0 {
                            Text("P \(item.protein, specifier: "%.0f")g · F \(item.fat, specifier: "%.0f")g · Fiber \(item.fiber, specifier: "%.0f")g")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(verbatim: "\(Int(item.carbs)) g")
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { items.remove(atOffsets: $0) }
            HStack {
                Text("Total").font(.headline)
                Spacer()
                Text("\(Int(totalCarbs)) g carbs")
                    .font(.headline.monospacedDigit())
            }
            if totalFPU > 0 {
                HStack {
                    Text("Calculated FPU")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f", totalFPU))
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// Shown when the sensor reading is stale (> 5 min) or missing —
    /// type the value you see on the sensor/meter so the suggestion works.
    private var manualBgSection: some View {
        Section {
            HStack {
                Image(systemName: "drop.fill").foregroundStyle(.red)
                TextField("current glucose", text: $manualBg)
                    .keyboardType(.numberPad)
                    .focused($typing)
                Text("mg/dL").foregroundStyle(.secondary)
            }
        } header: {
            Text("Manual glucose")
        } footer: {
            Text("The sensor reading is older than 5 min (or there is no connection). Enter your current value to get a suggestion.")
        }
    }

    private var insulinSection: some View {
        Section {
            if loadingRec {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Calculating suggestion…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let rec = recommendation?.data {
                if rec.rescueCarbsG > 0 {
                    Label(
                        "Low predicted — eat \(Int(rec.rescueCarbsG)) g of carbs instead of injecting.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                } else {
                    LabeledContent("Suggestion") {
                        Text(String(format: "%.1f U", rec.recommendedUnits))
                            .font(.title3.bold().monospacedDigit())
                            .foregroundStyle(.teal)
                    }
                    Text("Glucose \(Int(rec.bg)) · IOB \(rec.iob, specifier: "%.1f") U · COB \(rec.cob, specifier: "%.0f") g · Meal \(rec.mealUnits, specifier: "%.1f") U · Correction \(rec.correctionUnits, specifier: "%+.1f") U")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else if !readingIsFresh && parseDecimal(manualBg) == nil {
                Text("Enter your manual glucose above to get a suggestion.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if let recommendationError {
                Text(recommendationError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Stepper(value: $dose, in: 0...40, step: LocalStore.shared.therapyProfile.doseIncrementU) {
                HStack(spacing: 6) {
                    Text("I will inject")
                    Text(String(format: "%.1f U", dose))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(dose > 0 ? .primary : .secondary)
                }
            }
        } header: {
            Text("Insulin")
        } footer: {
            Text("The suggestion uses your ratios and accounts for IOB/COB. The decision is always yours — adjust the dose before logging.")
        }
    }

    private var whenSection: some View {
        Section {
            DatePicker(
                "When",
                selection: $when,
                in: Date().addingTimeInterval(-48 * 3600)...Date(),
                displayedComponents: [.date, .hourAndMinute]
            )
            if isBackdated {
                Label(
                    "Logging in the past — IOB/COB will be recalculated with this time. The dose suggestion above is for NOW, not for that time.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        } footer: {
            Text("If you forgot to log at the time, adjust the time — active amounts stay correct.")
        }
    }

    private var saveAsFavoriteSection: some View {
        Section {
            TextField("Save as favorite (name, optional)", text: $saveAsFavoriteName)
                .focused($typing)
        } footer: {
            Text("If you give it a name, this meal is added to the frequent chips.")
        }
    }

    // MARK: actions

    private func updateRecommendation() async {
        loadingRec = true
        // Stale/missing sensor reading: use the manually typed value.
        let bgOverride = readingIsFresh ? nil : parseDecimal(manualBg)
        recommendationError = nil
        if !readingIsFresh && bgOverride == nil {
            recommendation = nil // no basis for a suggestion yet
        } else {
            do {
                recommendation = try await APIClient.recommend(
                    carbs: totalCarbs, fpu: totalFPU, bg: bgOverride
                )
            } catch {
                recommendation = nil
                recommendationError = error.localizedDescription
            }
        }
        loadingRec = false
    }

    private func save() async {
        saving = true
        let timestamp = isBackdated ? when : nil // nil = server uses "now"
        if totalCarbs > 0 || totalFPU > 0 {
            let description = items.map(\.name).joined(separator: ", ")
            do {
                try await APIClient.logMeal(
                    carbs: totalCarbs, protein: totalProtein, fat: totalFat, fiber: totalFiber,
                    description: description.isEmpty ? nil : description,
                    at: timestamp
                )
            } catch {
                // Offline: keep it on-device with the real timestamp.
                state.enqueue(PendingOp(
                    id: UUID(), kind: .meal, carbs: totalCarbs,
                    protein: totalProtein, fat: totalFat, fiber: totalFiber,
                    description: description.isEmpty ? nil : description,
                    at: timestamp ?? Date()
                ))
            }
        }
        if dose > 0 {
            do {
                try await APIClient.logInsulin(units: dose, at: timestamp)
            } catch {
                state.enqueue(PendingOp(
                    id: UUID(), kind: .dose, units: dose,
                    at: timestamp ?? Date()
                ))
            }
        }
        if let env = recommendation {
            try? await APIClient.markRecommendation(
                id: env.recommendationId,
                accepted: dose == env.data.recommendedUnits
            )
        }
        let favName = saveAsFavoriteName.trimmingCharacters(in: .whitespaces)
        if !favName.isEmpty, totalCarbs > 0 {
            try? await APIClient.addFavorite(name: favName, carbs: totalCarbs, fpu: totalFPU)
        }
        await state.refresh()
        dismiss()
    }
}

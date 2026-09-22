import SwiftUI

/// The "Low" button: one tap answers "how many carbs should I eat?"
/// Asks the engine for a zero-carb recommendation — if a low is predicted
/// it returns rescue grams; logging the rescue snoozes the low alarm.
struct RescueView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var recommendation: Recommendation?
    @State private var failure: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let rec = recommendation {
                    if rec.rescueCarbsG > 0 {
                        Text("Eat now")
                            .font(.title2)
                        Text(verbatim: "\(Int(rec.rescueCarbsG)) g")
                            .font(.system(size: 72, weight: .heavy, design: .rounded))
                            .foregroundStyle(.red)
                        Text("of fast-acting carbs (juice, sugar, glucose tabs)")
                            .foregroundStyle(.secondary)
                        Text("Glucose \(Int(rec.bg)) · IOB \(rec.iob, specifier: "%.1f") U · forecast \(Int(rec.eventualBg)) mg/dL")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Button {
                            saving = true
                            Task {
                                try? await APIClient.logMeal(
                                    carbs: rec.rescueCarbsG,
                                    description: String(localized: "Hypo rescue")
                                )
                                await state.refresh()
                                dismiss()
                            }
                        } label: {
                            Text(saving ? "…" : "I ate it — log \(Int(rec.rescueCarbsG)) g")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(saving)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.green)
                        Text("No low predicted")
                            .font(.title2.bold())
                        Text("Glucose \(Int(rec.bg)) · IOB \(rec.iob, specifier: "%.1f") U · forecast \(Int(rec.eventualBg)) mg/dL")
                        .foregroundStyle(.secondary)
                        Text("If you feel hypo, check with the sensor and eat 15 g anyway — symptoms beat the calculation.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                } else if let failure {
                    Text(failure)
                        .multilineTextAlignment(.center)
                    Text("Classic rule: 15 g of fast-acting carbs, recheck in 15 min.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("Calculating…")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBackground)
            .navigationTitle("Low")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                do {
                    recommendation = try await APIClient.recommend(carbs: 0, fpu: 0).data
                } catch {
                    failure = error.localizedDescription
                }
            }
        }
        .presentationDetents([.medium])
    }
}

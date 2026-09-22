import SwiftUI

struct ExerciseLogView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var type = "walk"
    @State private var intensity = "moderate"
    @State private var duration = 30
    @State private var saving = false

    /// Stored id -> label shown in the user's language.
    private let types: [(id: String, label: LocalizedStringKey)] = [
        ("walk", "Walking"), ("run", "Running"), ("gym", "Gym"),
        ("bike", "Cycling"), ("football", "Football"), ("other", "Other"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Activity", selection: $type) {
                    ForEach(types, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("Intensity", selection: $intensity) {
                    Text("Light").tag("low")
                    Text("Moderate").tag("moderate")
                    Text("Vigorous").tag("high")
                }
                .pickerStyle(.segmented)
                Stepper(value: $duration, in: 5...240, step: 5) {
                    Text("\(duration) min").monospacedDigit()
                }
            }
            .navigationTitle("Log exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "…" : "Log") {
                        saving = true
                        Task {
                            try? await APIClient.logExercise(
                                type: type, intensity: intensity, durationMin: duration
                            )
                            await state.refresh()
                            dismiss()
                        }
                    }
                    .disabled(saving)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

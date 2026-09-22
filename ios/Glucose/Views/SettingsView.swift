import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state

    @AppStorage("tirGoalPct") private var goalPct = 70.0
    @AppStorage("basalUnits") private var basalUnits = 0.0 // 0 = reminder off
    @State private var lluEmail = Keychain.get("lluEmail") ?? ""
    @State private var lluPassword = Keychain.get("lluPassword") ?? ""
    @State private var testResult: Result<Void, Error>?
    @State private var testing = false
    @State private var backfilling = false
    @State private var backfillSummary: String?
    @State private var backfillError: String?
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("LibreLinkUp") {
                    TextField("email", text: $lluEmail)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .focused($typing)
                        .onChange(of: lluEmail) { _, new in
                            Keychain.set(new, key: "lluEmail")
                            Task { await PollingService.shared.resetSession() }
                        }
                    SecureField("password", text: $lluPassword)
                        // Otherwise iOS capitalizes the first letter — and
                        // with the input hidden behind dots, you never see it.
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($typing)
                        .onChange(of: lluPassword) { _, new in
                            Keychain.set(new, key: "lluPassword")
                            Task { await PollingService.shared.resetSession() }
                        }
                    Button("Test connection") {
                        testResult = nil
                        testing = true
                        Task {
                            testResult = await APIClient.testConnection(urlString: "")
                            testing = false
                            await state.refresh() // the test itself already pulled live data — show it now
                        }
                    }
                    .disabled(testing)
                    if let testResult {
                        switch testResult {
                        case .success:
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let error):
                            Label(error.localizedDescription, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    Text("Your LibreLinkUp follower account (not the sensor app account) — see the README. The app connects directly, with no server; the password stays only in this iPhone's Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button(backfilling ? "Fetching…" : "Fetch last 14 days from LibreLinkUp") {
                        backfilling = true
                        backfillError = nil
                        backfillSummary = nil
                        Task {
                            defer { backfilling = false }
                            do {
                                let n = try await PollingService.shared.backfillLogbook()
                                backfillSummary = String(localized: "\(n) new readings added.")
                                await state.refresh()
                            } catch {
                                backfillError = error.localizedDescription
                            }
                        }
                    }
                    .disabled(backfilling)
                    if let backfillSummary { Text(backfillSummary).font(.footnote).foregroundStyle(.secondary) }
                    if let backfillError { Label(backfillError, systemImage: "xmark.circle.fill").foregroundStyle(.red) }
                    Text("Fills recent gaps (up to 14 days) — only readings tied to events/alarms, not the full continuous trace.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Meals") {
                    NavigationLink("Manage frequent meals") { FavoritesManageView() }
                }

                Section("Therapy profile") {
                    NavigationLink("Ratios & targets") { TherapyProfileView() }
                }

                Section("Daily basal") {
                    Stepper(value: $basalUnits, in: 0...80, step: 0.5) {
                        Group {
                            if basalUnits == 0 {
                                Text("Reminder off")
                            } else {
                                Text("\(basalUnits, specifier: "%.1f") U in the morning")
                            }
                        }
                        .monospacedDigit()
                    }
                    Text("With a dose set, every day from 05:00 a reminder shows on Home until you confirm it. Confirming logs the dose. Leave it at 0 to turn it off.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Time-in-range goal") {
                    Stepper(value: $goalPct, in: 40...95, step: 5) {
                        Text("In range at least \(Int(goalPct))%")
                            .monospacedDigit()
                    }
                    Text("Used by the Progress calendar and streak — changing it here recalculates everything instantly.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("This app suggests doses based on your ratios — it does not replace clinical judgment. Validate your regimen with your diabetes care team.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { typing = false }
                }
            }
            .onChange(of: lluEmail) { _, _ in Task { await state.refresh() } }
        }
    }
}

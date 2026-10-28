import SwiftUI

/// Your area, for Live TV's Local channels: from the iPhone's approximate
/// location (asked once, kept on the device), or a state and optional city.
struct AreaPicker: View {
    @Environment(Preferences.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var city = ""
    @State private var locating = false
    @State private var locateFailed = false

    var body: some View {
        List {
            #if os(iOS)
            Section {
                Button {
                    Task { await useLocation() }
                } label: {
                    Label(locating ? "Finding your area…" : "Use my location", systemImage: "location.fill")
                }
                .disabled(locating)
            } footer: {
                Text(locateFailed
                     ? "Couldn't tell where you are (location may be off for Zapline in Settings). Pick your state below."
                     : "Asks for your approximate location once. It's only used to pick your local channels and stays on this iPhone.")
            }
            #endif
            if let area = prefs.area {
                Section {
                    TextField("City (optional)", text: $city)
                        .onSubmit { prefs.area = LocalArea(state: area.state, city: city.isEmpty ? nil : city) }
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                } header: {
                    Text("City")
                } footer: {
                    Text("Stations from your city come first.")
                }
            }
            Section("State") {
                ForEach(LocalArea.states.sorted { $0.value < $1.value }, id: \.key) { code, name in
                    Button {
                        prefs.area = LocalArea(state: code, city: prefs.area?.state == code ? prefs.area?.city : nil)
                        city = prefs.area?.city ?? ""
                    } label: {
                        HStack {
                            Text(name).rowForeground()
                            Spacer()
                            if prefs.area?.state == code { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            }
            if prefs.area != nil {
                Section {
                    Button("Clear area", role: .destructive) {
                        prefs.area = nil
                        city = ""
                    }
                }
            }
        }
        .navigationTitle("Your area")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if let area = prefs.area { prefs.area = LocalArea(state: area.state, city: city.isEmpty ? nil : city) }
                    dismiss()
                }
            }
        }
        .onAppear { city = prefs.area?.city ?? "" }
    }

    #if os(iOS)
    private func useLocation() async {
        locating = true
        defer { locating = false }
        if let area = await AreaLocator().locate() {
            prefs.area = area
            city = area.city ?? ""
            locateFailed = false
        } else {
            locateFailed = true
        }
    }
    #endif
}

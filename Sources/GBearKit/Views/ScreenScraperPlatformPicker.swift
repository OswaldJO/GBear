import SwiftUI

/// ScreenScraper console picker for creating and editing emulator profiles.
struct ScreenScraperPlatformPicker: View {
    @Binding var selection: Int?

    private let unsetSentinel = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Platform", selection: platformBinding) {
                Text("Not set").tag(unsetSentinel)
                ForEach(ScreenScraperPlatformMap.selectableSystems, id: \.id) { system in
                    Text(system.name).tag(system.id)
                }
            }
            Text("Used when searching ScreenScraper for covers. Manual search opens with this console selected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var platformBinding: Binding<Int> {
        Binding(
            get: { selection ?? unsetSentinel },
            set: { newValue in
                selection = newValue == unsetSentinel ? nil : newValue
            }
        )
    }
}

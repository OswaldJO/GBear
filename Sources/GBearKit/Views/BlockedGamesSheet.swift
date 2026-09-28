import SwiftUI

/// Games removed from the library that Scan Paths skips. Unblocking lets the next scan add them again.
struct BlockedGamesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [LibraryBlocklist.Entry] = []
    @State private var confirmUnblockAll = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: entries.isEmpty ? "checkmark.circle" : "hand.raised.fill")
                            .font(.title2)
                            .foregroundStyle(entries.isEmpty ? Color.secondary : Color.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entries.isEmpty ? "No blocked games" : "\(entries.count) blocked game\(entries.count == 1 ? "" : "s")")
                                .font(.headline)
                            Text("Scan Paths skips these files.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section {
                    Text(
                        "Games you remove with Remove from Library are added here so Scan Paths does not bring them back. " +
                            "Unblock a game and it returns on the next Scan Paths (if the file is still in a Paths folder). " +
                            "Clear All Games and the other Clear actions do not block anything."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if !entries.isEmpty {
                    Section("Removed from library") {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Blocked Games")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Unblock All") { confirmUnblockAll = true }
                        .disabled(entries.isEmpty)
                }
            }
            .confirmationDialog(
                "Unblock every game?",
                isPresented: $confirmUnblockAll,
                titleVisibility: .visible
            ) {
                Button("Unblock All") {
                    LibraryBlocklist.removeAll()
                    reload()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The next Scan Paths adds these games back if their files are still in your Paths folders.")
            }
        }
        .frame(minWidth: 480, minHeight: 380)
        .onAppear(perform: reload)
    }

    private func row(_ entry: LibraryBlocklist.Entry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.body.weight(.medium))
                Text(detailLine(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.path)
            }
            Spacer(minLength: 8)
            Button("Unblock") {
                LibraryBlocklist.remove(key: entry.key)
                reload()
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    private func detailLine(_ entry: LibraryBlocklist.Entry) -> String {
        let removed = "Removed \(entry.removedAt.formatted(date: .abbreviated, time: .omitted))"
        guard let source = entry.sourceName, !source.isEmpty else { return removed }
        return "\(source) · \(removed)"
    }

    private func reload() {
        entries = LibraryBlocklist.entries.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

#Preview {
    BlockedGamesSheet()
}

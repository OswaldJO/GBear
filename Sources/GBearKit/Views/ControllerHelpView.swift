import SwiftUI

/// Help → Controller Navigation: every controller control as a table per area. Keep in sync with
/// `LibraryControllerNavigator`, `ControllerPageNavigator` and `OnScreenKeyboard`.
public struct ControllerHelpView: View {
    private struct Section: Identifiable {
        let title: String
        var rows: [(button: String, action: String)] = []
        var note: String?
        var id: String { title }
    }

    private static let sections: [Section] = [
        Section(
            title: "Getting started",
            note: "Connect any Bluetooth or USB controller. Buttons use PlayStation names with Xbox in brackets: Cross (A), Circle (B), Square (X), Triangle (Y), Select (Share / Create / View), Start (Options / Menu). GBear only responds while it's the app in front with no dialog or folder picker open, and not while this Mac is streaming a game. After switching back to GBear, let go of every button first."
        ),
        Section(title: "Anywhere in GBear", rows: [
            ("L2 / R2", "Move between areas in a loop: sidebar, covers, Info column (while open), toolbar. On Emulators, Paths and Streaming: the page and the toolbar."),
            ("L1 / R1", "Previous / next game"),
            ("Select", "Open / close the Info column (when you let go)"),
            ("Start", "Play the selected game right away"),
            ("Square / Circle", "Smaller / bigger covers"),
            ("L3", "Collapse / expand the sidebar"),
        ], note: "The focused item has an outline."),
        Section(title: "Covers", rows: [
            ("D-pad / left stick", "Move between covers (hold to repeat)"),
            ("Cross", "Show Play / Info; press again to play"),
            ("Triangle", "Close Play / Info, then clear the selection"),
        ]),
        Section(title: "Sidebar", rows: [
            ("Up / down", "Pick a section (All, Mac Games, an emulator, and so on)"),
            ("Cross or Triangle", "Go to the covers"),
        ]),
        Section(title: "Info column", rows: [
            ("Up / down", "Move between its controls"),
            ("Cross", "Use the control (Name and Game path open the on-screen keyboard)"),
            ("Left / right", "Change Launch with, or move a disc or cover earlier / later"),
            ("L1 / R1", "Switch games while it stays open"),
            ("Triangle", "Close the Info column"),
        ]),
        Section(title: "Toolbar", rows: [
            ("Left / right", "Pick an item"),
            ("Cross", "Activate it (picking a tab moves you into it)"),
            ("Triangle", "Back to the covers"),
        ], note: "A strip appears with the tabs, Search, Add Game, Scan Paths, Import Storefront Games, ScreenScraper Login, Manage Blocked List and Hide / Show Names."),
        Section(title: "Emulators, Paths and Streaming", rows: [
            ("D-pad", "Move between menus, switches, text fields and buttons"),
            ("Cross", "Press a button or switch, or open the on-screen keyboard for a text field"),
            ("Left / right on a menu", "Change its choice"),
            ("Triangle", "Back to the toolbar"),
        ], note: "Rows that are only clickable (like Emulators library search results) need the mouse."),
        Section(title: "On-screen keyboard", rows: [
            ("D-pad", "Pick a key"),
            ("Cross", "Type the key"),
            ("Square", "Delete"),
            ("Triangle", "Space"),
            ("L1 / R1", "Move the cursor"),
            ("L2", "Shift"),
            ("R2, Start or Done", "Finish"),
            ("Circle", "Close (what you typed is kept)"),
            ("Right stick", "Move the keyboard around the window"),
            ("L3 / R3", "Smaller / bigger keyboard"),
        ], note: "Size and position are remembered."),
        Section(title: "Anywhere, including games", rows: [
            ("Select + L1 / R1", "Volume down / up"),
            ("Select + L2 / R2", "Screen brightness down / up"),
        ], note: "Holding repeats, and macOS shows its usual indicator. In GBear, a shoulder button pressed with Select doesn't also switch games or areas, and Select doesn't open Info."),
        Section(title: "In a game or any other app", rows: [
            ("Start + R1", "Enter / exit full screen (sends Control-Command-F)"),
            ("Hold Select + Start for 5 s", "Quit the app (sends Command-Q), then come back to GBear"),
        ], note: "These don't apply inside GBear, and GBear is never quit this way. The game still sees the buttons, so it may pause. Some emulators use their own full screen shortcut, or ask \"Are you sure?\" before quitting; answer that with the mouse or keyboard."),
        Section(
            title: "Permission",
            note: "Volume, brightness, full screen and Command-Q press keys for you, which macOS only allows with Accessibility permission (System Settings > Privacy & Security > Accessibility > GBear). Without it, quitting still works by asking the app to quit, and the others do nothing."
        ),
    ]

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Self.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).font(.headline)
                        if !section.rows.isEmpty { table(section.rows) }
                        if let note = section.note {
                            Text(note)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.trailing, 12)
        }
        .frame(width: 520, height: 460)
    }

    private func table(_ rows: [(button: String, action: String)]) -> some View {
        VStack(spacing: 0) {
            row(button: "Button", action: "Action", index: nil)
            ForEach(rows.indices, id: \.self) { index in
                Divider()
                row(button: rows[index].button, action: rows[index].action, index: index)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    /// `index` nil is the header row.
    private func row(button: String, action: String, index: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(button)
                .fontWeight(.semibold)
                .frame(width: 150, alignment: .leading)
            Text(action)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(index == nil ? .caption.weight(.semibold) : .callout)
        .foregroundStyle(index == nil ? .secondary : .primary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(index == nil || index! % 2 == 1 ? Color.primary.opacity(0.06) : .clear)
    }
}

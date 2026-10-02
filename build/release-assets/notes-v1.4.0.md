Controller and keyboard navigation for the whole Mac app, full covers in the library, Steam sign-in without an API key, and Astris for Switch. The host's bitrate now shows on every guest's picture.

## Mac — GBear-macOS.zip

**Play from the couch with a controller**
- Any Bluetooth or USB controller drives GBear: the D-pad moves between covers, Cross shows Play / Info then plays, Start plays right away, L1 / R1 step through games, L2 / R2 move between the sidebar, covers, Info column and toolbar, and L3 hides the sidebar. Square / Circle resize the covers.
- An on-screen keyboard (move it with the right stick, resize with L3 / R3) for search, game names and paths. Emulators, Paths and Streaming work with the controller too, and so do folder pickers.
- In a game: **Select + Start** held for 5 s quits it and brings GBear back (hold again to force quit; "Are you sure?" dialogs like RPCS3's can be answered with the D-pad and Cross). **Start + R1** toggles full screen. **Select + L1 / R1** change the volume and **Select + L2 / R2** the brightness. These need GBear's Accessibility permission.
- Everything is listed under **Help → Controller Navigation**.

**Keyboard**
- The arrow keys move across the whole app: between covers, into the sidebar, Info column, tabs / Search strip and cover size slider at the edges, and between the controls on the other tabs. Return acts like Cross; on Search you type straight into the search bar.

**Library**
- Covers are shown whole instead of cropped, and rows are only as tall as their covers. A slider at the bottom right sets the cover size.
- **Hide Names** in the ⋯ menu shows covers only. Sequels with Roman numerals sort in order (Clock Tower, II, 3).
- Linked emulator groups can be renamed (right-click the group in the sidebar).
- Fixed repeated covers, covers for titles with brackets in the name, and hidden daily cover checks that used up ScreenScraper requests.

**Storefronts**
- Steam signs in inside GBear with your account (Steam Mobile approval, Steam Guard code or QR code); no Web API key needed. GOG / Epic social sign-in buttons work. Unreal / Fab assets are no longer imported as Epic games.
- The Info column shows which systems a store game runs on, and each store can hide games without a Mac version.

**Emulators**
- **Astris** (Switch) is in Default Launch Arguments, and games now launch in it. Sandboxed emulators get the game the way Finder opens a file.

**Remote co-op**
- Players 3 and 4 have their own stand-in keys (letters and the number row), so remote friends no longer all drive Player 2. Rebind Players 3 and 4 in the emulator using the Controller map.
- Mac guests see the host's video rate on the picture (**Streaming → Show the host's bitrate on the picture**).

Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel).

## Android companion — GBear-companion-android.apk

- Shows the host's video rate in the top-left corner of the picture (for example `Host 7.6 / 8.0 Mbit/s`). Turn it off with **Show host bitrate** in the stream input options.

Copy the apk to the phone and open it to install over the previous version. An iPhone build is not in this release.

## Windows — GBearGuest-windows.exe

- Shows the host's video rate on the picture, like the companion.

If SmartScreen warns, choose **More info**, then **Run anyway**. Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once; joining a Mac does not.

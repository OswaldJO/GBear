# GBear — Features and Inner Workings

This document describes **how the app behaves today** and **where implementation lives**. For a short, commit-adjacent summary of recent changes, see `source control log.md`.

---

## Product shape

- **SwiftUI** app with a tabbed shell: **Library**, **Emulators**, **Paths**, **Streaming**. Controller mapping is **companion-only** (no **Controllers** tab on the Mac app).
- **SwiftData** persists emulators, game folder paths, and library games. Store file: see `PersistenceStoreLocation` (default under Application Support).

---

## Library tab

### Sidebar

- **All** — every visible game (emulator-linked + standalone Mac/Epic-style entries that pass filters).
- **Mac Games** — games with **no** `emulatorUUID` (native Mac adds, Epic imports, etc.). Context menu can clear only these entries.
- **Per-emulator** — games linked to that `EmulatorProfile`.
- **Cover Art and Metadata → Screen Scrapper** — detail pane for ScreenScraper: open credentials sheet, run a **full-library** metadata/cover scrape (not the game grid). **Automatic matching** includes **Only Scan Missing** (default on): skip games that already have ScreenScraper cover art; uncheck to scrape the whole library again.

### Toolbar (Library)

- **Add Game** — `NSOpenPanel` for app/executable/directory; creates `LibraryGame` with no emulator.
- **Scan Paths** — `GamePathScanner.scan` plus `EpicInstalledGamesImporter.importInstalledGames`; may schedule metadata pass. Scan is **one level deep** (files + immediate subfolders). After scanning, **prunes** emulator-linked games under a **reachable** Paths game folder when the ROM/file is missing (`ScanSummary.removedMissing`). Also removes leftover per-file rows inside folders now treated as one game (`removedNested`). Games under an offline/unmounted Paths root are kept. Startup still removes games whose **emulator** no longer exists.
- **Import Epic Installed Games** — Epic-only import.
- **Metadata Settings** — presents `ScreenScraperSettingsSheet`.

### Grid and play

- `LibraryGamesGridView` / `GameLibraryTile`: tap for play/info overlay; play goes through `GameLauncher`. Tile size is **fixed width 160**; height follows that game’s emulator **cover art size** (`CoverAspectRatio`, default **2:3**). Mixed **All** rows can be uneven. Crop is **display-only** (`scaledToFill` + clip); scrape still stores the full image.

### Inspector (Info)

- `LibraryGameInspectorView`: display name; for emulator-linked games — **File** (basename) and **Path** (full `romPath`, link-styled; tap opens **Finder** via `NSWorkspace.activateFileViewerSelecting`); for **Mac** entries with no emulator — editable game path + **Choose Game…**.
- **Multi-disc set:** link with suggestions or **Link with other discs…** sheet (`DiscGroupLinkSheet`); list linked discs with ▲/▼ reorder; **Reset order from filenames**; **Unlink this disc**. Linked discs share cover art and ScreenScraper `gameid`/`systemeid`; changes propagate via `DiscGroupService.propagateSharedState`.
- Cover art: choose file, ScreenScraper manual search, reorder detected covers, set primary, clear. Inspector preview uses the same per-emulator crop as the grid.

Grid tiles show a **Disc N** badge when the game is in a linked set and a disc number is parsed from the path/title.

**Key types:** `RootView.swift`, `LibraryGame.swift`, `CoverAspectRatio.swift`, `DiscGroupService.swift`, `DiscGroupLinkSheet.swift`.

---

## Emulators tab

- Add/configure `EmulatorProfile`: executable path, GBear-style `{ImagePath}` / `{rom}` template, optional per-emulator ROM extensions.
- **Cover art size** — picker on create and edit (`CoverAspectRatio`): **2:3 (SteamGridDB)**, **4:3 (SNES)**, **1:1 (GBA, PSX)**, **3:4 (PS2, GC, WII, NES)**, **8:7 (NDS, 3DS)**, **3:5 (PSP, SWITCH)**, **16:9 (Screen / Banner)**. Stored as `coverAspectRatioRaw` (default `"2:3"` for SwiftData migration). Catalog/custom row fill infers a starting ratio from platforms/name; the user can change it before Add / Save.
- **`{user_name}`** expands to the current macOS account short name at launch (for paths under `/Users/{user_name}/Library/...`). Leading **`~`** in an argv token is expanded. Absolute home paths in stored templates are normalized to `/Users/{user_name}/...` on save/startup (`LaunchArgumentTemplate`).
- Export/import configured profiles (optional `coverAspectRatioRaw`; older JSON keeps the current ratio on conflict overwrite). Bundled catalog + custom launch-argument presets live in `BuiltinEmulatorCatalog` / `CustomEmulatorLibraryStore`.
- **PS2:** catalog preset **ARMSX2** (`emulatorId: armsx2`); default startup **`-fastboot -- "{ImagePath}"`**. **AetherSX2** is not in the catalog; startup may retarget existing `AetherSX2.app` profiles to `/Applications/ARMSX2.app`.
- **Add emulator:** choosing a catalog/custom row fills launch args, file types, and a starting **cover art size**; **display name** is filled only when that field is empty.
- **App Sandbox is off** for the Mac app (`GBear.entitlements`). Sandboxed callers cannot pass `NSWorkspace.OpenConfiguration.arguments` (system ignores them).

**Key types:** `EmulatorsView.swift`, `EmulatorProfile.swift`, `CoverAspectRatio.swift`, `LaunchArgumentTemplate.swift`, `BuiltinEmulatorCatalog.json`.

---

## Paths tab

Per **selected emulator**:

- **Game folders** — scanned by `GamePathScanner` **one level deep**: each **file** and each **immediate subfolder** is one library game. Files inside a subfolder are not separate games (bin/cue dumps in a title folder stay one entry). Launch path for a folder is the best immediate file (`m3u` > `cue` > `gdi`/`chd`/`iso` … last `bin`). Point the path at the folder that *contains* those games, not a grandparent of lettered subfolders unless those folders are the titles.
- **Cover folders** — local images matched to ROM names on scan.
- **Exclude folders** — skipped during scan.
- **Toggle:** *Prioritize ScreenScraper art over local covers* — stored on `EmulatorProfile.preferScreenScraperCovers` (default `false`). Affects **auto-selected primary** cover after a metadata pass; all sources still accumulate in `coverImageOptions`.
- **Toggle:** *Auto-link multi-disc games on scan* — `EmulatorProfile.autoLinkMultiDiscGames` (default `false`). After each **Scan Paths**, `DiscGroupService.autoLinkAllEnabledEmulators` clusters games on that emulator with the same normalized base title (same logic as manual link suggestions) and links sets of 2+; `ScanSummary.autoLinkedDiscSets` reports count.

**Key types:** `PathsView.swift`, `GameFolderPath.swift`, `GamePathScanner.swift`, `DiscGroupService.swift`.

### RPCS3 / PS3 folder scanning

When a configured **game folder** belongs to an RPCS3 (or PS3-style) emulator, `GamePathScanner` uses **folder-aware** import instead of treating every file under `dev_hdd0/game` as a ROM:

| Detection | Behavior |
|-----------|----------|
| **Title folder** | Subfolder with `PARAM.SFO` and `USRDIR/EBOOT.BIN` (RPCS3 install) or `PS3_GAME/USRDIR/EBOOT.BIN` (disc dump layout). |
| **Title** | Read from `PARAM.SFO` (`TITLE`, else `TITLE_ID`, else folder name). |
| **Launch path** | Stored `romPath` is the **`EBOOT.BIN`** file; `GameLauncher` substitutes it into the emulator’s `{ImagePath}` / `{rom}` template (RPCS3 catalog default: `"{ImagePath}"`). |
| **Category filter** | Only **`GD`** (disc install) and **`HG`** (PSN/HDD install) folders are imported; patch/DLC/UCC/APPDATA-style siblings are skipped. |
| **File scan** | Loose **`.iso`** files sitting **directly** in the game folder are still imported. Inner assets (`.bin` tracks, etc.) are not separate games. |

**Typical path:** `~/Library/Application Support/rpcs3/dev_hdd0/game` assigned to the RPCS3 `EmulatorProfile` on the **Paths** tab.

**Rescan:** If a library row already exists for the same normalized `EBOOT.BIN` path, scan **updates the title** from `PARAM.SFO` (and can reassign emulator if the path moved profiles). Counts toward `ScanSummary.reassigned`.

**Limits:** Retail **GD** HDD folders often contain **game data only** (no `USRDIR/EBOOT.BIN`); RPCS3 boots those from the Blu-ray image or its internal list, not from an EBOOT path in `dev_hdd0/game`. Import those titles via **PS3 `.iso`** paths (or manual add) if you want them in the library grid.

**Help:** App menu **RPCS3 Game not launching** — if RPCS3 is already open, close it before launching a different PS3 game from the library (single-instance / open-document behavior).

**Key implementation:** `GamePathScanner.ps3LaunchPathIfPresent`, `ps3Metadata` / `parsePS3SFO`, `shouldIncludePS3Folder`, `isPS3StyleEmulator`, `preferredLaunchFile`.

---

## Metadata and ScreenScraper

- **IGDB removed.** Remote metadata uses **ScreenScraper API v2** (`https://api.screenscraper.fr/api2/…`).
- **Credentials:** `MetadataCredentials` — `devid` / `devpassword` required; `ssid` / `sspassword` optional. Persisted in `UserDefaults` (see `docs/metadata-setup.md`).
- **Matching waterfall** (`MetadataService`, per game):
  1. Pinned `screenScraperGameId` + `screenScraperSystemId` on `LibraryGame` (if set).
  2. **`jeuInfos.php`** hash lookup (`RomFingerprint`: MD5/CRC32/SHA1, `.cue`/`.m3u` payload, PS3 folder `dossier`) — requires resolved **`systemeid`**.
  3. **`jeuInfos.php`** exact filename (`romnom` + size + `romtype`).
  4. **`jeuRecherche.php`** fuzzy search with query variants (`RomTitleNormalizer`, `.hack` `//` forms, roman → arabic numerals).
  5. Auto-select from ambiguous set (user toggle) or `ScreenScraperDisambiguationCoordinator` sheet.
- **Platform resolution** before scrape: `EmulatorProfileLookup` (SwiftData relationship or `emulatorIDString`) → `EmulatorPlatformResolver`; fallback `MetadataSystemResolver` (`platformHint`, Epic → PC **135**); fallback **`RomPathPlatformResolver`** (longest matching **Paths** game-folder root). Scrape logs include `emulatorSystemeid=`.
- **Title safety:** `pickTitleIsCompatible` blocks wrong-platform fuzzy picks; Part/Vol numbers optional when subtitle matches (`.hack Part 1` ↔ `.hack//Infection`). Scraped title applied only when compatible (hash/exact always apply).
- **Background fetcher:** `MetadataBackgroundFetcher` — periodic batches; **schedule extra** after scans; full library scrape from Screen Scrapper sidebar (`scrapeAllNow`). **Only Scan Missing** (default on) filters that full scrape to games without ScreenScraper covers (`LibraryGame.hasScreenScraperCover`). Session logs: `gbear-scrape-*.log` in Downloads. **`clearAllScrapedMetadata`** wipes covers, ScreenScraper IDs, disambiguation queue.
- **Covers:** `CoverImageCache` disk cache; validates decoded `NSImage` before save. Local folder discovery first; remote appended to `coverImageOptions`; primary respects `preferScreenScraperCovers`. **Library crop** is per-emulator (`CoverAspectRatio`); files on disk are not rewritten. **Multi-disc:** cover + ScreenScraper IDs propagate to siblings in the same `discGroupIDString`.

**Key types:** `MetadataService.swift`, `ScreenScraperClient.swift`, `RomFingerprint.swift`, `RomTitleNormalizer.swift`, `MetadataSystemResolver.swift`, `RomPathPlatformResolver.swift`, `MetadataBackgroundFetcher.swift`, `ScreenScraperLibraryView.swift`, `ScreenScraperDisambiguationCoordinator.swift`, `CoverImageCache.swift`.

---

## Epic Games (installed only, no OAuth in-app)

- **Import:** `EpicInstalledGamesImporter` reads Epic launcher manifests under `~/Library/Application Support/Epic/.../Manifests`.
- **Model:** `LibraryGame.librarySourceID` (`"epic"`), `epicAppName` for launcher URI.
- **Launch:** `GameLauncher` — if `epicAppName` is set, tries `com.epicgames.launcher://apps/...` before falling back to direct path.

**Key types:** `EpicInstalledGamesImporter.swift`, `GameLauncher.swift`.

---

## Launch pipeline

- **Emulator games:** resolve `EmulatorProfile`; expand `{user_name}`, `{ImagePath}` / `{rom}` / `{ROM}`, and `~` (`LaunchArgumentTemplate` + `GameLauncher.parseArguments`).
- **With non-empty argv:** quit any running copy of that `.app` (so macOS does not merely activate an existing window and drop args), then **`NSWorkspace.openApplication`** with `OpenConfiguration.arguments` and **`createsNewApplicationInstance = true`**.
- **Already-running + empty template:** optional “open document” Apple Event path (avoid for PCSX2/ARMSX2 boot — see bug journal).
- **Standalone / no emulator:** Epic URI path above, else open `.app` or file URL.
- **Do not** rely on `/usr/bin/open --args` from a sandboxed process, or on `OpenConfiguration.arguments` while App Sandbox is enabled — both fail to deliver the ISO path (emulator stays on its game list).

**Key types:** `GameLauncher.swift`, `LaunchArgumentTemplate.swift`.

---

## Streaming tab (native GBear host)

The Mac app embeds its own **GBear stream host** (ScreenCaptureKit → H.264, HTTP control plane, UDP audio/input). The companion pairs over HTTP and opens a **native video activity** on Android (`GBearVideoActivity`); Sunshine/Moonlight RTSP is no longer required for the default Android desktop stream path.

### Host lifecycle

- **`GBearStreamHostManager`** — in **`ensureReady()`** starts HTTP control (**28765**) and keeps transport listeners bound for the life of the host: TCP video (**28766**), UDP audio subscribe (**28767**), TCP audio downlink (**28769**), UDP input (**28768**). Capture starts on first remote **`stream/start`**; later viewers **attach without restarting encode**. Session create seats **this Mac as Player 1** unless a companion is designated as host player. Stream start/stop is serialized on **`streamOperationChain`**. On stream start, **`GBearLocalOutputMute`** mutes Mac default output; unmutes when the last **video** viewer leaves. **`isVideoStreaming`** mirrors **`videoStreaming`** on the control API.
- **`GBearStreamControlServer`** — pairing queue (`clientKind`: phone vs computer) + **co-op session seats 1–8** (`POST /gbear/v1/session/create|join|join-local|host-player|leave|reassign|cursor-owner|end`); **`stream/start`** auto-joins in **join order** after seating the host player; **`playAsHost`** lets a companion take Player 1 in place of this Mac. **`stream/stop`** leaves the seat and only stops capture when no remaining clients want video. Status includes `session`, `hostPlayerDeviceId`, + `maxViewers` (8).
- **`GBearVideoStreamServer`** / **`GBearAudioStreamServer`** — up to **8** TCP clients; framed **`GBV1`** / **`GBA1`**.
- **`GBearDisplayCapture`** — SCK display + **system audio** (`capturesAudio`); PCM converted to s16le.
- **`GBearStreamInputServer`** — **`GBI1`** touch, **`GBK1`** keyboard, **`GBG1`** gamepad. Incoming GBG1 `joinSeat` is translated to the current assigned seat so **Move to Player N** does not require clients to change packets.
- **`GBearVirtualGamepadManager`** — IOHIDUserDevice pads named **GBear Virtual Pad N**, created only for **occupied** seats.
- **`GBearHostLocalGamepad`** — host GCController → assigned virtual pad.
- **`GBearStreamGuestManager`** — another Mac pairs as `computerGuest`, receives video/audio, sends local pads as GBG1.
- **`GBearSessionCoordinatorClient` / `GBearSessionTunnel`** — remote co-op (coordinator auth/invites/ICE/TURN + GBTL mux). LAN remains direct ports; coordinator membership is 8, WAN byte-relay is still two sockets.
- **`StreamingView`** — **Host plays on** (this Mac = Player 1 and uses a slot, so **7 devices** can join; a paired companion standing in frees the Mac slot so **8 devices** can join), Join another computer (join order by default), 8-slot Move-to UI, pairing for phones and computers.

### macOS permissions

| Permission | Purpose | UI name |
|------------|---------|---------|
| **Screen Recording** | Desktop video + system audio capture | GBear |
| **Accessibility** | Synthetic mouse move/click from phone touch | GBear (same list entry; not a separate “touch” item) |
| **Virtual HID** (`com.apple.developer.hid.virtual.device`) | Up to 8 co-op virtual gamepads | Entitlement on Mac target |

Restart the Mac app after toggling Accessibility. Stream audio is **not** a separate item in **System Settings → Sound → Output**; it is captured and sent to the phone. While a stream is active, the Mac’s default output is **muted** so speakers stay quiet and the phone is the playback device (use phone **media** volume during a stream).

### GBear stream ports

| Port | Protocol | Role |
|------|----------|------|
| 28765 | HTTP | Control — pairing, co-op session, stream start/stop |
| 28766 | TCP | Video — `GBV1` framed H.264 (up to 8 viewers) |
| 28767 | UDP | Audio subscribe — phone `GBAS` |
| 28769 | TCP | Audio downlink — length-prefixed `GBA1` PCM |
| 28768 | UDP | Input — `GBI1` / `GBK1` / `GBG1` |

**Key types:** `StreamingView.swift`, `GBearStreamHostManager.swift`, `GBearStreamControlServer.swift`, `GBearCoopSession.swift`, `GBearVideoStreamServer.swift`, `GBearDisplayCapture.swift`, `GBearAudioStreamServer.swift`, `GBearLocalOutputMute.swift`, `GBearStreamInputServer.swift`, `GBearGamepadEventFormat.swift`, `GBearVirtualGamepad.swift`, `GBearHostLocalGamepad.swift`, `GBearStreamGuestManager.swift`, `GBearSessionCoordinatorClient.swift`, `GBearSessionTunnel.swift`, `GBearRemoteInputPlayback.swift`, `GBearKeyboardPlayback.swift`, `GBearStreamPorts.swift`, `AccessibilityPermission.swift`. Separate C target **`GBearHID`**. Companion auto-map: `GBearGamepadAutoMapper.kt`, `GBearCoopPadMappingStore.kt`.

Setup: `docs/streaming-native.md`. Remote coordinator: `services/gbear-session/`.

---

## Companion app (`companion_app/`)

Flutter shell (iOS + Android) for discovery, HTTP pairing with the native Mac host, and LAN streaming.

### Tabs

- **Hosts** — discover Mac via GBear HTTP control plane; **Add IP** (outlined); **Pair** / **Cancel** while a pairing request is pending (`PairingCancellation` + **`POST /gbear/v1/pair/cancel`** on the Mac).
- **Session** — **`GBearHostClient.startStream`** attaches in **join order** (host Mac is Player 1 unless **Play as the host** is on). The Mac’s slot counts toward 8; an 8th device can join only as the host stand-in. Optional slot override at join; Mac **Move to** reassigns after. Opens **Android** `GBearVideoActivity`. **Stop** leaves the seat; capture ends when the last **video** viewer leaves.
- **Controller** — **Co-op pad mode (GBG1)** (default on) **Auto-maps** connected pads (Eden-style key/axis probe) onto GBG1; **Override** listens for a press. Off uses keyboard chords / Swap. Link gamepad + chord UI remains for single-player / shortcuts.
- **Settings** — **Appearance**, Swap, Shortcuts, **Remote co-op** (coordinator URL, sign-in, redeem invite).

### Android native (GBear video)

- **`GBearVideoActivity`** — TCP `GBV1` reader thread; codec pump on `HandlerThread`; decode profiles (Annex-B passthrough + `c2.android.avc.decoder` first). **`volumeControlStream`**: media volume. Gamepad motion: if **Swap** on, **`GBearGamepadMouseSender`** runs first (left stick → **`GBI1`** cursor); then **`GBearGamepadMapping`** (triggers, hat D-pad, analog stick directions). Keys: **Back** → **`GamepadLinkCapture`** → mapping (including **toggleSwap**) → Swap mouse for **A/B/X** only → swallow other gamepad keys. **`onDestroy`**: Mac **`stream/stop`** only when the activity did **not** exit via **Back** (`leaveViewerWithoutMacStop`).
- **`MainActivity`** (Flutter shell) — **`GamepadInputFilter`** swallows gamepad keys/motion outside the stream viewer; **volume** keys pass through. **`GamepadLinkCapture`** during link (with target **`elementId`**). **`onDestroy`**: best-effort Mac stop if a stream was still marked active.
- **`GBearAudioReceiver`** — prefers **TCP 28769** (length-prefixed `GBA1`); falls back to UDP after `GBAS` subscribe on **28767**. Separate network and playback threads; `AudioTrack` buffer ~150 ms with low-latency mode; small PCM queue to avoid blocking the socket reader.
- **`GBearInputSender`** — relative cursor, tap/drag gestures on the video `SurfaceView` → UDP `GBI1` to Mac (background thread). Tunables in **Settings → Controllers → Touchpad (stream view)**. Primary pointer path during native stream (no Moonlight mouse-emulation toggle).
- **`GBearRemoteInputPlayback`** (Mac) — maps normalized touch to the **captured display** frame; Y uses `minY + ny × height` so finger-up on the phone moves the cursor up on the Mac.
- **`GBearStreamLog`** — writes `gbear_stream.log` under app files dir for export/debug.
- **Appearance (companion)** — **Settings → Appearance**: primary text color presets (White, Purple, Lavender, Blue, Mint, Peach) or **Custom** RGB sliders. Default on fresh install is **Mint** (`#80CBC4`). Persisted in `companion.appearance.primaryTextColor`; `CompanionApp` rebuilds `CompanionTheme.dark(primaryText:)` when the value changes (`CompanionAppearanceSettings.themeRevision`). The color drives **`outlinedButtonTheme`** (Hosts **Add IP**, **Pair**, **Cancel**) and **`chipTheme`** (mapping/shortcut key chips: transparent fill, matching outline and label).
- **Stream shortcuts (Android)** — **Settings → Shortcuts**: named keyboard chords (multi-key). Default **Close app** = **Command + Q** (macOS quit foreground app); upgrades a stored ⌘⌥Esc default on launch. Stored in `stream.shortcuts` SharedPreferences; native overlay reads the same JSON. **`GBearStreamSession.keyboardSender`** is shared for the whole stream (survives leaving `GBearVideoActivity` with Back). Notification **Shortcuts** opens a picker on the video overlay or, if the viewer is closed, a Flutter sheet + `fireStreamShortcut`. Chords are sent as **`GBK1`** UDP on **28768** (~140 ms hold). Verified Jun 3 2026 with Mac **`GBearKeyboardPlayback`** VK table fix.
- **Controller mapping (Android)** — **Controller** tab: elements → **chords**, **Link gamepad**, or **Assign Swap**. Includes **left/right stick** cardinal directions (held while deflected; separate from L3/R3). **Link** waits for the control matching the row (e.g. push **right stick up** for **Right stick up**; D-pad rows accept hat or stick). Many pads report D-pad as **`AXIS_HAT_X/Y`** — **`handleHatDpad`** sends chords without blocking Swap when hat is centered. Manual links use synthetic key codes in **`GamepadKeyCodes`** for stick directions. **A / B / X** and **left stick** directions cannot **Assign Swap**. **`GBearGamepadMapping`**: keys, triggers, hat, sticks; **`toggleSwap`** on each **ACTION_DOWN** (no stuck latch). Bindings reload from prefs in the stream view; **`GBearKeyboardSender`** survives **Back**.
- **Swap mouse mode (Android)** — Notification **Swap** or **Assign Swap** toggles **`swapMouseModeActive`**. While on: left stick → cursor (**Swap stick cursor speed** in Settings); **A** click, **B** right-click, **X** drag; other mappings (Y, bumpers, right stick, D-pad chords, etc.) still fire. **`releaseAllKeys`** on toggle off avoids stuck modifiers on the Mac.
- **Stream notification (Android)** — channel **`gbear_stream_session_v2`**. Custom layout: row 1 **Stop | Swap**, row 2 **Controller | Shortcuts**; `addAction` fallback on OEMs that collapse custom views. **`GBearStreamNotificationReceiver`**: **Stop** → **`GBearStreamStopCoordinator.stopSession`** (deactivate session, dismiss notification, finish **`GBearVideoActivity`** or end log file, background Mac **`stream/stop`**, optional Flutter **`notifyFlutterStreamStoppedExternally`**); **Swap** → **`GBearStreamSwapActions.toggle`**; **Controller** / **Shortcuts** → mapping overlay or shortcut picker. No `CLOSE_SYSTEM_DIALOGS` broadcast (crash fix). Best-effort shade collapse after the action.

**Key types:** `gbear_host_client.dart`, `streaming_bridge.dart`, `stream_controller_mapping_store.dart`, `stream_touch_settings.dart`, `gamepad_elements.dart`, `gamepad_swap_toggle.dart`, `controller_mapping_section.dart`, `GBearVideoActivity.kt`, `MainActivity.kt`, `GamepadInputFilter.kt`, `GamepadLinkCapture.kt`, `GBearGamepadMouseSender.kt`, `GBearGamepadMapping.kt`, `GamepadKeyCodes`, `GBearStreamStopCoordinator.kt`, `GBearStreamSwapActions.kt`, `GBearStreamNotificationHelper.kt`, `GBearStreamSession.kt`, `GBearKeyboardPlayback.swift`, `GBearStreamHostManager.swift`, `GBearStreamControlServer.swift`, `GamepadElementCatalog.swift`.

### Keyboard chord codes (companion → Mac)

Companion labels use Moonlight’s Windows virtual-key codes (`moonlightKeyCode = (0x80 << 8) | vk`). Mac playback maps the low byte through a **US ANSI VK → `CGKeyCode`** table (see `GBearKeyboardPlayback.swift`). Example: **Q** is Windows `0x51` → Mac key code **12** (`kVK_ANSI_Q`), not `0x51 - 0x41`. Mac-specific modifiers:

| UI label | Windows VK | Mac key |
|----------|------------|---------|
| Option | `0xA4` | Left Option |
| Option (right) | `0xA5` | Right Option |
| Command | `0x5B` | Left Command |
| Command (right) | `0x5C` | Right Command |

Legacy bindings that used **Alt** (`0x12`) still map to left Option on the Mac.

### Phone export log (what to look for)

| Log line | Meaning |
|----------|---------|
| `Rendered frame #N` | Video path healthy |
| `Audio TCP connected` | Phone opened TCP downlink on **28769** |
| `Audio packet #N` | `GBA1` frames received and queued for playback |
| `AudioTrack started … buf=…` | Playback started; `buf` should be tens of KB, not multi-MB |
| `Audio subscribed` | UDP fallback path only (TCP preferred) |
| `Input UDP #1` | Touch packets leaving the phone |
| `Shortcut "…" (Command + Q) → host:28768` | User fired a stream shortcut |
| `Keyboard GBK1 down key=0x805b` | Modifier/key down (e.g. Command) |
| `Keyboard GBK1 down key=0x8051` | Key down (e.g. Q) |
| `Input send failed` / `Keyboard send failed` | Network/firewall or socket error on input port |
| `Back pressed — leaving stream view` | Video UI closed; host stream may stay active until **Stop** |
| `Swap on` / `Swap off` (toast) | Notification or mapped button toggled Swap mouse mode |
| `Gamepad map leftStickUp` / hat | Stick or D-pad chord down/up to Mac |
| `viewer closed` / `activity destroyed` | Back left stream running; destroy may stop Mac if not viewer-only exit |
| `Pairing cancelled` / `Cancelling pairing` | User tapped **Cancel** on Hosts |

**Doc:** `docs/companion-flutter.md`, `docs/streaming-native.md`.

---

## Data model (SwiftData)

- **`EmulatorProfile`** — name, paths, launch template, extensions, `preferScreenScraperCovers`, `autoLinkMultiDiscGames` (both default `false` for migration), `coverAspectRatioRaw` (default `"2:3"`).
- **`LibraryGame`** — title, `libraryDisplayName`, `romPath`, optional emulator link (`emulatorIDString` + relationship), cover URLs/options JSON, `platformHint`, `screenScraperGameId` / `screenScraperSystemId`, `screenScraperSelectionSkipped`, `discGroupIDString`, `discGroupOrder`, `librarySourceID`, `epicAppName`, `sortOrder`, play/metadata timestamps.
- **`GameFolderPath`** — folder path, purpose (games / covers / excludes), linked emulator.

---

## Help menu (app target)

- Replaces default Help group with topic buttons (RetroArch, RPCS3, orphan cleanup, **Keystrokes permission**). Implemented in `GBear.swift`.

---

## Known constraints / pitfalls

- **App Sandbox vs launch argv:** Keeping `com.apple.security.app-sandbox` on strips `NSWorkspace.OpenConfiguration.arguments`. Emulator launch requires an unsandboxed Mac app (current `GBear.entitlements`).
- **ARMSX2 / PCSX2 CLI:** Prefer **`-fastboot -- "{ImagePath}"`**. A bare `--` before the ISO is required when the path can confuse option parsing. **`-batch -fullscreen`** often produced a gray GS window even when the ISO did boot (check `~/Library/Application Support/ARMSX2/logs/emulog.txt` for `isoFile open ok` / ELF load).
- **Already-running ARMSX2:** `open -a … --args` without quitting first only activates the existing game-list window and does not apply new argv — `GameLauncher` terminates instances before CLI launch.
- **RPCS3 `dev_hdd0/game`:** Assign the folder to the **RPCS3** emulator profile (not a generic multi-system profile) so folder import and ISO-only file rules apply. After scanner fixes, run **Scan Paths** to rename stale **EBOOT** entries. PSN/HDD (**HG**) installs need `USRDIR/EBOOT.BIN`; disc **GD** data folders without EBOOT are not launchable from this path alone.
- **ScreenScraper** quotas, threading, and API shape can change. Without resolved **`systemeid`**, hash lookup is skipped and fuzzy search may pick wrong consoles (DS/Xbox/NES) or return `no_match`. Run **Scan Paths** so `RomPathPlatformResolver` can infer platform from folder roots; check scrape log for `emulatorSystemeid=nil`.
- **Multi-disc auto-link** uses normalized base titles — enable per emulator on **Paths**; manual link/unlink still available in inspector.
- **SwiftData migration:** new non-optional attributes need defaults or optional types; a prior crash on `preferScreenScraperCovers` was fixed with `= false` on the property. `coverAspectRatioRaw` defaults to `"2:3"`.
- **Full-library scrape** is synchronous per game with delays; large libraries take time and network.
- **Native streaming (Android)** is verified: video over TCP **28766** (~99% rendered vs. received); audio over TCP **28769** with Mac output muted during stream; touch over UDP **28768** with Accessibility granted.
- **Audio troubleshooting:** expect `Audio TCP connected`, then `Audio packet #1` and `AudioTrack started` with a modest buffer size. Mac console: `[GBearAudio] phone connected (TCP audio)`, `muted Mac default output`, `sent TCP audio frame #N`. If silent, check phone **media** volume and Mac firewall for **28767** / **28769**.
- **Touch** requires Mac **Accessibility** for **GBear**; phone should log `Input UDP #1`. Rebuild Mac app after input-mapping changes.
- **Keyboard shortcuts** require the same **Accessibility** grant; phone logs `Keyboard GBK1`; Mac Console shows `[GBearInput] GBK1` / `keyboard`. Rebuild Mac app after `GBearKeyboardPlayback` changes.
- **Stream notification** on some OEMs may still collapse custom layouts; two-row inline buttons + `addAction` fallback are both present. Do not rely on `CLOSE_SYSTEM_DIALOGS` from the app (blocked on modern Android).
- **Swap stick sensitivity** is independent of touchpad **Cursor speed**; raise Swap stick speed in **Settings** if the cursor feels too slow after fixing inversion (stick up = cursor up on Mac).
- **Companion iOS** native video receiver is still limited; Android `GBearVideoActivity` is the reference client.
- Use the Mac’s **LAN IP** (e.g. `192.168.1.x`), not `127.0.0.1`, on the phone.

---

## Cross-reference

- **What changed lately:** `docs/source control log.md`
- **Credential setup detail:** `docs/metadata-setup.md`
- **Native streaming:** `docs/streaming-native.md`
- **Legacy Sunshine quickstart (optional):** `docs/streaming-quickstart.md`, `docs/streaming-setup.md`
- **Companion app:** `docs/companion-flutter.md`, `companion_app/README.md`

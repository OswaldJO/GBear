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
- **Count** — footer under the sidebar shows how many games are in the selected list (All, Mac Games, Flycast, …). Hidden on Screen Scrapper and storefront panes.
- **Storefront Manager → Show Manager** — one sidebar row that opens `StorefrontManagerView`. At the top, a **Storefronts** card has a checkbox for **Epic Games**, **Steam**, **GOG** (`StorefrontSettings.enabled`, `UserDefaults` `Storefronts.Enabled`, default Epic only). Unchecked storefronts are not imported and their games are hidden from the grid (rows are kept). Then a login card per storefront (`StorefrontLoginCard`) with **Only show installed games in library** (`Storefronts.OnlyInstalled`, per storefront), the Steam Web API key field, and the Epic paste-code fallback. Last, one import card with per-storefront counts and the last result.
  - **Sign-in** (`StorefrontLoginSheet`, embedded `WKWebView` with a non-persistent data store):
    - **Steam:** OpenID to `steamcommunity.com` returns the SteamID64. Owned games also need the user's own **Steam Web API key** (`IPlayerService/GetOwnedGames`).
    - **GOG:** OAuth with the GOG Galaxy client id; the code arrives on the `embed.gog.com/on_login_success` redirect.
    - **Epic:** Epic Games Launcher OAuth client; the `authorizationCode` JSON page is read, or the user pastes the code after signing in in a browser.
    - Tokens are exchanged for refresh tokens. Refresh tokens (rotated on each import) and the Steam key live in the Keychain (`StorefrontCredentials`, service `com.gbear.storefronts`); account names and the SteamID live in `UserDefaults`.
  - **Import** (`StorefrontImporter`), for each checked storefront:
    - **Installed from disk:** Steam `libraryfolders.vdf` + `appmanifest_*.acf` with StateFlags bit 4 (`SteamClient`, `VDF` parser). Epic launcher `.item` manifests (`EpicClient`, replaces `EpicInstalledGamesImporter`). GOG `goggame-<id>.info` in `/Applications`, `~/Applications`, `~/GOG Games` app bundles (`GOGClient`).
    - **Owned list when signed in:** Steam Web API; GOG `account/getFilteredProducts`; Epic library-service records + catalog bulk items. Epic catalog lookups run only for app names not already in the library, and DLC / add-ons / engine content is dropped.
    - **Library rows:** `librarySourceID` = storefront raw value, `storefrontGameID` (Epic app name / Steam app id / GOG product id), `storefrontInstalled`. Uninstalled owned games use a launcher URL as `romPath` (`steam://rungameid/…`, `goggalaxy://openGameView/…`, `com.epicgames.launcher://apps/…`).
    - **Removal:** a storefront row that is neither installed nor owned (or not installed while signed out) is removed on import. If the owned list fails to load, rows are kept and only marked not installed.
    - **Covers:** new rows get store art (Steam `library_600x900_2x`, falling back to `header.jpg` via a HEAD check; GOG games-database vertical cover; Epic `DieselGameBoxTall`). The metadata fetcher skips storefront games that already have a cover. Legacy Epic rows are matched by `epicAppName` or path.
  - **Grid:** installed storefront games show a green check in the cover's top-right corner (`LibraryGame.isInstalledStorefrontGame`).
  - **Launch** (`GameLauncher.launchStorefrontGame`): Steam always via `steam://rungameid`; Epic via the launcher URI, falling back to the installed app; GOG opens the installed app, otherwise the game in GOG Galaxy.
  - **Blocking:** removing a storefront game blocks `storefront/<store>/<id>`, so it stays blocked whether installed or not.
- **ROMM → Show ROMM** — opens `RommSettingsView`. See **ROMM** below.
- **Cover Art and Metadata → Screen Scrapper** — detail pane for ScreenScraper in this order: **login**, **Actions** (full-library scrape), **Automatic matching**, **Region priority** at the bottom (reorderable list; first available cover/title region is used). **Only Scan Missing** (default on) skips games that already have scraped cover art (ScreenScraper or TheGamesDB); uncheck to scrape the whole library again. The panel also has **IGDB keys** and **TheGamesDB API key** cards (in fallback order). When you are not signed in, the scrape fetches covers from whichever of those keys are saved.

### Toolbar (Library)

- **Add Game** — `NSOpenPanel` for app/executable/directory; creates `LibraryGame` with no emulator. Also unblocks that path if it was on the blocked list.
- **Scan Paths** — `GamePathScanner.scan` plus `EpicInstalledGamesImporter.importInstalledGames`; may schedule metadata pass. Scan is **one level deep** (files + immediate subfolders). After scanning, **prunes** emulator-linked games whose ROM/file is missing when that location is **reachable** (`ScanSummary.removedMissing`) — including leftovers from a Paths folder that was later removed. Also removes leftover per-file rows inside folders now treated as one game (`removedNested`). Games under an offline/unmounted volume are kept. Startup still removes games whose **emulator** no longer exists. Blocked paths are never inserted (`ScanSummary.skippedBlocked`, reported in the scan alert).
- **Import Storefront Installed Games** — `StorefrontImporter.importAll` for every checked storefront (also runs at the end of **Scan Paths**; skips blocked games). See **Storefront Manager** below.
- **ScreenScraper Login** — presents `ScreenScraperSettingsSheet`.
- **Manage Blocked List** — presents `BlockedGamesSheet`: games removed with **Remove from Library**, with emulator name, removal date, and path. It has per-row **Unblock** and **Unblock All**, and the next Scan Paths re-adds unblocked games. The list is `LibraryBlocklist` (JSON in `UserDefaults` key `Library.BlockedGames`, keyed by the lowercased standardized path the scanner compares with). Only the grid context menu's **Remove from Library** (`RootView.deleteGame`) adds entries. **Clear All Games** / **Clear Games for …** / **Clear Mac Games**, orphan cleanup, and scan pruning do not. Help → **Games missing after scan** explains this.

### Grid and play

- `LibraryGamesGridView` / `GameLibraryTile`: tap for play/info overlay; play goes through `GameLauncher`. Tile size is **fixed width 160**; height follows that game’s emulator **cover art size** (`CoverAspectRatio`, default **2:3**). Mixed **All** rows can be uneven. Crop is **display-only** (`scaledToFill` + clip); scrape still stores the full image.

### Inspector (Info)

- `LibraryGameInspectorView`: display name; for emulator-linked games — **File** (basename) and **Path** (full `romPath`, link-styled; tap opens **Finder** via `NSWorkspace.activateFileViewerSelecting`; orange **Not present** when the file is missing, with a **Download From ROMM** button underneath for ROMM games — see **ROMM**); for **Mac** entries with no emulator — editable game path + **Choose Game…**.
- **ROMM** (only when `rommStatus` is set, i.e. the game's emulator is linked to a ROMM platform): **Status** (**In ROMM** green / **Missing** orange) and **ROMM path** (the server's `full_path`, link-styled; opens `<server>/rom/<id>` in the browser).
- **Launch with** (emulator-linked games only): a menu of emulator profiles. The default is the game's library emulator; picking another stores `LibraryGame.launchEmulatorIDString`, and `RootView.launch` passes that profile to `GameLauncher.launch(game:launchEmulator:)`. The game stays in its library section and keeps its ROMM link; scans don't touch the override. A deleted override profile falls back to the default.
- **Multi-disc set:** link with suggestions or **Link with other discs…** sheet (`DiscGroupLinkSheet`); list linked discs with ▲/▼ reorder; **Reset order from filenames**; **Unlink this disc**. Linked discs share cover art and ScreenScraper `gameid`/`systemeid`; changes propagate via `DiscGroupService.propagateSharedState`.
- Cover art: choose file, **Search for Covers** across configured providers (title drops trailing `(USA)` / `(Disc 1)` tags; **Platform** defaults from the emulator profile), reorder detected covers, set primary, clear. Inspector preview uses the same per-emulator crop as the grid.

Grid tiles show a **Disc N** badge when the game is in a linked set and a disc number is parsed from the path/title.

**Key types:** `RootView.swift`, `LibraryGame.swift`, `CoverAspectRatio.swift`, `DiscGroupService.swift`, `DiscGroupLinkSheet.swift`.

---

## Emulators tab

- Add/configure `EmulatorProfile`: executable path, GBear-style `{ImagePath}` / `{rom}` template, optional per-emulator ROM extensions.
- **Cover art size** — picker on create and edit (`CoverAspectRatio`): **2:3 (SteamGridDB)**, **4:3 (SNES)**, **1:1 (GBA, PSX)**, **3:4 (PS2, GC, WII, NES)**, **8:7 (NDS, 3DS)**, **3:5 (PSP, SWITCH)**, **16:9 (Screen / Banner)**. Stored as `coverAspectRatioRaw` (default `"2:3"` for SwiftData migration). Catalog/custom row fill infers a starting ratio from platforms/name; the user can change it before Add / Save.
- **Platform** — picker on create and edit (`screenScraperSystemId`, same ScreenScraper console list as manual cover search). Catalog/custom row fill infers a starting console; **Not set** falls back to catalog/name inference. Stored id is used for scrape `systemeid` and as the default **Platform** in inspector **Search for Covers**.
- **`{user_name}`** expands to the current macOS account short name at launch (for paths under `/Users/{user_name}/Library/...`). Leading **`~`** in an argv token is expanded. Absolute home paths in stored templates are normalized to `/Users/{user_name}/...` on save/startup (`LaunchArgumentTemplate`).
- Export/import configured profiles (optional `coverAspectRatioRaw` and `screenScraperSystemId`; older JSON keeps the current values on conflict overwrite). Bundled catalog + custom launch-argument presets live in `BuiltinEmulatorCatalog` / `CustomEmulatorLibraryStore`.
- **PS2:** catalog preset **ARMSX2** (`emulatorId: armsx2`); default startup **`-fastboot -- "{ImagePath}"`**. **AetherSX2** is not in the catalog; startup may retarget existing `AetherSX2.app` profiles to `/Applications/ARMSX2.app`.
- **Add emulator:** choosing a catalog/custom row fills launch args, file types, a starting **platform**, and a starting **cover art size**; **display name** is filled only when that field is empty.
- **App Sandbox is off** for the Mac app (`GBear.entitlements`). Sandboxed callers cannot pass `NSWorkspace.OpenConfiguration.arguments` (system ignores them).

**Key types:** `EmulatorsView.swift`, `EmulatorProfile.swift`, `CoverAspectRatio.swift`, `ScreenScraperPlatformPicker.swift`, `LaunchArgumentTemplate.swift`, `BuiltinEmulatorCatalog.json`.

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

- **Provider order:** **ScreenScraper API v2** (`https://api.screenscraper.fr/api2/…`) when the user is signed in, then **IGDB** (`https://api.igdb.com/v4/games`), then **TheGamesDB** (`https://api.thegamesdb.net/v1.1/Games/ByGameName`, `include=boxart`) dead last because its monthly allowance is small. `CoverProvider.allCases` is the canonical order. Each backup runs only when the one before it produced no cover (or ScreenScraper was skipped because the user is not signed in), and only when its key is saved. A ScreenScraper disambiguation prompt is left for the user; the backups do not answer it.
- **Credentials:** `MetadataCredentials` — `devid` / `devpassword` required; `ssid` / `sspassword` optional. Persisted in `UserDefaults` (see `docs/metadata-setup.md`). TheGamesDB uses the key the user pastes on Screen Scrapper (`MetadataCredentials.theGamesDBAPIKey`). IGDB uses the user's Twitch application Client ID + Client Secret (`igdbClientID` / `igdbClientSecret`); **Save keys** asks Twitch for a token to confirm them. With no key saved, that provider is skipped.
- **TheGamesDB backup** (`TheGamesDBClient`, hooked from `MetadataBackgroundFetcher.fetchAndSave`): name search on the emulator platform (`TheGamesDBPlatformMap`, including Genesis + Mega Drive). The search string prefers a clean title over a longer dump filename (`Yonder_The_Cloud_…__0100…__v0` loses to **Yonder The Cloud Catcher Chronicles**; underscores and Switch title ids are normalized in `RomTitleNormalizer`). Front box art only, and only when `pickTitleIsCompatible` accepts the title. Covers are chosen with the Screen Scrapper **Region priority** list: TheGamesDB regions map to `us` / `eu` / `wor` / `jp` / `kr` / `au`, and the first region in that list that has a front cover wins. If the full name has no cover, one follow-up search uses the title through the sequel number (`Fullmetal Alchemist 3 The Girl Who Succeeds God` → `Fullmetal Alchemist 3`) so a later region (Japan, when US, Europe, and World are empty) can still supply the box. That follow-up does not rename the library title. No ROM hash lookup. A miss sets `LibraryGame.theGamesDBCheckedAt` so the background pass does not spend the monthly allowance again; **Scrape library** retries. HTTP 403 stops further TheGamesDB calls for that batch. Downloaded art uses the same `CoverImageCache` path, so **Only Scan Missing** skips it. `remoteCoverSource` is `screenscraper`, `thegamesdb`, or `igdb`. ScreenScraper game ids are not filled from the backups.
- **IGDB backup** (`IGDBClient`, `IGDBPlatformMap`): `IGDBTokenStore` caches the Twitch app access token (`https://id.twitch.tv/oauth2/token`, `client_credentials`) until shortly before expiry; a 401 clears it and retries once. Search is `search "…"; where platforms = (…)` with `cover.image_id`, `alternative_names`, and `game_localizations` (region + cover). A game matches on its name, an alternative name, or a regional name; only a main-name match may rename the library title. Both backups use `MetadataService.backupTitleMatches` (stricter than ScreenScraper's check): the shorter title's words must all be in the longer one, and a one-word title must match exactly, so `Off the Game` no longer takes `Olympic Games Tokyo 2020`. Cover choice: a regional cover wins only when its region is first in **Region priority**, otherwise the main cover, otherwise the best-ranked regional cover. Images use `t_cover_big_2x`. Same sequel-number follow-up search as TheGamesDB. Misses set `LibraryGame.igdbCheckedAt`. A rejected Client ID / Secret stops IGDB for the rest of that batch. Limit is 4 requests per second; a 429 waits one second and retries once.
- **Matching waterfall** (`MetadataService`, per game):
  1. Pinned `screenScraperGameId` + `screenScraperSystemId` on `LibraryGame` (if set).
  2. **`jeuInfos.php`** hash lookup (`RomFingerprint`: MD5/CRC32/SHA1, `.cue`/`.m3u` payload, PS3 folder `dossier`) — requires resolved **`systemeid`**.
  3. **`jeuInfos.php`** exact filename (`romnom` + size + `romtype`).
  4. **`jeuRecherche.php`** fuzzy search with query variants (`RomTitleNormalizer`, `.hack` `//` forms, roman → arabic numerals).
  5. Auto-select from ambiguous set (user toggle) or `ScreenScraperDisambiguationCoordinator` sheet.
- **Platform resolution** before scrape: stored `EmulatorProfile.screenScraperSystemId` if set; else `EmulatorProfileLookup` → `EmulatorPlatformResolver` (catalog/name); fallback `MetadataSystemResolver` (`platformHint`, Epic → PC **135**); fallback **`RomPathPlatformResolver`** (longest matching **Paths** game-folder root). Scrape logs include `emulatorSystemeid=`.
- **Region priority:** Screen Scrapper **Region priority** list (`MetadataCredentials.screenScraperRegionPriority`) ranks ScreenScraper locales. Cover and title picks walk that order (optional filename/manual-search region is tried first). Default rank is US → Europe → World → Japan → France → Germany → Spain → Korea, then Italy / Portugal / Australia / ScreenScraper default. Older single **PreferredRegion** values migrate to the top of the list.
- **Manual search** (`CoverSearchSheet`, inspector **Search for Covers…**; also **Search manually…** in the disambiguation sheet): searches every provider in `CoverProvider.configured` at once. That is ScreenScraper when the build has dev credentials, IGDB with user keys, and TheGamesDB with a user key (sections appear in that order); unconfigured providers are skipped and the button hides when none are set up. It pre-fills the emulator’s platform and strips dump tags from the title (`Vandal Hearts II (USA)` → `Vandal Hearts II`; `Off the Game [0100F5201B452000][v0] (1.33 GB)` → `Off the Game`) because ScreenScraper `jeuRecherche` misses region/title-ID/size suffixes. The platform picker's ScreenScraper id maps to TheGamesDB / IGDB filters via `screenScraperSystemId`, and **Any platform** drops the filter. The cover region picker boosts one locale, then the rest of the priority list. TheGamesDB hits are sorted by that order, and IGDB picks a regional cover with it. Results are grouped per provider with console and region labels, with no strict title filter (`TheGamesDBClient.searchCoverList`, `IGDBClient.searchCoverList`). Picking a ScreenScraper hit goes through `ScreenScraperDisambiguationCoordinator.applySelection` (pins the game id). Picking a backup hit caches the cover, makes it primary, sets `remoteCoverSource`, and renames only when `backupTitleMatches`.
- **Title safety:** `pickTitleIsCompatible` blocks wrong-platform fuzzy picks; Part/Vol numbers optional when subtitle matches (`.hack Part 1` ↔ `.hack//Infection`). Scraped title applied only when compatible (hash/exact always apply).
- **Background fetcher:** `MetadataBackgroundFetcher` — periodic batches; **schedule extra** after scans; full library scrape from Screen Scrapper sidebar (`scrapeAllNow`). **Only Scan Missing** (default on) filters that full scrape to games that already have scraped covers (`LibraryGame.hasScreenScraperCover`, including TheGamesDB art in the cover cache). Session logs: `gbear-scrape-*.log` in Downloads. The header lists `fallbackOrder=`. The footer has a **Cover provider usage** block from `MetadataBackgroundFetcher.ProviderUsage` (`ScrapeSummary.usage`): one `usage provider=…` line per provider with `configured`, `searched`, `covers`, `no_match`, `errors`, `skipped` (no platform mapping, not signed in, or paused after quota / rejected keys), ScreenScraper `ambiguous`, TheGamesDB `requests` and `remaining_monthly_allowance`, then a `covers_by_provider` total line. **`clearAllScrapedMetadata`** wipes covers, ScreenScraper IDs, TheGamesDB / IGDB check timestamps, and the disambiguation queue.
- **Covers:** `CoverImageCache` disk cache; validates decoded `NSImage` before save. Local folder discovery first; remote appended to `coverImageOptions`; primary respects `preferScreenScraperCovers`. **Library crop** is per-emulator (`CoverAspectRatio`); files on disk are not rewritten. **Multi-disc:** cover + ScreenScraper IDs propagate to siblings in the same `discGroupIDString`.

**Key types:** `MetadataService.swift`, `ScreenScraperClient.swift`, `TheGamesDBClient.swift`, `TheGamesDBPlatformMap.swift`, `IGDBClient.swift`, `IGDBPlatformMap.swift`, `RomFingerprint.swift`, `RomTitleNormalizer.swift`, `MetadataSystemResolver.swift`, `RomPathPlatformResolver.swift`, `MetadataBackgroundFetcher.swift`, `ScreenScraperLibraryView.swift`, `ScreenScraperRegionPriorityList.swift`, `ScreenScraperDisambiguationCoordinator.swift`, `CoverImageCache.swift`.

---

## Epic Games (installed only, no OAuth in-app)

- **Import:** `EpicInstalledGamesImporter` reads Epic launcher manifests under `~/Library/Application Support/Epic/.../Manifests`.
- **Model:** `LibraryGame.librarySourceID` (`"epic"`), `epicAppName` for launcher URI.
- **Launch:** `GameLauncher` — if `epicAppName` is set, tries `com.epicgames.launcher://apps/...` before falling back to direct path.

**Key types:** `EpicInstalledGamesImporter.swift`, `GameLauncher.swift`.

---

## ROMM

- **Connection** (`RommCredentials`, `RommClient`): server address and username in `UserDefaults` (`ROMM.ServerURL`, `ROMM.Username`; `http://` is assumed without a scheme), password in the Keychain (`KeychainStore`, service `com.gbear.romm`). Every request uses HTTP Basic auth. **Connect** calls `GET /api/heartbeat` (server version) and `GET /api/platforms`.
- **Platform links** (`RommSync.links`, `UserDefaults` `ROMM.PlatformLinks`, ROMM platform id → `EmulatorProfile.id`): one emulator menu per ROMM platform in the pane.
- **Sync** (`RommSync.sync`; **Sync Now** in the pane and at the end of **Scan Paths**), per linked platform:
  - Fetch `GET /api/roms?platform_ids=…&platform_id=…` in pages of 1000 (ROMM 4 only honours `platform_ids`; older servers `platform_id`) and drop roms whose `platform_id` differs.
  - **Filter** (`RommSync.isGame`): skip hidden files or anything under a hidden folder (`.DS_Store`, `._` AppleDouble), `Thumbs.db` / `desktop.ini`, non-game extensions (text, images, audio/video, xml/dat/db, saves, checksums), and single files whose extension is not in the linked emulator's supported file types (when it has any). Multi-file games (folders) pass. Filtered entries are not matched, added, or counted (`Summary.ignoredFiles`).
  - **Name match** (`RommSync.matchKey`): drop `(…)` / `[…]` tags, fold accents, `&` → and, roman numerals II–X → digits, drop the/a/an/and, then compare the sorted words. A local game matches on its file stem, title, or library name against ROMM's `fs_name_no_tags` or `name`, so "Legend of Zelda, The - The Wind Waker (USA)" matches "The Legend of Zelda: The Wind Waker".
  - Matched games get `rommStatus = in_romm`, `rommRomID`, `rommPath`, `rommFileName`, `rommHasMultipleFiles`; unmatched local games get `missing`.
  - **ROMM-only games** — only when **Add games to library that are not on this Mac** is checked (next to **Sync Now**; `ROMM.AddGamesNotOnMac`, **off by default**; with it off, sync deletes not-downloaded ROMM-only rows) — become rows with `rommImported = true`, ROMM's cover, and a placeholder `romPath` (`/ROMM/<platform fs_slug>/<fs_name>`), so the inspector shows **Path: Not present**. Blocked as `romm/<id>`, so **Remove from Library** keeps them out.
  - ROMM-only rows whose ROMM game is gone are deleted. Unlinking an emulator clears its ROMM fields and removes its not-downloaded ROMM-only rows. If the user copies the file into a game folder themselves, Scan Paths adds it and the next sync drops the duplicate ROMM-only row.
- **Clear Sync** (`RommSync.clearSync`, with a confirmation): deletes rows with `rommImported == true` whose file is not present and clears every ROMM field on all other games. Downloaded games (file present) stay; no files are touched; login, platform links, and the blocked list are kept.
- **Download** (`RootView.downloadFromROMM` → `RommSync.download(_:into:modelContext:)`): from **Download From ROMM** under Path, or from **Play** when `needsROMMDownload` (in ROMM, file not present; Play launches after the download).
  - The destination is the emulator's **game folder** from Paths (`RommSync.downloadFolders`). If there are several, a confirmation dialog lists them. With none, the user is told to add one. An unmounted folder fails with a message.
  - `RommClient.download` fetches `GET /api/roms/{id}/content/{fs_name}` to a temp file. Single files are moved to `<folder>/<fs_name>`; multi-file games arrive as a zip and are extracted with `ditto -x -k` into `<folder>/<fs_name>/` (one game folder, like the scanner expects).
  - The row's `romPath` becomes the real path and `rommImported` is cleared, so it is an ordinary local game from then on (still **In ROMM** after sync). A spinner shows on the tile and in the inspector while downloading.
- **Scanner:** `GamePathScanner` never prunes `rommImported` rows for a missing file or as a cue sidecar track.

**Key types:** `RommClient.swift`, `RommSync.swift`, `RommSettingsView.swift`, `KeychainStore.swift`.

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
- **`GBearVirtualGamepadManager`** — IOHIDUserDevice pads named **GBear Virtual Pad N**, created only for **occupied** seats. Without the Virtual HID entitlement every create fails, so remote seats fall back to **`GBearKeyboardPadStandIn`**.
- **`GBearKeyboardPadStandIn`** — presses keys for a remote player's pad (needs Accessibility). Events use the hardware key source (`hidSystemState`), so they still land after `GameLauncher` hides GBear and so in-game polling sees the key as held (BJ-097). The host binds them as that player in the emulator by clicking each slot while the friend presses the button. Map: A/B/X/Y = keypad 1/3/7/9, L1/R1 = keypad ÷/×, L2/R2 = keypad −/+, L3/R3 = keypad 0/5, Start = keypad Enter, Select = keypad ., Guide = keypad =, D-pad = keypad 8/2/4/6, left stick = F13 up / F16 down / F17 left / F18 right, right stick = F19 up / F20 down / F14 left / F15 right. Sticks and triggers are on/off (press above 0.5, release below 0.35). Only works well for one remote player; the host's own controller stays a normal controller in the emulator. The control list, labels, and keys live in **`GBearPadControl`** so the stand-in and the **Controller map** panel always agree.
- **Controller map** (`ControllerReceiverMapView`) — button left of **Move to** on each occupied player in **Players**. Popover in the companion mapper's row style: control name (companion labels), what it maps to on this Mac (**Sends Keypad 1**, **GBear Virtual Pad N**, or read directly for the host's own pad), and a live **Pressed** / percent badge with the row highlighted. Header shows **Receiving** / last-signal age. Fed by **`GBearPadInputMonitor`** (`@MainActor`), which `GBearVirtualGamepadManager.apply` / `applyToSeat` update per `GBG1` event; cleared when a seat empties.
- **`GBearHostLocalGamepad`** — host GCController → assigned virtual pad. Yields the controllers while this Mac is a guest (`yieldToGuestSender`), so `GBearGuestGamepadSender` keeps sending to the other host (BJ-096).
- **`GBearStreamGuestManager`** — another Mac pairs as `computerGuest`, receives video/audio, sends local pads as GBG1.
- **`windows-guest/`** — Windows couch-co-op app (`GBearGuest.exe`). **Join** is a `computerGuest` (TCP `GBV1` / `GBA1`, UDP `GBG1` from XInput, keyboard fallback). **Host this PC** is the same control ports as the Mac host so a Mac can **Join another computer**: DXGI capture, Media Foundation H.264 (capped at 1280×720), WASAPI loopback, and a ViGEm Xbox pad per remote seat (seat 1 stays the physical Windows controller). ViGEmBus must be installed on that PC for the remote pad. Direct IP only (LAN or a VPN such as Tailscale). The phone invite relay is not used.
- **`GBearRemoteCoopHost` / `GBearLocalRelayServer`** — two Macs on different networks. The host starts a localhost relay and an outbound Cloudflare tunnel, then copies a `GBEAR1` invite line. The guest redeems it and both sides exchange `GBTL` over WebSocket (video, audio, `GBG1`). No port forwarding. The relay is two sockets (host + one friend). The WebSocket is not on a 30s receive timeout. While the session is up the process stays awake, so launching a game (which hides GBear) does not suspend the relay. If a socket drops, that side reconnects; controller frames are never shed when video backs up (BJ-097). LAN **Join another computer** is unchanged. Capture for this path is **1280×720 @ 30fps** with `GBearVideoTuning.relay`: High profile without B-frames, a keyframe every 3s, and bursts up to 1.5× the average so busy scenes keep detail. **`GBearRelayBitrateController`** sets the average: it starts at 6 Mbit/s and moves between 2 and 12. The host sends a `ping` on the control channel every second and the guest answers with `pong`. If the round trip grows past the baseline, video is queueing, so the rate drops. It climbs again after a stable stretch. A guest that never answers pings is capped at 8. Video is never dropped as single frames: once the host send pump or the relay sheds one, both skip until the next keyframe and ask for a fresh one, and the relay sends the host `congestion` (BJ-098). The host Streaming screen shows **Picture: X Mbit/s** under the session status.
- **`GBearGuestVideoWindow`** — on a joining Mac (LAN or invite), the stream opens in its own resizable 16:9 window with full screen, not a sheet. `GBearStreamGuestManager.phase` opens it when streaming starts and closes it on leave or failure. Closing the window leaves the session.
- **`StreamingView`** — **Host plays on** (this Mac = Player 1 and uses a slot, so **7 devices** can join; a paired companion standing in frees the Mac slot so **8 devices** can join), Join another computer (join order by default), **Start remote co-op** / **Join with invite**, 8-slot Move-to UI, pairing for phones and computers.

### macOS permissions

| Permission | Purpose | UI name |
|------------|---------|---------|
| **Screen Recording** | Desktop video + system audio capture | GBear |
| **Accessibility** | Synthetic mouse move/click from phone touch | GBear (same list entry; not a separate “touch” item) |
| **Virtual HID** (`com.apple.developer.hid.virtual.device`) | Up to 8 co-op virtual gamepads | **Not granted.** Restricted entitlement that Apple must approve; it is not in `GBear.entitlements`, so pad creation fails and emulators see no **GBear Virtual Pad** (BJ-095). |

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

- **`EmulatorProfile`** — name, paths, launch template, extensions, `preferScreenScraperCovers`, `autoLinkMultiDiscGames` (both default `false` for migration), `coverAspectRatioRaw` (default `"2:3"`), `screenScraperSystemId` (optional ScreenScraper console).
- **`LibraryGame`** — title, `libraryDisplayName`, `romPath`, optional emulator link (`emulatorIDString` + relationship), cover URLs/options JSON, `platformHint`, `screenScraperGameId` / `screenScraperSystemId`, `screenScraperSelectionSkipped`, `discGroupIDString`, `discGroupOrder`, `librarySourceID`, `epicAppName`, `storefrontGameID`, `storefrontInstalled`, ROMM link (`rommStatus`, `rommRomID`, `rommPath`, `rommFileName`, `rommHasMultipleFiles`, `rommImported`), `launchEmulatorIDString` (per-game Launch with override), `sortOrder`, play/metadata timestamps.
- **`GameFolderPath`** — folder path, purpose (games / covers / excludes), linked emulator.

---

## Help menu (app target)

- Replaces default Help group with topic buttons (RetroArch, RPCS3, orphan cleanup, **Games missing after scan**, **ROMM**, **Keystrokes permission**). Implemented in `GBear.swift`.

---

## Known constraints / pitfalls

- **App Sandbox vs launch argv:** Keeping `com.apple.security.app-sandbox` on strips `NSWorkspace.OpenConfiguration.arguments`. Emulator launch requires an unsandboxed Mac app (current `GBear.entitlements`).
- **ARMSX2 / PCSX2 CLI:** Prefer **`-fastboot -- "{ImagePath}"`**. A bare `--` before the ISO is required when the path can confuse option parsing. **`-batch -fullscreen`** often produced a gray GS window even when the ISO did boot (check `~/Library/Application Support/ARMSX2/logs/emulog.txt` for `isoFile open ok` / ELF load).
- **Already-running ARMSX2:** `open -a … --args` without quitting first only activates the existing game-list window and does not apply new argv — `GameLauncher` terminates instances before CLI launch.
- **RPCS3 `dev_hdd0/game`:** Assign the folder to the **RPCS3** emulator profile (not a generic multi-system profile) so folder import and ISO-only file rules apply. After scanner fixes, run **Scan Paths** to rename stale **EBOOT** entries. PSN/HDD (**HG**) installs need `USRDIR/EBOOT.BIN`; disc **GD** data folders without EBOOT are not launchable from this path alone.
- **ScreenScraper** quotas, threading, and API shape can change. Without resolved **`systemeid`**, hash lookup is skipped and fuzzy search may pick wrong consoles (DS/Xbox/NES) or return `no_match`. Run **Scan Paths** so `RomPathPlatformResolver` can infer platform from folder roots; check scrape log for `emulatorSystemeid=nil`.
- **Multi-disc auto-link** uses normalized base titles — enable per emulator on **Paths**; manual link/unlink still available in inspector.
- **SwiftData migration:** new non-optional attributes need defaults or optional types; a prior crash on `preferScreenScraperCovers` was fixed with `= false` on the property. `coverAspectRatioRaw` defaults to `"2:3"`. `screenScraperSystemId` is optional (`nil` = infer).
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

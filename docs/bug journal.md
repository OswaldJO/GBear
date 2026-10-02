# Bug journal

Chronicle of bugs encountered in **GBear Mac** and the **companion app**, and how they were fixed. Entries are grouped by area; dates come from git commits unless noted as **in progress** (not yet committed).

For release notes style summaries, see `source control log.md`. For architecture context, see `Features and Inner Workings.md`.

---

## Mac library — scanning & covers

### BJ-127 — Controller couldn't answer RPCS3's quit confirmation
| | |
|---|---|
| **When** | Oct 1 2026 (**in progress**) |
| **Symptom** | Holding Select + Start in an RPCS3 game sent ⌘Q, and RPCS3 asked "A game is currently running. Do you really want to close RPCS3?" (No / Yes), but nothing on the controller could answer it. |
| **Cause** | Controller navigation only drives GBear's own windows; the dialog belongs to RPCS3, and while another app is in front the navigator only watched for the Select + Start / Start + R1 combos. |
| **Fix** | `ControllerDialogNavigator`: after ⌘Q it watches the app for 60 s, finds a confirmation dialog in its focused window through Accessibility, outlines its buttons with a click-through `HighlightWindow`, and `checkQuitDialog` maps D-pad / Cross / Circle / Triangle to move / `AXPress` / cancel. A second Select + Start hold on the same still-running app force quits it, and GBear now waits up to 60 s (was 10 s) for the app to exit before coming back to the front. |
| **Commit** | *in progress* |

### BJ-126 — Covers "fell" into view when the controller scrolled the grid
| | |
|---|---|
| **When** | Oct 1 2026 (**in progress**) |
| **Symptom** | Moving down the covers with the D-pad, covers in a row coming into view slid / jumped into place for a few frames instead of scrolling in like trackpad scrolling. Most reliable repro: scroll to the bottom, race back to the top, then D-pad down; it kicked in around the 10th–12th cover (at "Bug Too!" on the second descent). Also seen after toggling the sidebar with L3. |
| **Cause** | Main cause, found frame by frame in a screen recording: only the **newly selected** cover fell. Going down column 1, Chameleon Twist was first drawn on top of Baten Kaitos two rows up and slid down to its row over ~3 frames; on the next press Chrono Cross did the same. `GameLibraryTile` animated the ring's scale pop with `.animation(.easeOut(duration: 0.12), value: controllerRing)` over the whole cover, so the update that lit the ring also animated the cover's **position**. When `LazyVGrid` had just created that row at an estimated offset (estimates go stale after racing to the bottom and back, or after L3 changes the column count) and then re-placed it, the cover glided from the guess to its real row. Contributing: `CachedCoverThumbnail` had no in-memory cache, so recreated tiles first drew a default-height placeholder and resized once the file loaded. |
| **Fix** | The pop now uses the scoped `.animation(_:body:)`, which animates only the `scaleEffect` inside it, never the cover's frame. Earlier passes, still in place: `CoverImageCache.image(for:)` keeps loaded covers in an `NSCache` (600 entries); `CachedCoverThumbnail` seeds its `@State` image from it in `init`, and `GameLibraryTile.coverSize` uses the cached image's size, so a recreated tile draws at its final size on its first frame. Tiles also drop inherited animations (`.transaction { $0.animation = nil }`), which didn't help on its own because the value-based animation sat inside the tile. |
| **Commit** | *in progress* |

### BJ-125 — Controller didn't navigate the library at all
| | |
|---|---|
| **When** | Oct 1 2026 (**in progress**) |
| **Symptom** | With a DualSense already connected over Bluetooth, the new controller navigation did nothing in the library, even with GBear frontmost. |
| **Cause** | `LibraryControllerNavigator` refused input whenever `GBearHostLocalGamepad.isActive` was true. The stream host seats this Mac as local co-op player 1 by default (`syncSessionDevices`), so that flag is on as soon as the host starts, with no stream running. The log showed `active (1 controller(s))` immediately followed by `blocked: local co-op owns the controllers`. |
| **Fix** | Gate on `GBearStreamHostManager.isVideoStreaming` (a stream is actually running) instead of the local co-op flag. The frontmost-app, key-window, sheet and guest-stream checks are unchanged. Each change in gate state is now logged via `DebugLog`. |
| **Commit** | *in progress* |

### BJ-124 — Roman-numeral sequels sorted after numbered ones
| | |
|---|---|
| **When** | Oct 1 2026 (**in progress**) |
| **Symptom** | The library showed **Clock Tower**, **Clock Tower 3**, then **Clock Tower II** instead of putting II before 3. |
| **Cause** | `DiscGroupService.librarySort` compared titles with `localizedStandardCompare`, which treats digit runs as numbers but Roman numerals as letters, so "II" sorted after every digit. |
| **Fix** | `DiscGroupService.sortTitle` builds a sort-only title that turns standalone uppercase Roman numerals 1–39 (I, V, X letters; not the first word; a lone `I` only before the end or punctuation) into digits. Displayed titles are unchanged. A title ending in a letter-style `X` (e.g. **Mega Man X**) would sort as 10, so the inspector shows **Ignore Roman numerals when sorting** (`LibraryGame.ignoresRomanNumeralsInSort`) for any title the conversion changes; `sortTitle(for:)` then uses the title as written. |
| **Commit** | *in progress* |

### BJ-123 — Unreal Engine / Fab assets imported as Epic games
| | |
|---|---|
| **When** | Oct 1 2026 (**in progress**) |
| **Symptom** | After signing in to Epic, the library filled with non-games such as **4K Materials: Wood Flooring Vol.01**, **Advanced Cel Shader Lite** and **Advanced Glass Material Pack**, all without covers. |
| **Cause** | Epic's library service also lists Unreal Engine marketplace / Fab purchases. `EpicClient` skipped only the `ue` namespace and the `addons` / `engines` / `digitalextras` categories, but Fab items live in their own namespaces and are tagged `plugins`, `asset-format/…`, `type/format-item` and similar. Rows already in the library also skipped the catalog check entirely. |
| **Fix** | Skip private-sandbox records (as Legendary does) and treat catalog categories starting with `assets`, `asset-format`, `plugins`, `projects` or `type/format-item` as non-games too. Rejected app names are remembered and excluded from the owned set, so the importer deletes their rows. `gameFilterVersion` 2 re-checks every Epic item once, which cleans up rows imported before the fix. |
| **Commit** | *in progress* |

### BJ-122 — Steam sign-in "expired" minutes after signing in
| | |
|---|---|
| **When** | Oct 1 2026 (**in progress**) |
| **Symptom** | Right after signing in to Steam with the new native sign-in, **Import** failed with "Steam: Steam sign-in expired. Sign in again." |
| **Cause** | `SteamAuth` asked for **WebBrowser** tokens. The refresh token was valid for 211 more days, but Steam answers `GenerateAccessTokenForApp` for WebBrowser tokens with `AccessDenied` (EResult 15); only MobileApp tokens can be renewed that way over the Web API. The access token from sign-in was not saved, so the first import already needed a renewal, and every renewal failure was reported as "expired". |
| **Fix** | Sign in as **MobileApp** (`platform_type` 3, `website_id` Mobile, device details), save the access token and reuse it until 5 minutes before it expires, renew with `renewal_type` 1, and report AccessDenied as "sign in again (older sign-ins can't be renewed)" instead of "expired". Existing sign-ins need one more sign-in. |
| **Commit** | *in progress* |

### BJ-121 — GOG "Continue with Google" button did nothing
| | |
|---|---|
| **When** | Oct 1 2026 (**in progress**) |
| **Symptom** | In **Sign in to GOG**, tapping **Google** (or Steam / Discord / Xbox) under the email and password fields did nothing. |
| **Cause** | Those buttons open a pop-up window (`window.open`). `StorefrontLoginWebView` had no `WKUIDelegate`, and WebKit silently drops pop-ups without one. |
| **Fix** | The web view is now hosted in a container and its coordinator is the `WKUIDelegate`: `createWebViewWith` builds the pop-up with WebKit's configuration (keeps `window.opener`), stacks it over the sign-in page, and removes it on `webViewDidClose`. The pop-up shares the navigation delegate, so the GOG code is caught in either window. Google may still refuse embedded sign-in, so GOG now also has the **Trouble signing in?** fallback: sign in in the browser and paste the `on_login_success` address (`GOGClient.authorizationCode(fromPastedText:)`). |
| **Commit** | *in progress* |

### BJ-120 — Library covers looked zoomed in and cropped
| | |
|---|---|
| **When** | Oct 1 2026 (**in progress**) |
| **Symptom** | Many tiles in the library grid (for example **Costume Quest**, **Clock Tower 3**) cut off the top, bottom or sides of the box art. |
| **Cause** | `GameLibraryTile` drew `CachedCoverThumbnail` with its default `.fill` mode inside a fixed slot (card width × the emulator's cover aspect, default 2:3) and clipped it, so any cover whose shape didn't match the setting got zoomed in to fill the slot. |
| **Fix** | The tile uses `.fit` and applies the clip, border, badges and Play/Info overlay to the fitted image. A first pass bottom-aligned covers inside the old fixed slot, which broke top alignment and left large gaps in mixed-emulator rows; the tile is now sized from the image's own shape (card width, capped at the emulator's cover height), tiles top-align in each row, and titles no longer reserve 3 lines, so rows are only as tall as their tallest tile. |
| **Commit** | *in progress* |

### BJ-119 — Same cover listed several times under Detected covers
| | |
|---|---|
| **When** | Oct 1 2026 (**in progress**) |
| **Symptom** | Games such as **A Short Hike**, **Gris** and **Super Mario Odyssey** listed the same box art three or four times in the inspector's Detected covers. The cover cache held 881 files for about 263 games, with groups of 4–6 byte-identical images. |
| **Cause** | `CoverImageCache` named each download by a hash of its full address. ScreenScraper media addresses carry the dev and user credentials and come from rotating mirror hosts, so the same image came back under a new address after signing in or on another scrape, got a new file, and was appended to the game's cover list as a new option. Separately, the "already downloaded" check looked for `<hash>.php` while ScreenScraper images were saved as `<hash>.jpg`, so those were downloaded again on every scrape. |
| **Fix** | Downloads are named by a hash of their bytes, with `index.json` mapping a normalized address (no mirror host or credential parameters) to the file; older address-named files are still found. `mergeDuplicateCoversOnce` runs once at launch: it groups cache files by content, rewrites every game's primary cover and cover list to one copy (the list setter drops the repeats), remaps the index, and deletes the extra files. |
| **Commit** | *in progress* |

### BJ-118 — ScreenScraper showed 510 requests after one manual scrape
| | |
|---|---|
| **When** | Oct 1 2026 (**in progress**) |
| **Symptom** | A **Scrape library** run for one game reported `used_today=510/20000` for ScreenScraper, though the user had only scraped once that day. |
| **Cause** | `MetadataBackgroundFetcher.runLoop` ran every 45 s and fetched 3 games whose `metadataLastFetchAt` was over 24 h old, covers or not, so the whole library (~263 games) was re-checked through ScreenScraper every day while signed in. `scheduleExtraPass` added more after scans, ROMM syncs, storefront imports and link changes. Those passes wrote no scrape log. ScreenScraper's counter also runs from midnight Paris time (3 PM Pacific), so "today" included the afternoon before. |
| **Fix** | Removed the background loop, `scheduleExtraPass`, `startIfNeeded`, the unused `scrapeAllNow`, and the "waiting for background pass" UI. Cover providers are called from **Scrape library**, **Search for Covers…**, and `scrapeNewGames` after a scan, ROMM sync or storefront import adds games. That pass only takes games never looked up and without a cover, applies a cover file found beside the game first, and writes its own log. The usage line and Manage Providers now say "used this cycle" with the reset time (`used_this_cycle=` / `cycle_resets=`, `CoverProviderQuota.nextCycleReset`) instead of "today". |
| **Commit** | *in progress* |

### BJ-117 — SP(LR)ITE searched as "Spite" and found no cover
| | |
|---|---|
| **When** | Oct 1 2026 (**in progress**) |
| **Symptom** | The scrape log showed `steamgriddb_no_match title=SP(LR)ITE query=Spite`. The game is **Sp(L/R)ite**, which SteamGridDB has. |
| **Cause** | `RomTitleNormalizer.searchQuery` removed every `(...)` / `[...]` group anywhere in the title, treating `(LR)` like a dump tag such as `(USA)`. The strict backup check (`MetadataService.backupTitleMatches`) also split `Sp(L/R)ite` into `sp` + `ite`, and a Japanese subtitle on the candidate (`Sp(L/R)ite スプライト`) counted as an extra word, so even the right spelling would not have matched. |
| **Fix** | Groups wedged inside a word (letter or digit on both sides) are kept in the query; tags after a space or at the end are still removed. `RomTitleNormalizer.joiningInWordPunctuation` turns `SP(LR)ITE`, `Sp(L/R)ite` and `SpLRite` into the same word for matching. `backupTitleMatches` uses it on both sides and ignores non-Latin words in the candidate when the query is written in Latin letters. `SteamGridDBClient.searchFrontCover` retries with the joined spelling when the first search finds nothing. The query is now right (`Sp(l/r)ite`), but this game still gets no cover from SteamGridDB: its entry there is misspelled `Sprlite` (game 5436987, Steam app 2533920) and has no grids uploaded at all, so another provider (IGDB, ScreenScraper) or an upload to SteamGridDB is needed. |
| **Commit** | *in progress* |

### BJ-105 — Flycast kept ROMM duplicates after unlinking from Redream
| | |
|---|---|
| **When** | Sep 28 2026 (**in progress**) |
| **Symptom** | After unlinking Flycast and Redream, the Flycast section (default emulator, linked to ROMM's Dreamcast platform) listed "Not present" ROMM copies of games that are on the drive. Disc sets like **Resident Evil 2** and **Skies of Arcadia** showed as two games with the same name. |
| **Cause** | Unlinked, the scanner gives every file in the shared `/Volumes/PNY 512/Dreamcast` folder to Redream. `RommSync.blend` matched only Flycast's own games, found none, and added every ROMM rom as a ROMM-only row. ROMM names each disc of a set the same, so the disc rows had the same title. |
| **Fix** | `blend` also matches local files inside the ROMM-linked emulator's game folders (and its linked partners' folders) that another emulator owns. Those roms are never added as ROMM-only rows, and existing copies are deleted on the next sync. The end-of-sync cleanup skips those rows. `RommSync.displayTitle` adds ` (Disc N)` from the file name. Separate ROMM files with the same title (two versions, two regions) still show separately. |
| **Commit** | *in progress* |

### BJ-104 — Dreamcast games showed twice (Flycast ROMM copies + Redream local files)
| | |
|---|---|
| **When** | Sep 28 2026 (**in progress**) |
| **Symptom** | Dreamcast games such as **Blue Stinger** appeared under both Flycast (ROMM, Path "Not present") and Redream (the local `.chd`), even though both emulators scan `/Volumes/PNY 512/Dreamcast`. |
| **Cause** | The scanner keeps one row per file path and hands it to whichever emulator scans the folder last, so every shared local game ended up under Redream. ROMM's Dreamcast platform is linked to Flycast, and blending only matched Flycast's own games. Flycast had no local games left, so every ROMM rom became a ROMM-only row next to Redream's local copy. |
| **Fix** | Emulator linking (`EmulatorLinkService`). Linked profiles share one library section. The scanner no longer moves rows between linked emulators, and it settles unwanted rows only after every root is scanned, so a linked emulator that still wants a file keeps it. ROMM blending matches across the whole group, and the library shows each file path once per group. At first the duplicates stayed until **Scan Paths**, because linking only changed the profiles. Now every link change runs the scan and ROMM sync by itself (`refreshLibraryAfterLinkChange`). |
| **Commit** | *in progress* |

### BJ-103 — Scrapes kept calling cover providers past their API limits
| | |
|---|---|
| **When** | Sep 28 2026 (**in progress**) |
| **Symptom** | No visible limit handling: a ScreenScraper daily quota error only counted as an error, and the scrape kept sending requests for every remaining game. |
| **Cause** | ScreenScraper had no quota handling: HTTP 430 / 431 / 429 were generic errors, and `MetadataService` swallows errors and tries more queries per game. TheGamesDB's pause lasted only one batch, so the 45 s background pass and every relaunch tried again. IGDB 429 was retried once and then counted as an error. Nothing stopped a scrape, or prevented one starting, when every provider was used up. |
| **Fix** | `CoverProviderQuota` stores a per-provider block with a reset time. It is fed by ScreenScraper `ssuser` counts and 430 / 431 / 429 / 401 / 423, TheGamesDB allowance / 403 / `allowance_refresh_timer`, and IGDB repeated 429. Clients refuse requests while blocked; the fetcher skips blocked providers, stops or refuses a scrape when all are blocked, and the background pass idles. IGDB requests are spaced 260 ms apart. Limits are shown in Manage Providers → Actions and in the scrape log. |
| **Commit** | *in progress* |

### BJ-102 — ROMM games did not blend with local games (disc duplicates, messy local names)
| | |
|---|---|
| **When** | Sep 28 2026 (**in progress**) |
| **Symptom** | PS1 showed local **D (USA) (Disc 2)** next to a coverless ROMM copy **D (USA) (Disc 2).chd**, and **Chrono Cross (USA) (Disc 1)** next to a ROMM-only **Chrono Cross**. Local dump names (`… Switch NSP BASE GAME`, underscores) stayed **Missing** even though ROMM had the game under a cleaner name. |
| **Cause** | The match key removed every `(…)` tag, including `(Disc N)`, and kept one ROMM game per key. So all local discs matched ROMM's Disc 1 and Discs 2–3 were added again as not-on-this-Mac games. Unidentified ROMM games keep the file extension in `name` (`….chd`), which broke their key and title. Local scene junk and title ids stopped exact word matches. |
| **Fix** | New `RommMatcher`: exact file name, then `RomTitleNormalizer`-cleaned titles, then ROMM title contained in the local name (single candidate, no extra sequel number, extra words not another game's). Disc numbers must agree; a disc-less local game claims every disc of the set. ROMM names lose their extension for titles. Matched games without a cover take ROMM's. The next sync deletes the duplicate not-downloaded rows. |
| **Commit** | *in progress* |

### BJ-101 — ROMM sync added ~13,500 junk games (hidden files, whole server under every emulator)
| | |
|---|---|
| **When** | Sep 28 2026 (**in progress**) |
| **Symptom** | After the first ROMM **Sync Now**, the library jumped to ~13,800 games: tiles named `._.DS_Store` and `._Aery-Peace-of Mind-2.nsp` with no covers. The sync said 14,789 in ROMM although the linked platforms held about 1,000 games. |
| **Cause** | 1) `RommClient.roms` sent `platform_id`, which ROMM 4 ignores (it filters on `platform_ids`), so every linked platform returned the whole server and each emulator got every rom. 2) Nothing filtered ROMM's entries, so macOS AppleDouble / `.DS_Store` files were imported as games. 3) Games not on this Mac were always added. |
| **Fix** | The request sends `platform_ids` and `platform_id`, and roms whose `platform_id` differs are dropped. `RommSync.isGame` skips hidden files/folders, docs, images, saves and other non-game extensions, and single files the linked emulator can't open (its supported file types); they are not counted either (reported as ignored). **Add games to library that are not on this Mac** is a checkbox, **off by default**; with it off, the next sync removes not-downloaded ROMM-only rows. **Clear Sync** removes every not-downloaded ROMM game and resets all ROMM statuses. |
| **Commit** | *in progress* |

### BJ-100 — Cover search results spilled over other provider sections
| | |
|---|---|
| **When** | Sep 28 2026 (**in progress**) |
| **Symptom** | In **Search for Covers**, a loaded cover drew far larger than its card and covered the ScreenScraper section header and the result's own title (seen with *Chasm* for Switch from TheGamesDB). |
| **Cause** | `CachedCoverThumbnail` used `scaledToFill()` inside a fixed-height frame with no clipping, so a tall box-art image drew at its fill size outside the card. The same grid code was in `ScreenScraperMatchGrid`. |
| **Fix** | `CachedCoverThumbnail` takes a `contentMode`. Both result grids use `.fit` inside a 180 pt box with `.clipped()`, so the whole cover shows inside its card. Library tiles keep `.fill`. |
| **Commit** | *in progress* |

### BJ-099 — IGDB backup took the wrong game's cover and title
| | |
|---|---|
| **When** | Sep 28 2026 (**in progress**) |
| **Symptom** | *Off the Game* got the cover and title of *Olympic Games Tokyo 2020: The Official Video Game*. *Fullmetal Alchemist 3 The Girl Who Succeeds God* was renamed to the Japanese *Kami wo Tsugu Shoujo* title. |
| **Cause** | TheGamesDB / IGDB used `pickTitleIsCompatible`, which accepts nearly any title for a 3+ word query with no numbers. IGDB's fuzzy search returned the Olympic game, and the Japanese main name counted as a match, so it also replaced the library title. |
| **Fix** | `MetadataService.backupTitleMatches`: the shorter title's words (apostrophes and accents folded, roman numerals as digits) must all appear in the longer one, and a one-word title must match exactly. Used for backup picks and backup title changes. |
| **Commit** | *in progress* |

### BJ-090 — Manual ScreenScraper search missed region-tagged titles
| | |
|---|---|
| **When** | Sep 25 2026 (**in progress**) |
| **Symptom** | Inspector **Search ScreenScraper** for *Vandal Hearts II (USA)* returned no match (platform often wrong, e.g. PlayStation 2). The same title without `(USA)` on PlayStation matched. |
| **Cause** | Manual search prefilled `libraryListTitle` including No-Intro region tags. ScreenScraper `jeuRecherche` does not match those. Platform was inferred from catalog/extension overlap, not an explicit emulator console. |
| **Fix** | `EmulatorProfile.screenScraperSystemId` picker (same list as the search sheet) seeds manual search + scrape. `RomTitleNormalizer.strippingTrailingParentheticalTags` drops `[title IDs]` / `[v0]` / `(1.33 GB)` / trailing `(USA)` from the search title. |
| **Commit** | *in progress* |

### BJ-089 — Missing games stayed after Paths folder was removed
| | |
|---|---|
| **When** | Sep 25 2026 (**in progress**) |
| **Symptom** | PS1 titles from `/Users/…/Desktop/Games/PS1` remained in the library after the files were deleted and **Scan Paths**, even though Paths now only listed `/Volumes/PNY 512/PS1`. |
| **Cause** | `pruneMissingPathScannedGames` only considered games **under a current Paths root**. Rows from a removed scan folder were skipped. |
| **Fix** | Also delete emulator-linked games whose file is gone when that location is still reachable (local disk). Keep rows when `/Volumes/Name` is unmounted. |
| **Commit** | *in progress* |

### BJ-088 — Bin/cue folders imported as one game per file
| | |
|---|---|
| **When** | Sep 24 2026 (**in progress**) |
| **Symptom** | A game stored as a folder of `.bin`/`.cue` (or similar) under a Paths game folder appeared as many library tiles, one per file. |
| **Cause** | `GamePathScanner` walked every matching file recursively under the scan root. |
| **Fix** | Scan only **immediate** children: files and subfolders. Each subfolder is one game; launch file is chosen inside that folder (`m3u`/`cue` before `bin`). Rescan removes leftover nested per-file rows and **cue sidecar `.bin` tracks** (`ScanSummary.removedNested`), including `(Track N)` files. |
| **Commit** | *in progress* |

### BJ-087 — Library covers locked to one crop for every emulator
| | |
|---|---|
| **When** | Sep 24 2026 (**in progress**) |
| **Symptom** | All library tiles used a single cover crop (hardcoded ~3:4 / 160×214), so N64/SNES/handheld boxes did not match box art the way a per-system frontend can. |
| **Cause** | `GameLibraryTile` used `.aspectRatio(3/4)` and a fixed height; `EmulatorProfile` had no cover-size field. Scrape stores the full image; crop was display-only and global. |
| **Fix** | `CoverAspectRatio` on each `EmulatorProfile` (`coverAspectRatioRaw`, default `"2:3"`). Picker on create/edit; catalog fill infers a starting ratio; grid/inspector height = width × (h/w). |
| **Commit** | *in progress* |

### BJ-001 — Exclude folders ignored due to path string mismatch
| | |
|---|---|
| **When** | Apr 21, 2026 (`7586490` *scan bugs*) |
| **Symptom** | ROMs under configured exclude paths were still imported, or excludes behaved inconsistently vs. Finder paths. |
| **Cause** | Exclude checks compared raw path strings without normalizing (`standardizingPath`, trailing slashes, case). |
| **Fix** | `GamePathScanner.normalizedPathForComparison()`; all exclude/root/existing-ROM lookups use normalized lowercase paths. |
| **Commit** | `7586490` |

### BJ-002 — “Ghost” library games after emulator removed
| | |
|---|---|
| **When** | Apr 21, 2026 (`1933de3` *scan bugs pt2*) |
| **Symptom** | Deleted or missing emulators left games visible in the grid; Play failed silently or behaved oddly. |
| **Cause** | `LibraryGame` rows kept stale `emulatorUUID`; filter showed all games regardless of live `EmulatorProfile` rows. |
| **Fix** | Filter library to `visibleLibraryGames` (game’s emulator must exist); startup `removeOrphanedGamesFromLibrary()` with user-facing cleanup alert; Play guards with clear `scanFeedback` when emulator reference is invalid. |
| **Commit** | `1933de3` |

### BJ-003 — Scan gave no useful feedback / games not reassigned to correct emulator
| | |
|---|---|
| **When** | Apr 21, 2026 (`7586490`, `51575dd`) |
| **Symptom** | Scan appeared to do nothing; ROMs stayed tied to wrong emulator after path changes. |
| **Cause** | Scan only returned a count; path keys didn’t match when re-scanning; limited logging. |
| **Fix** | `ScanSummary` (added / reassigned / linked covers); per-emulator scan logging; reassignment when an existing path is scanned under a different emulator; cover linking improvements in *Cover link algorithm*. |
| **Commit** | `7586490`, `51575dd` |

### BJ-004 — SwiftData crash on `preferScreenScraperCovers`
| | |
|---|---|
| **When** | Metadata / ScreenScraper work (documented in `Features and Inner Workings.md`) |
| **Symptom** | App crashed on launch or migration after adding a new non-optional model field. |
| **Cause** | New attribute without a default for existing stores. |
| **Fix** | Default `preferScreenScraperCovers = false` on `EmulatorProfile`. |
| **Commit** | (field added during ScreenScraper integration; see metadata commits ~`526b1b3`) |

### BJ-005 — Builtin emulator catalog entries “hide and reappear”
| | |
|---|---|
| **When** | Apr 20, 2026 (`46891e0` *hide and reappear*) |
| **Symptom** | Emulators or path UI state confusing after catalog regeneration / launch path changes. |
| **Cause** | Catalog JSON regeneration and `PathsView` / `GameLauncher` behavior out of sync with user expectations. |
| **Fix** | Catalog generation script + `BuiltinEmulatorCatalog` / `PathsView` / `GameLauncher` updates so hidden or path-related state is consistent. |
| **Commit** | `46891e0` |

### BJ-006 — RPCS3 `dev_hdd0/game` titles show as **EBOOT** and won’t launch
| | |
|---|---|
| **When** | Jun 9, 2026 (**in progress** — not yet committed) |
| **Symptom** | Games under `~/Library/Application Support/rpcs3/dev_hdd0/game` appeared in the library as **EBOOT** (generic placeholder, no cover/metadata); **Play** failed or did nothing. PSN/HDD titles that previously worked regressed after rescan. |
| **Cause** | (1) `shouldIncludePS3Folder` filtered on **`DG`** but PlayStation `PARAM.SFO` uses **`GD`** for disc installs — retail HDD folders were never imported via folder logic. (2) Early scans imported `USRDIR/EBOOT.BIN` as a plain `.bin` file (filename → title **EBOOT**); later folder-aware rescans hit the same normalized path in `existingPaths` and **skipped without updating the title**. (3) File enumerator did not pre-request `.isDirectoryKey`, making PS3 title-folder detection less reliable on some systems. |
| **Fix** | `GamePathScanner`: category filter **`GD` \| `HG`**; on PS3 folder match for an existing `EBOOT.BIN` path, refresh `LibraryGame.title` from `PARAM.SFO`; include `.isDirectoryKey` in scan enumerator `includingPropertiesForKeys`. User action: assign `dev_hdd0/game` to RPCS3 profile, rebuild, **Scan Paths**. |
| **Commit** | (pending) |

### BJ-007 — ScreenScraper scrape with `emulatorSystemeid=nil` (wrong/missing covers)
| | |
|---|---|
| **When** | Jun 9, 2026 (**in progress**) |
| **Symptom** | Most games in scrape logs show `emulatorSystemeid=nil`; hash lookup never runs; fuzzy search picks wrong platform (e.g. Prince of Persia → DS, Obscure → Xbox, FF IX → NES) or `no_match`. |
| **Cause** | `LibraryGame` rows missing live `emulator` relationship, `emulatorIDString`, and `platformHint` despite ROMs living under configured **Paths** folders. |
| **Fix** | `EmulatorProfileLookup` + `MetadataSystemResolver` + `RomPathPlatformResolver` (longest path-root match, including walk of `EmulatorProfile.folderPaths`); scrape-start `relinkEmulators`; **Scan Paths** refreshes nil emulator links. User: rebuild → **Scan Paths** → **Clear scraped covers** → re-scrape. |
| **Commit** | *Not committed yet* |

### BJ-008 — `.hack` PS2 games `no_match` after title-compatibility guard
| | |
|---|---|
| **When** | Jun 9, 2026 (**in progress**) |
| **Symptom** | All `.hack` / Dot Hack entries `no_match` in scrape log though older builds had covers; inspector showed empty covers after clear + re-scrape. |
| **Cause** | (1) `pickTitleIsCompatible` required Part/Vol digit in ScreenScraper title (e.g. `1` from “Part 1” missing in `.hack//Infection`). (2) Search stopped at first API hit even when no compatible candidate. (3) Often combined with BJ-007 (`systemeid` nil). |
| **Fix** | Optional Part/Vol tokens + subtitle anchor match; search tries variants until a compatible hit; `RomTitleNormalizer` `.hack//G.U. Vol.N//Name` variants. |
| **Commit** | *Not committed yet* |

### BJ-009 — Multi-disc duplicates out of order in library grid
| | |
|---|---|
| **When** | Jun 9, 2026 (**fixed**, in progress) |
| **Symptom** | Four FF IX discs linked but grid showed Disc 2, 3, 4, then Disc 1; same display title sorted by scan `sortOrder`. |
| **Cause** | Library sort used title then `sortOrder`; no per-group disc ordering. |
| **Fix** | `discGroupOrder` on `LibraryGame`; `DiscGroupService.librarySort`; inspector ▲/▼ + **Reset order from filenames**; auto-assign order on link / auto-link scan. |
| **Commit** | *Not committed yet* |

### BJ-010 — Corrupt cover tiles (“UNUNLLLE” / garbage text on grid)
| | |
|---|---|
| **When** | Jun 9, 2026 (**in progress**) |
| **Symptom** | Some grid cells showed garbled large text instead of box art after scrape. |
| **Cause** | Invalid or non-image bytes cached as cover; wheel/PHP URLs saved without validation. |
| **Fix** | `CoverImageCache` validates `NSImage` before persisting; `.php` URLs stored with `.jpg` extension where needed. Clear bad entries via **Clear scraped covers**. |
| **Commit** | *Not committed yet* |

---

## Mac library — launch / ARMSX2

### BJ-080 — ARMSX2 opens but stays on the game list (no ISO)
| | |
|---|---|
| **When** | Jul 26, 2026 (**in progress**) |
| **Symptom** | **Play** from GBear started ARMSX2 on the game list; game never booted. Unsandboxed CLI/`swift` tests with the same argv *did* pass the ISO (misleading). |
| **Cause** | Mac app had **App Sandbox** enabled. Apple documents that **`NSWorkspace.OpenConfiguration.arguments` is ignored** when the caller is sandboxed. `/usr/bin/open --args` from the sandbox also failed to deliver argv. Emulog showed folder scan only — no `isoFile open ok`. |
| **Fix** | Removed `com.apple.security.app-sandbox` from `GBear.entitlements` / `project.yml`. Launch via `NSWorkspace` + `arguments` + `createsNewApplicationInstance` after quitting existing ARMSX2 instances. |
| **Commit** | *Not committed yet* |

### BJ-081 — `open --args` ignored when ARMSX2 already running
| | |
|---|---|
| **When** | Jul 26, 2026 (**in progress**) |
| **Symptom** | Even after quitting “should” have fixed BJ-080, **Play** still left the user on the game list if ARMSX2 was already open. |
| **Cause** | Without a new instance, macOS `open -a App --args …` only **activates** the existing process; argv is not applied. Process list showed bare `…/ARMSX2` with no ISO. |
| **Fix** | `GameLauncher.terminateRunningInstances(ofAppAt:)` before CLI launch; `createsNewApplicationInstance = true` on `OpenConfiguration`. |
| **Commit** | *Not committed yet* |

### BJ-082 — Past game list but gray ARMSX2 screen (no visible gameplay)
| | |
|---|---|
| **When** | Jul 26, 2026 (**in progress**) |
| **Symptom** | With argv actually delivered (unsandboxed tests), ARMSX2 left the game list but showed a **gray** window; looked “not running.” |
| **Cause** | Default/legacy template used **`-batch -fullscreen`**. Emulog could still show ISO/ELF load while the GS/fullscreen path presented a blank/gray surface. |
| **Fix** | Catalog + migration prefer **`-fastboot -- "{ImagePath}"`** (no forced `-batch`/`-fullscreen`). Soften stored `-batch -fullscreen…` templates via `LaunchArgumentTemplate.normalizePCSX2StyleBootSeparator`. |
| **Commit** | *Not committed yet* |

### BJ-083 — ARMSX2 SIGSEGV in `MainWindow::startFile` (open-document while wizard)
| | |
|---|---|
| **When** | Jul 26, 2026 (**in progress**) |
| **Symptom** | Launch seemed to crash immediately after setup wizard / when reusing a running instance. |
| **Cause** | Crash report: Apple Event **open documents** → `MainWindow::startFile` null deref while Qt still in **`QDialog::exec()`** (setup wizard). GBear’s “already running → open document” path triggered this. |
| **Fix** | For non-empty launch templates, never use the open-document shortcut; always CLI launch after terminating instances. Avoid opening documents into ARMSX2 during first-run UI. |
| **Commit** | *Not committed yet* |

### BJ-084 — Hardcoded `/Users/<personal>/…` RetroArch cores in launch args
| | |
|---|---|
| **When** | Jul 26, 2026 (**in progress**) |
| **Symptom** | Configured RetroArch profiles embedded a personal home directory; not portable. |
| **Cause** | Templates stored absolute `/Users/…` paths; `{user_name}` was documented in Help but not expanded at launch. |
| **Fix** | `LaunchArgumentTemplate`: expand `{user_name}` / `~`; normalize stored home prefixes to `/Users/{user_name}/…` on migrate/save. |
| **Commit** | *Not committed yet* |

### BJ-085 — Missing ROM files stayed in library after Scan Paths
| | |
|---|---|
| **When** | Jul 26, 2026 (**in progress**) |
| **Symptom** | After restoring the full MacDeck/GBear store, PS2/Switch (etc.) titles whose files are no longer on the Mac remained in the library even after **Scan Paths**. |
| **Cause** | “Orphan” cleanup only deleted games whose **emulator** was missing. Scan only added/reassigned; it never pruned absent files. |
| **Fix** | `GamePathScanner.pruneMissingPathScannedGames`: on scan, delete emulator-linked games under a **reachable** Paths game root when the file is gone; keep rows if the whole root/volume is offline. Scan feedback reports **Removed N missing game(s)**. |
| **Commit** | *Not committed yet* |

---

## Streaming — architecture (Sunshine → native GBear)

### BJ-116 — Players 2–8 all controlled Player 2
| | |
|---|---|
| **When** | Sep 29 2026 |
| **Symptom** | With several remote friends in a session, every friend's pad moved Player 2 in the emulator. |
| **Cause** | Still no Virtual HID entitlement (BJ-095), so every remote seat fell back to `GBearKeyboardPadStandIn`, which had one key table and one set of held keys for everyone. The Mac has too few keys for 7 players × 25 controls. The kernel enforces the entitlement in `IOHIDResourceUserClient` (running as root does not help), so no app-side workaround creates a real pad. |
| **Fix** | Stopgap: `GBearPadControl.standInKey(seat:)` gives Players 1–2 the keypad + F13–F20 table, Player 3 letters, Player 4 the number row and punctuation. The stand-in keeps held keys per player and `release(seat:)` frees only the friend who left. Players 5–8 get no keys; the Controller map says so (`Route.unrouted`). Per-emulator network inputs (RetroArch network pad, Dolphin pipes, Cemu DSU) were built and then removed: GBear should not need code for each emulator. Real fix, for every emulator and all 8 players: Apple grants `com.apple.developer.hid.virtual.device` to team AFYV687T82 for `com.funnybearapps.gbear`, and GBear ships with a provisioning profile that contains it. Prepared for that: `GBearHIDUserDevice.c` now presents each pad as a wired DualShock 4 (054C:09CC, real 64-byte report 0x01, answers calibration / MAC / firmware feature reports, accepts rumble output) with a unique serial, MAC and location per seat, so SDL, RPCS3, RetroArch and GameController apps auto-map it instead of seeing an unknown `1209:BEAx` pad. Creation is skipped when the entitlement is missing (`GBearHIDHasVirtualDeviceEntitlement`), so the keyboard fallback still engages. `Scripts/sign-virtual-hid.sh` embeds the profile and re-signs with the entitlement after the Release build, refusing profiles that lack it. Untested until Apple approves. |
| **Commit** | *in progress* |

### BJ-115 — Windows guest could not join with an invite line
| | |
|---|---|
| **When** | Sep 29 2026 |
| **Symptom** | Pasting the host Mac's remote co-op invite into the Windows guest's host box and pressing Join showed "Could not connect to host on port 28765". |
| **Cause** | The Windows guest only spoke the LAN protocol: it passed whatever was in the box to `WinHttpConnect` on port 28765 as a host name. It had no invite parser and no relay client, so the `GBEAR1 <code> <https address>` line was treated as an address. Separately, a single-line Windows edit box keeps only the first line of pasted text, so a chat-wrapped invite would have lost its end anyway. |
| **Fix** | `GBearGuest.cpp`: `parseInvite` (same rules as the companion's `RemoteCoopInvite`, BJ-110), `register-device` + `redeem-invite` over HTTPS with the dev bearer, then `runRelaySession` opens a WinHTTP WebSocket (`RelaySocket`) to `/v1/ws?…&mode=relay`, says `hello` on `relay_ready`, answers `ping` with `pong`, takes the seat from `welcome`, decodes `GBTL` video on its own thread (skips to a keyframe after drops), plays audio, and sends `GBG1` as input frames. Reconnects up to 8 times. The host box subclass turns pasted line breaks into spaces and Enter joins. Compiles; not yet tested on Windows. |
| **Commit** | release **v1.3.2** |

### BJ-114 — Guest picture stretched and pillarboxed
| | |
|---|---|
| **When** | Sep 29 2026 |
| **Symptom** | On the companion, the host MacBook's screen looked wider than it should and soft; Windows guests saw the same. |
| **Cause** | The host always encoded a 16:9 frame (1280×720, later 1920×1080). ScreenCaptureKit fit the 16:10 MacBook screen inside it with black side bars, wasting ~13% of the pixels. The companion's `SurfaceView` was `MATCH_PARENT` and the Windows guest used `StretchDIBits` to the whole client area, so both then stretched that frame to their screen's shape. |
| **Fix** | `GBearDisplayCapture.fittedSize` captures at the display's aspect inside the requested box (1662×1080 for a 1512×982-point MacBook). Companion `fitSurfaceToVideo` centers the picture at its own shape (touch area stays full screen); Windows guest letterboxes; Mac guest renders with aspect fit via `GBearGuestVideoRenderer` and sizes its window to the picture. Harness: sizes, decode of real 1662×1080 H.264, renderer. Not yet tested live. |
| **Commit** | release **v1.3.0** |

### BJ-113 — Remote co-op audio tore and lagged at 1080p
| | |
|---|---|
| **When** | Sep 28 2026 |
| **Symptom** | On v1.2.8, the companion's audio crackled and fell behind during play, and the bitrate sat near 20 Mbit/s. The bitrate log showed the target at 20 000 kbps while the screen was still (measured under 1 Mbit/s), then when the game got busy measured jumped to 18–24 Mbit/s and the relay round trip went from ~60 ms to 1.1–1.2 s, twice. |
| **Cause** | Three things. `GBearRelayBitrateController` raised the target whenever pings showed no queue, and a nearly idle stream never queues, so the target reached the 20 Mbit/s ceiling untested; busy scenes then overran the link. The host's audio `GBearRelaySendPump` kept one pending packet and replaced it on every new 10 ms chunk, so any large video frame ahead of it on the WebSocket discarded audio (tearing). The companion's `GBearAudioReceiver` queued up to 96 chunks (~1 s), so audio that arrived late after a stall stayed late. |
| **Fix** | The target only climbs while the encoder sends at least 60% of it (`noteVideoSent`); ceiling 16 Mbit/s; back off 30% past 150 ms of queue (was 250) and halve past 500 ms. Audio pump keeps a 20-chunk FIFO (drops oldest only beyond 200 ms). Companion caps queued audio at 200 ms and skips ahead. Verified with a harness (idle screen holds the target, busy stream climbs, severe queue halves, audio order kept, video still skips to keyframes); not yet tested in a live session. |
| **Commit** | release **v1.2.9** |

### BJ-112 — Remote co-op picture looked like 480p
| | |
|---|---|
| **When** | Sep 28 2026 |
| **Symptom** | Friends on the companion (and a second guest) saw the host's 1080p screen much softer than over Wi‑Fi, "like 480p". The bitrate log showed `capture 1280x720 @ 30 fps` with the rate pinned at the 12 Mbit/s ceiling for the last 35 s, round trip 50–160 ms and no congestion. |
| **Cause** | `attachRelayGuest` hardcoded a 1280×720 capture. The host is a 3024×1964 (16:10) MacBook, so the screen fit inside that frame is only about 1108×720, which the phone then stretches across a ~3088×1440 display. The link had headroom; the rate controller's 12 Mbit/s ceiling and 6 s climb steps also kept it from using more. |
| **Fix** | Relay capture is 1920×1080 @ 30 like Wi‑Fi streaming. `GBearRelayBitrateController` starts at 8 Mbit/s, climbs every 4 s, and tops out at 20 (congestion handling unchanged). The companion opens the relay player at 1920×1080 and resizes its surface to the decoded frame size. |
| **Commit** | release **v1.2.7** |

### BJ-111 — Back in the companion player ended the stream on Android 16
| | |
|---|---|
| **When** | Sep 28 2026 |
| **Symptom** | On an Android 16 phone, Back in the stream player closed it and ended the session, with no "Back pressed" in the log. The new **Leave remote co-op?** prompt never showed, and on Wi‑Fi Back stopped the Mac stream instead of just hiding the picture. |
| **Cause** | Flutter's default target SDK is 36, which turns on predictive back. Back then goes to `OnBackInvokedDispatcher` and never reaches `GBearVideoActivity.dispatchKeyEvent` or `onBackPressed`. With no callback registered, the system finishes the activity, and `onDestroy` calls `stopStreamOnHost`. |
| **Fix** | `GBearVideoActivity.onCreate` registers an `OnBackInvokedCallback` (API 33+) that runs `handleStreamBackNavigation`. Verified on an SM-S908U1 (API 36): Back shows the prompt; **Hide**, **Resume stream view**, and **Leave** behave as intended. |
| **Commit** | release **v1.2.5** |

### BJ-110 — Pasted invite line split at a hyphen never joined
| | |
|---|---|
| **When** | Sep 28 2026 |
| **Symptom** | Tapping **Join with invite** did nothing useful, over and over. The companion logged `redeeming invite at accountability-gear-vault-` (address cut off) for each tap. Typing the same line by hand worked. |
| **Cause** | Chat and messaging apps wrap the long `trycloudflare.com` address at hyphens, so the copied line had a line break inside the address. `RemoteCoopInvite.parse` split on whitespace and used only the first piece, a host that does not exist. The Mac guest's `parseInviteLine` had the same flaw. |
| **Fix** | Both parsers join everything after the code back together (the address never contains spaces) and strip zero-width characters and soft hyphens. Verified on the phone with a line break typed inside the address. |
| **Commit** | release **v1.2.5** |

### BJ-109 — Remote co-op invite worked for only one friend
| | |
|---|---|
| **When** | Sep 28 2026 |
| **Symptom** | A friend joined with the host's invite line. A second person using the same line never got a picture. On the companion it ended in "Could not reach the host". |
| **Cause** | Not a bad code: invites can be redeemed many times for 30 minutes. `GBearLocalRelayServer` rooms held exactly two sockets (host + one guest) and closed any third, and `GBearRemoteCoopHost` tracked a single admitted guest and seat. Nothing told the second person why. |
| **Fix** | Rooms hold the host plus up to 7 guests with peer numbers. Guest traffic reaches the host wrapped in `GBTP` (`GBearTunnelPeerFrame`); the host addresses `welcome` / `error` to one peer and broadcasts media and pings. `GBearRemoteCoopHost` seats each friend separately, per-friend drop timers, `GBG1` seat rewrite per peer. `attachRelayGuest` now reports `sessionFull` vs `captureFailed` (and frees the seat when capture fails); a full session answers "This session is full". Guests need no update. |
| **Commit** | release **v1.2.4** |

### BJ-108 — Companion relay bridge listened on IPv6 loopback only
| | |
|---|---|
| **When** | Sep 28 2026 |
| **Symptom** | Still on v1.2.2: after **Join with invite**, the player tried `127.0.0.1:<port>` 16 times, got `ECONNREFUSED` every time, and closed. The log showed the bridge alive until the player gave up (`Relay bridge stopped (stream stop)`), so BJ-107 was not the cause here. |
| **Cause** | `GBearRelayBridge` bound its video/audio `ServerSocket`s and input `DatagramSocket` to `InetAddress.getLoopbackAddress()`. On Android that is `::1`, and a socket bound to `::1` does not accept IPv4 `127.0.0.1`. The player, audio reader, and input senders all dial `127.0.0.1`. |
| **Fix** | Bind all bridge sockets to `127.0.0.1` explicitly (`GBearRelayBridge.loopbackAddress`). |
| **Commit** | release **v1.2.3** |

### BJ-107 — Companion player closed right after joining with the invite line
| | |
|---|---|
| **When** | Sep 28 2026 |
| **Symptom** | After **Join with invite** succeeded (seat assigned), the player opened and closed at once. `gbear_stream.log` showed every video connect to `127.0.0.1:<port>` refused, then "stopped from companion". |
| **Cause** | `GBearVideoActivity` only handled `orientation|screenSize|keyboardHidden`, so turning to `sensorLandscape` could recreate it. The old copy's `onDestroy` called `stopStreamOnHost("127.0.0.1")`, which closes `GBearRelayBridge` and its loopback ports while the new copy was connecting. On Wi‑Fi the same path only sent a harmless stop to the Mac, so it went unnoticed. |
| **Fix** | The manifest handles all size, layout, and density changes for the player. `GBearVideoActivity.onDestroy` skips the stop when `isChangingConfigurations` or when a newer viewer has replaced it, and `MainActivity.onDestroy` skips it on configuration changes. `GBearRelayBridge.stop(reason)` logs why the bridge closed. |
| **Commit** | release **v1.2.2** |

### BJ-106 — Companion could not use the remote co-op invite line
| | |
|---|---|
| **When** | Sep 28 2026 |
| **Symptom** | Pasting the host Mac's invite line into the companion's **Friend invite code** box (Settings → Remote co-op) always ended in "Invite redeem failed". |
| **Cause** | That box belonged to an early design: it upper-cased a 6-letter code and sent it to a separate coordinator whose default address, `http://127.0.0.1:8787`, is the phone itself. The Mac's invite is a whole line with its own tunnel address. Even a successful redeem would only have shown a message, because nothing on the phone could carry video or controller data over the relay (`gbear_session_tunnel.dart` was never called). |
| **Fix** | **Session → Remote co-op with a friend** parses the `GBEAR1` line and redeems the code at the line's address (`RemoteCoopInvite`). `GBearRelayBridge` joins the relay WebSocket and serves video, audio, and input on loopback ports, so the existing player runs unchanged. The old Settings box and `GBearSessionClient` were removed. |
| **Commit** | release **v1.2.1** |

### BJ-091 — Remote co-op could not cross networks
| | |
|---|---|
| **When** | Sep 26 2026 |
| **Symptom** | Two Macs on different networks could not start couch co-op. **Join another computer** needs the host’s address. The **Remote co-op** buttons only talked to `127.0.0.1:8787`, and the Mac guest never redeemed an invite. |
| **Cause** | The session coordinator and `GBTL` tunnel were not wired to the Mac guest, and nothing reachable from the internet was running. Direct ports cannot be opened without port forwarding. |
| **Fix** | Host **Start remote co-op** starts `GBearLocalRelayServer` on localhost and an outbound tunnel, then shows a `GBEAR1` invite line. **Join with invite** connects outbound and carries video, audio, and `GBG1`. |
| **Commit** | release **v1.1.0** |

### BJ-098 — Remote co-op picture fell apart in busy scenes
| | |
|---|---|
| **When** | Sep 28 2026 |
| **Symptom** | Over the invite relay, input latency felt fine, but the picture turned blocky and smeared whenever a lot moved on screen, and stayed smeared for a moment afterwards. |
| **Cause** | The relay path used the LAN encoder settings: Baseline H.264, a keyframe every second, and a hard cap at the 4 Mbit/s average, so busy frames were starved. When the link backed up, the host send pump and the relay dropped single frames mid-GOP. Every later P-frame then referenced a missing picture, so the smear lasted until the next keyframe. |
| **Fix** | Relay capture uses a relay tuning (`GBearVideoTuning.relay` in `GBearH264Encoder`): High profile without B-frames, keyframes every 3s, and room to burst to 1.5× the average. `GBearRelayBitrateController` starts at 6 Mbit/s and adapts between 2 and 12 from control-channel ping round trips plus drops. After any video drop, the host pump and the relay skip to the next keyframe and request one, instead of forwarding broken frames. The relay tells the host `{"type":"congestion"}` when it sheds for the friend. The host Streaming screen shows the current **Picture** rate. |
| **Commit** | release **v1.1.7** |

### BJ-097 — Remote friend's controller died once the game launched
| | |
|---|---|
| **When** | Sep 27 2026 (**in progress**) |
| **Symptom** | The friend's taps showed on the host **Controller map**, then stopped after Play. Opening GBear again did not bring them back. The map staying quiet means packets were no longer applied, not only that the game ignored keys. |
| **Cause** | The relay WebSocket used a 30s receive timeout. The host mostly sends video and only receives controller packets, so a quiet load (or GBear being hidden for the game) killed the socket. Nothing reconnected, and the friend's app treated that as the host leaving and stopped sending. A full video buffer also dropped every binary frame, including `GBG1`. Separately, stand-in keys were posted on GBear's private key table, which a running game does not poll. |
| **Fix** | Keep the WebSocket open for the session, keep the process awake while co-op is running, reconnect if the socket drops, and never shed controller frames when video backs up. Input is applied off the video path. Stand-in keys post with `CGEventSource(stateID: .hidSystemState)`. Reopening the Streaming screen no longer restarts an already-running host. |
| **Commit** | release **v1.1.6** |

### BJ-096 — Remote friend's controller stopped sending mid-session
| | |
|---|---|
| **When** | Sep 26 2026 (**in progress**) |
| **Symptom** | After mapping Player 2 and switching games, the host's **Controller map** showed the last signal minutes ago. Video still reached the friend. Host counters: only WebSocket pings arrived from the friend (~77 KB of input all session). |
| **Cause** | On the friend's Mac, GBear also ran its own co-op session with **This Mac** as Player 1, so `GBearHostLocalGamepad` was active. It rebinds every controller's `valueChangedHandler` on each `refreshCoopSession` (e.g. opening the Streaming tab) and on controller reconnect (its `Task` hop runs after `GBearGuestGamepadSender`'s rebind). That replaced the sender's handler, so presses went to a local pad and were never sent. `stop()` also cleared every handler. |
| **Fix** | `GBearHostLocalGamepad.yieldToGuestSender()` / `reclaimFromGuestSender()`: while `GBearStreamGuestManager` has a pad sender (invite or LAN join), host-local `bindAll` and `stop()` leave controller handlers alone. Also: `GBearRemoteCoopHost` kills stale `cloudflared tunnel --url http://127.0.0.1:8787` processes before starting a tunnel and terminates its tunnel on app quit (five orphans were found from earlier crashed runs). |
| **Commit** | release **v1.1.6** |

### BJ-095 — Emulators never see GBear Virtual Pads
| | |
|---|---|
| **When** | Sep 26 2026 |
| **Symptom** | Remote friend joined and pressed buttons, but the host emulator's controller list showed only the host's physical pad. No **GBear Virtual Pad 1** or **2**. |
| **Cause** | `IOHIDUserDeviceCreateWithProperties` needs `com.apple.developer.hid.virtual.device`. That entitlement was removed from `GBear.entitlements` in `45201c3`. It is restricted: Apple grants it through the System Extension / DriverKit request form ("Virtual HID"), and signing it without a matching provisioning profile makes AMFI kill the app at launch. The host log shows every create returning `IOHIDUserDeviceRef … id:0x0`, so `GBearVirtualGamepad` has no device and drops every report. |
| **Fix** | Keyboard stand-in: when a seat's pad has no HID device, `GBearVirtualGamepadManager.apply` sends that remote player's `GBG1` to `GBearKeyboardPadStandIn`, which holds keypad and F13–F20 keys (Accessibility required). The host binds Player 2 to the keyboard in the emulator. Sticks and triggers become on/off keys; one remote player at a time. Held keys release on leave or reset. The real fix is Apple granting Virtual HID; the stand-in turns itself off once pads can be created. |
| **Commit** | release **v1.1.4** |

### BJ-094 — Guest video stayed small when the pop-up was enlarged
| | |
|---|---|
| **When** | Sep 26 2026 |
| **Symptom** | On the joining Mac, the stream opened in a small pop-up. Dragging it bigger grew an empty see-through border while the picture stayed the same size. |
| **Cause** | The picture was a SwiftUI `.sheet` on the main window, with `GBearGuestVideoView` pinned at its minimum frame. A sheet cannot grow past its parent window, and the video view did not fill the extra space. |
| **Fix** | `GBearGuestVideoWindow` opens the stream in its own resizable 16:9 window with full screen. `GBearGuestVideoView` fills the window. `GBearStreamGuestManager.phase` opens the window when streaming starts and closes it on leave or failure. Closing the window leaves the session. |
| **Commit** | release **v1.1.3** |

### BJ-093 — Host crashed when the remote friend joined
| | |
|---|---|
| **When** | Sep 26 2026 |
| **Symptom** | The friend pasted the invite and the host GBear quit. Crash report: `EXC_BREAKPOINT` on the main thread in `GBearGamepadEventFormat.parse` from `GBearRemoteCoopHost.handleIncoming`. |
| **Cause** | `GBG1` puts `buttons` at byte 5 and the floats at 9–29. `parse` used `load(fromByteOffset:)`, which requires aligned memory. Debug builds trap with "load from misaligned raw pointer". |
| **Fix** | Use `loadUnaligned` for every `GBG1` field. Test packs a pad packet, wraps it in `GBTL`, unwraps, and parses it in a `-Onone` build; the old code traps on the same test. |
| **Commit** | release **v1.1.2** |

### BJ-092 — Host crashed on Start remote co-op
| | |
|---|---|
| **When** | Sep 26 2026 |
| **Symptom** | GBear quit right after **Start remote co-op**, before the invite line showed. Crash report: `EXC_BREAKPOINT` on queue `GBearRelay.server` in `GBearLocalRelayServer.nextFrame(in:)`. |
| **Cause** | After a WebSocket frame was consumed, `removeFirst` left the buffer as a `Data` slice whose indices no longer start at 0. `nextFrame` read `buffer[0]`, which is out of range for a slice. |
| **Fix** | Rebase the buffer to a fresh `Data` after each frame, and rebase inside `nextFrame` when handed a slice. Relay self-test now sends a 40-message burst; the old code traps on it. |
| **Commit** | release **v1.1.1** |

### BJ-011 — Sunshine/Moonlight path fragile (ports, PIN, dual instances)
| | |
|---|---|
| **When** | Jun 2–3, 2026 (Sunshine era: `f373265`, `cead3f0`, `a0a1ee1`; removed `df1f254`) |
| **Symptom** | Pairing/streaming depended on external Sunshine; port **48010** conflicts if two instances; Moonlight `/launch` coupling; hard to ship in Mac app bundle. |
| **Cause** | Out-of-process Sunshine + forked Moonlight repos + TLS/control-plane complexity. |
| **Fix** | Replaced with in-app **GBear** stack: `GBearStreamControlServer`, ScreenCaptureKit + VideoToolbox, companion `GBearHostClient` / `GBearVideoActivity`. Removed Sunshine bootstrap scripts and vendor clones (`df1f254`). |
| **Commit** | `df1f254` (*no more sunshine or moonlight*) |

---

## Streaming — video (Android)

### BJ-020 — Black screen / decoder not configured (H.264 Annex-B)
| | |
|---|---|
| **When** | Jun 3, 2026 (`df1f254` native video path; hardened in follow-up work) |
| **Symptom** | TCP connected but no picture; logs showed `decoder=false` until keyframe/SPS/PPS handled. |
| **Cause** | Mac sends length-prefixed `GBV1` Annex-B; MediaCodec needs SPS/PPS (avcC or in-band) before slice NALs. |
| **Fix** | `GBearVideoActivity` Annex-B parse, avcC bootstrap, keyframe gating, `c2.android.avc.decoder` path; Mac encoder keyframe on connect. Verified ~900+ frames rendered in session logs. |
| **Commit** | `df1f254`, ongoing in `41487e8` / `GBearVideoActivity.kt` |

---

## Streaming — touch & keyboard (Mac + Android)

### BJ-030 — Touch Y axis inverted on Mac
| | |
|---|---|
| **When** | Jun 3, 2026 (`cbd1ca8` *no more inverted mouse input*) |
| **Symptom** | Finger up on phone moved Mac cursor down (or vice versa). |
| **Cause** | Normalized phone Y mapped with `frame.maxY - ny * height` (flipped). |
| **Fix** | Use `frame.minY + ny * height` in `GBearRemoteInputPlayback`. Removed obsolete companion “mouse emulation” toggle. |
| **Commit** | `cbd1ca8` |

### BJ-031 — Command+Q (and letters) sent wrong keys to Mac
| | |
|---|---|
| **When** | Jun 3, 2026 (`ae82eac` *shortcut fix*) |
| **Symptom** | **Close app** shortcut and chords didn’t quit the foreground app; wrong characters or no effect. |
| **Cause** | `GBearKeyboardPlayback` mapped Windows VK with `vk - 0x41` (e.g. Q → keycode 16 instead of **12**); Command/Option posted as separate key down/up events instead of `CGEvent.flags`. |
| **Fix** | US ANSI `windowsVKToMacKeyCode` table (Carbon `kVK_ANSI_*`); modifiers only update `heldModifierFlags`; letter keys posted with correct `CGKeyCode`. |
| **Commit** | `ae82eac` |

### BJ-032 — Shortcuts stopped working after leaving video with Back
| | |
|---|---|
| **When** | Jun 3, 2026 (`ae82eac`, `f7c4936`) |
| **Symptom** | Notification or home **Shortcuts** / **Close app** did nothing after Back left `GBearVideoActivity`. |
| **Cause** | `GBearKeyboardSender` lived on the activity and was cleared on destroy. |
| **Fix** | Session-scoped `GBearStreamSession.keyboardSender()` for the whole stream; activity uses shared sender. |
| **Commit** | `f7c4936`, `ae82eac` |

### BJ-033 — Mac Command/Option missing from chord picker
| | |
|---|---|
| **When** | Jun 3, 2026 (`f7c4936` *controller mapping*) |
| **Symptom** | Could not map gamepad buttons to Mac Command/Option chords. |
| **Cause** | Moonlight key list / Mac playback didn’t treat modifier VKs correctly. |
| **Fix** | Added Option/Command (left/right) to picker; `GBearKeyboardPlayback` modifier flag path (completed in `ae82eac`). |
| **Commit** | `f7c4936`, `ae82eac` |

---

## Streaming — audio

### BJ-040 — No audio on phone / multi-second latency
| | |
|---|---|
| **When** | Jun 3, 2026 (`41487e8` *streaming and audio work*) |
| **Symptom** | Video worked; phone silent or audio heavily delayed. |
| **Cause** | UDP-only or blocked reader; oversized `AudioTrack` buffer; planar ScreenCaptureKit audio not interleaved correctly on Mac. |
| **Fix** | Mac: stereo interleave in `GBearDisplayCapture`; **`GBA1`** over **TCP 28769** (primary). Android: `GBearAudioReceiver` network + playback threads, ~150 ms buffer, `PERFORMANCE_MODE_LOW_LATENCY`. |
| **Commit** | `41487e8` |

### BJ-041 — Mac speakers still audible while “streaming” to phone
| | |
|---|---|
| **When** | Jun 3, 2026 (`41487e8`; behavior refined in uncommitted host lifecycle work) |
| **Symptom** | Mac continued playing audio locally when the Mac app was open, even when user expected phone-only playback. |
| **Cause** | Output not muted during stream; early host startup started capture/listeners whenever Streaming UI opened. |
| **Fix** | `GBearLocalOutputMute` during active stream; restore on stop. **In progress:** `ensureReady()` only starts HTTP pairing control—capture/transport start on companion `stream/start` (see BJ-050). |
| **Commit** | `41487e8` (mute); host lifecycle split **in progress** (working tree) |

---

## Companion — pairing & UI

### BJ-050 — Mac capture/stream ran whenever Streaming tab opened
| | |
|---|---|
| **When** | Jun 3, 2026 (**in progress**, working tree) |
| **Symptom** | Opening GBear → Streaming muted Mac and felt like “stream always on” without companion starting a session. |
| **Cause** | `GBearStreamHostManager.ensureReady()` started video/audio/input listeners and implied active streaming. |
| **Fix** | `ensureReady()` starts **HTTP 28765 only**; `beginVideoStream` on `POST /gbear/v1/stream/start`; `endVideoStream` on `stream/stop`; UI copy distinguishes pairing host vs active stream. |
| **Commit** | *Not committed yet* |

### BJ-051 — No way to cancel pairing wait on phone
| | |
|---|---|
| **When** | Jun 3, 2026 (`ae82eac`) |
| **Symptom** | Pair button stayed disabled while polling; user had to wait for Mac deny/timeout. |
| **Cause** | No companion cancel path; only Mac could deny. |
| **Fix** | Outlined **Cancel** on host row; `PairingCancellation` + `POST /gbear/v1/pair/cancel`; Mac `cancelPending(deviceID:)`. |
| **Commit** | `ae82eac` |

### BJ-052 — Host action buttons wrong style (filled vs outlined)
| | |
|---|---|
| **When** | Jun 3, 2026 (`ae82eac`) |
| **Symptom** | Add IP / Pair / Cancel didn’t match desired outlined appearance preset. |
| **Fix** | `OutlinedButton` theme from `CompanionAppearanceSettings` primary text color; chips outlined in mapping/shortcut editors. |
| **Commit** | `ae82eac` |

### BJ-053 — Second companion stream replaced the first viewer
| | |
|---|---|
| **When** | Sep 22, 2026 (**in progress**) |
| **Symptom** | Two phones could pair, but starting a second Desktop stream dropped the first phone’s video/audio (single TCP client + `beginVideoStream` always ended prior capture). |
| **Cause** | `GBearVideoStreamServer` / audio kept one client; companion `startStream` stopped Mac capture whenever `videoStreaming` was already true. |
| **Fix** | Fan-out to 2 video/audio clients; co-op session seats; attach without restarting capture; companion no longer stops an active multi-viewer session when joining. |
| **Commit** | *Not committed yet* |

---

## Companion — stream notification (Android)

### BJ-060 — Samsung notification showed title only (no Stop/Controller/Shortcuts)
| | |
|---|---|
| **When** | Jun 3, 2026 (`b4933a8`, `ae82eac`) |
| **Symptom** | Ongoing stream notification collapsed to a single line on Samsung/One UI. |
| **Cause** | `DecoratedCustomViewStyle` + low-importance channel; OEM ignores custom RemoteViews layout. |
| **Fix** | Channel `gbear_stream_session_v2` (HIGH); custom `gbear_stream_notification.xml`; **no** `DecoratedCustomViewStyle`; duplicate `NotificationCompat.addAction` fallback buttons. |
| **Commit** | `b4933a8`, `ae82eac` |

### BJ-061 — App crashed when tapping notification Shortcuts
| | |
|---|---|
| **When** | Jun 3, 2026 (`ae82eac`) |
| **Symptom** | Process died after **Shortcuts** action; SecurityException in log. |
| **Cause** | `NotificationShadeUtils` broadcast `Intent.ACTION_CLOSE_SYSTEM_DIALOGS`, blocked on modern Android. |
| **Fix** | Removed broadcast; reflection-only `StatusBarManager.collapsePanels()` wrapped in try/catch; collapse is best-effort after action. |
| **Commit** | `ae82eac` |

### BJ-062 — Notification **Stop** didn’t allow starting a new stream
| | |
|---|---|
| **When** | Jun 3, 2026 (reported after `ae82eac`; fix **in progress**) |
| **Symptom** | Notification **Stop** OK, but Session tab still showed blue **Streaming** (or 2nd **Start** flashed *Starting* then *Stream stopped*; 3rd **Start** hit `TimeoutException after 0:00:12` on Mac `stream/start`). |
| **Cause** | (1) **300ms delayed `onStreamStoppedExternally`** fired after a new Start. (2) Resume `getStreamSession` during start reset UI. (3) Mac start/stop HTTP overlapped while capture still tearing down. (4) Prior `deactivate()` callback re-entered `stopAll`. (5) `_refreshStreamSessionState` cleared *Stream running* / *Starting* but not success label **Streaming**; Flutter stop notify removed from `stopAll`. |
| **Fix** | Remove delayed stop notify; ignore external stop while `_startingStream`; skip session refresh during start; companion calls `stream/stop` + status poll + 25s timeout/5 retries before start; Mac `enqueueStreamOperation` + cancel `captureTask`; `_isLiveStreamSessionStatus` clears **Streaming** when native inactive; **pull model:** `pendingExternalStopLogPath` on `getStreamSession`; resume refresh offers log; `_startStream` trusts native `hostStreamActive`. **Jun 2026:** notification **Stop** removed — use Session tab **Stop** only (notification path could not reliably sync Flutter / second **Start**). |
| **Commit** | *Not committed yet* |

### BJ-063 — Second stream: `ECONNREFUSED` on port 28766
| | |
|---|---|
| **When** | Jun 3, 2026 (logs + **in progress** fix) |
| **Symptom** | After stop, new session immediately failed connect to `192.168.1.14:28766`. |
| **Cause** | (1) `NWListener.start()` returned before `.ready`. (2) Fast Session Stop posted Mac `stream/stop` in the background; a late stop could kill the next stream after `stream/start`. (3) Stale TCP listener if `stopListener` had not finished. |
| **Fix** | `GBearNWListenerAwait`; deferred native connect result; `macStopGeneration` cancels stale Android background stops on new start; Mac restarts listener if still bound; preemptive `endVideoStream` when listener active. |
| **Commit** | *In progress* |

---

## Companion — session lifecycle

### BJ-070 — `hostStreamActive` stuck after failed connect
| | |
|---|---|
| **When** | Jun 3, 2026 (**in progress**) |
| **Symptom** | Connect failed but app behaved as if stream still active; **Start** disabled. |
| **Cause** | `GBearVideoActivity` called `finish()` on connect error without clearing `GBearStreamSession` or stopping Mac. |
| **Fix** | `handleConnectFailure()` → `GBearStreamStopper.stopAll`; `launchStreamActivity` returns `false` to Flutter when connect fails (no immediate `result.success(true)`). |
| **Commit** | *In progress (with BJ-063)* |

### BJ-071 — **Resume stream view** failed after Back from video
| | |
|---|---|
| **When** | Jun 3, 2026 (regression after Mac-stop-on-destroy work; **fixed**, verified) |
| **Symptom** | **Resume stream view** did not reopen video; Mac had stopped even though user only pressed **Back**. |
| **Cause** | `GBearVideoActivity.onDestroy` posted **`stream/stop`** whenever `hostStreamActive` was true, including viewer-only exit via **Back** (`leaveViewerOnly`). |
| **Fix** | **`GBearStreamSession.leaveViewerWithoutMacStop`**: set on Back path, cleared in `onDestroy`; Mac stop only when the activity ends for other reasons (force-quit, connect failure teardown, Session **Stop**). **`resumeStream`** clears the flag and relaunches **`GBearVideoActivity`**. |
| **Commit** | *Not committed yet* |

### BJ-072 — Swap on but left stick did not move cursor
| | |
|---|---|
| **When** | Jun 3, 2026 (**fixed**, verified) |
| **Symptom** | Notification **Swap** enabled; face buttons worked; left stick had no effect on Mac cursor. |
| **Cause** | **`handleHatDpad`** returned “consumed” whenever any D-pad slot had a binding, even with hat centered—so **`GBearGamepadMouseSender`** never ran. Motion order ran mapping before Swap mouse. |
| **Fix** | Hat handler only consumes when a direction actually presses/releases a chord; generic motion runs **Swap mouse first**, then triggers/hat/sticks. Left-stick read includes dead-zone fallback axes on some pads. |
| **Commit** | *Not committed yet* |

### BJ-073 — **Assign Swap** / mapped Swap toggled only once
| | |
|---|---|
| **When** | Jun 3, 2026 (**fixed**, verified) |
| **Symptom** | First Swap toggle worked; later presses did nothing until user relinked the button. |
| **Cause** | **`swapToggleDown`** latch in **`GBearGamepadMapping`**; missed **KEY_UP** left latch set so further **ACTION_DOWN** was ignored. |
| **Fix** | Toggle Swap on each **ACTION_DOWN** (`repeatCount == 0`) without latch; **`releaseAllKeys`** on Swap off unchanged. |
| **Commit** | *Not committed yet* |

### BJ-074 — **Link gamepad** ignored D-pad and stick (L3/R3 only)
| | |
|---|---|
| **When** | Jun 3, 2026 (**fixed**, verified for D-pad; stick directions added) |
| **Symptom** | **Link gamepad** only detected face buttons and L3/R3; D-pad and stick pushes did nothing. |
| **Cause** | Capture listened only to **`KeyEvent`**; Samsung and many pads emit D-pad as **`AXIS_HAT_X/Y`** and sticks as **`MotionEvent`**, not **`KEYCODE_DPAD_*`**. |
| **Fix** | **`GamepadLinkCapture.tryConsumeMotion`** (hat + stick deflection); **`dispatchGenericMotionEvent`** on **`MainActivity`** and **`GBearVideoActivity`**. Link passes target **`elementId`** so the correct stick direction is learned. Eight stick-direction mapping slots + **`handleAnalogSticks`** at stream time. |
| **Commit** | *Not committed yet* |

### BJ-075 — Phone volume buttons had no effect in companion
| | |
|---|---|
| **When** | Jun 3, 2026 (**fixed**, verified) |
| **Symptom** | Hardware volume keys did not change loudness while the app was open (including during stream). |
| **Cause** | Gamepad filter could interfere; stream notification **`CATEGORY_TRANSPORT`** on some OEMs tied volume to the wrong stream; no explicit **`volumeControlStream`**. |
| **Fix** | **`GamepadInputFilter`**: never treat volume keys as gamepad; **`volumeControlStream = STREAM_MUSIC`** on **`MainActivity`** / **`GBearVideoActivity`**; notification category **service**. |
| **Commit** | *Not committed yet* |

### BJ-076 — Second **Start** / force-quit left Mac session stuck
| | |
|---|---|
| **When** | Jun 3–4, 2026 (**fixed**, verified **Stop → Start**) |
| **Symptom** | After **Stop**, swipe-kill, or failed reconnect, next **Start Desktop** failed (TCP **28766** / timeout) until Mac app restart. |
| **Cause** | Refactor bound/unbound **NWListener** per session (port races on second connect). **`stream/stop`** reported idle before teardown; companion **`transportReady`** / heavy pre-start polling fought async stop. Working commit **41487e8** kept listeners up and only toggled capture. |
| **Fix** | Restored persistent listeners in **`ensureReady()`**; capture-only **`beginVideoStream`** / **`endVideoStream`**; fire-and-forget **`stream/start`** + **`stream/stop`**; idempotent **`startListener`**; removed **`transportReady`**. Companion: single **`stream/start`**; preflight stop only when **`videoStreaming`** true. Retained **Back** resume, **Stop** coordinator, and **Stop active stream** on Mac. |
| **Commit** | *Not committed yet* |

### BJ-086 — Co-op locked to two phones / join order
| | |
|---|---|
| **When** | Sep 22, 2026 (**in progress**) |
| **Symptom** | Remote couch co-op only allowed two companion phones; player order followed join order; host Mac and a second computer could not occupy slots; co-op GBG1 ignored button remaps. |
| **Cause** | `maxSeats` / video-audio `maxClients` / HID pads hardcoded to 2; seats were phone-device identity with no `joinSeat` remap; no host-local or computer-guest client kinds; GBG1 used a fixed Android keycode table. |
| **Fix** | 8 slots (`GBearCoopSession`); this Mac counts as a player (**7 remotes**); **8 remotes** only if a companion plays as host; join-order default with Player 1 reserved for the host; `joinSeat` frozen + host translation for **Move to**; virtual pads per occupied seat; computer guests; companion auto-map + overrides. WAN relay remains 2-peer. |
| **Commit** | *in progress* |

---

## Open / known issues

| ID | Issue | Notes |
|----|--------|--------|
| BJ-080–083 | ARMSX2 launch regressions (sandbox argv, gray GS, open-document crash) | Verify after rebuild with sandbox **off**; quit ARMSX2 before Play; emulog should show `isoFile open ok`. |
| BJ-085 | Missing files left in library after scan | Verify **Scan Paths** reports removed missing games when Paths roots are online. |
| BJ-007 | Scrape log still mostly `emulatorSystemeid=nil` on some libraries | Confirm **Scan Paths** after rebuild; verify ROM paths match configured folder roots (symlinks / external drives). |
| BJ-008 | Residual `no_match` for short/obscure titles | *rain*, *Hannah*, *ChokoNana* may need manual ScreenScraper pick even with platform set. |
| — | Some OEMs still collapse custom notification layout | `addAction` fallback present; may need in-app stream control panel. |
| — | Host physical pad + GBear virtual pad both visible to emulators | If double-input, disconnect the physical device in the emulator and map **GBear Virtual Pad N**. |
| — | WAN table larger than two | Mac invite relay is host + one friend. Use LAN **Join another computer** for 3+ players. |
| — | `stream/start` returns before capture is running | Phone connects to TCP **28766** immediately; first frames may lag until SCK starts (expected). |
| — | Force-quit without **Stop** | Use Session **Stop** or Mac **Stop active stream**; next **Start** sends preflight **`stream/stop`** when **`videoStreaming`** is still true. |
| — | Right stick on some pads uses **AXIS_RX/RY** vs **Z/RZ** | Mapping tries both; link capture matches target element only. |

---

## How to add entries

1. Assign the next **BJ-###** id.
2. Include **symptom**, **cause**, **fix**, and **commit** (or *in progress*).
3. Add a line to `source control log.md` when the fix ships in a release.
4. Agents: project rule **living-docs** (`.cursor/rules/living-docs.mdc`) — keep this journal, `source control log.md`, and `Features and Inner Workings.md` updated when work fits those docs.

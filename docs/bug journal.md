# Bug journal

Chronicle of bugs encountered in **Playnite Mac** and the **companion app**, and how they were fixed. Entries are grouped by area; dates come from git commits unless noted as **in progress** (not yet committed).

For release notes style summaries, see `source control log.md`. For architecture context, see `Features and Inner Workings.md`.

---

## Mac library — scanning & covers

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

## Streaming — architecture (Sunshine → native Playnite)

### BJ-011 — Sunshine/Moonlight path fragile (ports, PIN, dual instances)
| | |
|---|---|
| **When** | Jun 2–3, 2026 (Sunshine era: `f373265`, `cead3f0`, `a0a1ee1`; removed `df1f254`) |
| **Symptom** | Pairing/streaming depended on external Sunshine; port **48010** conflicts if two instances; Moonlight `/launch` coupling; hard to ship in Mac app bundle. |
| **Cause** | Out-of-process Sunshine + forked Moonlight repos + TLS/control-plane complexity. |
| **Fix** | Replaced with in-app **Playnite** stack: `PlayniteStreamControlServer`, ScreenCaptureKit + VideoToolbox, companion `PlayniteHostClient` / `PlayniteVideoActivity`. Removed Sunshine bootstrap scripts and vendor clones (`df1f254`). |
| **Commit** | `df1f254` (*no more sunshine or moonlight*) |

---

## Streaming — video (Android)

### BJ-020 — Black screen / decoder not configured (H.264 Annex-B)
| | |
|---|---|
| **When** | Jun 3, 2026 (`df1f254` native video path; hardened in follow-up work) |
| **Symptom** | TCP connected but no picture; logs showed `decoder=false` until keyframe/SPS/PPS handled. |
| **Cause** | Mac sends length-prefixed `PNV1` Annex-B; MediaCodec needs SPS/PPS (avcC or in-band) before slice NALs. |
| **Fix** | `PlayniteVideoActivity` Annex-B parse, avcC bootstrap, keyframe gating, `c2.android.avc.decoder` path; Mac encoder keyframe on connect. Verified ~900+ frames rendered in session logs. |
| **Commit** | `df1f254`, ongoing in `41487e8` / `PlayniteVideoActivity.kt` |

---

## Streaming — touch & keyboard (Mac + Android)

### BJ-030 — Touch Y axis inverted on Mac
| | |
|---|---|
| **When** | Jun 3, 2026 (`cbd1ca8` *no more inverted mouse input*) |
| **Symptom** | Finger up on phone moved Mac cursor down (or vice versa). |
| **Cause** | Normalized phone Y mapped with `frame.maxY - ny * height` (flipped). |
| **Fix** | Use `frame.minY + ny * height` in `PlayniteRemoteInputPlayback`. Removed obsolete companion “mouse emulation” toggle. |
| **Commit** | `cbd1ca8` |

### BJ-031 — Command+Q (and letters) sent wrong keys to Mac
| | |
|---|---|
| **When** | Jun 3, 2026 (`ae82eac` *shortcut fix*) |
| **Symptom** | **Close app** shortcut and chords didn’t quit the foreground app; wrong characters or no effect. |
| **Cause** | `PlayniteKeyboardPlayback` mapped Windows VK with `vk - 0x41` (e.g. Q → keycode 16 instead of **12**); Command/Option posted as separate key down/up events instead of `CGEvent.flags`. |
| **Fix** | US ANSI `windowsVKToMacKeyCode` table (Carbon `kVK_ANSI_*`); modifiers only update `heldModifierFlags`; letter keys posted with correct `CGKeyCode`. |
| **Commit** | `ae82eac` |

### BJ-032 — Shortcuts stopped working after leaving video with Back
| | |
|---|---|
| **When** | Jun 3, 2026 (`ae82eac`, `f7c4936`) |
| **Symptom** | Notification or home **Shortcuts** / **Close app** did nothing after Back left `PlayniteVideoActivity`. |
| **Cause** | `PlayniteKeyboardSender` lived on the activity and was cleared on destroy. |
| **Fix** | Session-scoped `PlayniteStreamSession.keyboardSender()` for the whole stream; activity uses shared sender. |
| **Commit** | `f7c4936`, `ae82eac` |

### BJ-033 — Mac Command/Option missing from chord picker
| | |
|---|---|
| **When** | Jun 3, 2026 (`f7c4936` *controller mapping*) |
| **Symptom** | Could not map gamepad buttons to Mac Command/Option chords. |
| **Cause** | Moonlight key list / Mac playback didn’t treat modifier VKs correctly. |
| **Fix** | Added Option/Command (left/right) to picker; `PlayniteKeyboardPlayback` modifier flag path (completed in `ae82eac`). |
| **Commit** | `f7c4936`, `ae82eac` |

---

## Streaming — audio

### BJ-040 — No audio on phone / multi-second latency
| | |
|---|---|
| **When** | Jun 3, 2026 (`41487e8` *streaming and audio work*) |
| **Symptom** | Video worked; phone silent or audio heavily delayed. |
| **Cause** | UDP-only or blocked reader; oversized `AudioTrack` buffer; planar ScreenCaptureKit audio not interleaved correctly on Mac. |
| **Fix** | Mac: stereo interleave in `PlayniteDisplayCapture`; **`PNA1`** over **TCP 28769** (primary). Android: `PlayniteAudioReceiver` network + playback threads, ~150 ms buffer, `PERFORMANCE_MODE_LOW_LATENCY`. |
| **Commit** | `41487e8` |

### BJ-041 — Mac speakers still audible while “streaming” to phone
| | |
|---|---|
| **When** | Jun 3, 2026 (`41487e8`; behavior refined in uncommitted host lifecycle work) |
| **Symptom** | Mac continued playing audio locally when the Mac app was open, even when user expected phone-only playback. |
| **Cause** | Output not muted during stream; early host startup started capture/listeners whenever Streaming UI opened. |
| **Fix** | `PlayniteLocalOutputMute` during active stream; restore on stop. **In progress:** `ensureReady()` only starts HTTP pairing control—capture/transport start on companion `stream/start` (see BJ-050). |
| **Commit** | `41487e8` (mute); host lifecycle split **in progress** (working tree) |

---

## Companion — pairing & UI

### BJ-050 — Mac capture/stream ran whenever Streaming tab opened
| | |
|---|---|
| **When** | Jun 3, 2026 (**in progress**, working tree) |
| **Symptom** | Opening GBear → Streaming muted Mac and felt like “stream always on” without companion starting a session. |
| **Cause** | `PlayniteStreamHostManager.ensureReady()` started video/audio/input listeners and implied active streaming. |
| **Fix** | `ensureReady()` starts **HTTP 28765 only**; `beginVideoStream` on `POST /playnite/v1/stream/start`; `endVideoStream` on `stream/stop`; UI copy distinguishes pairing host vs active stream. |
| **Commit** | *Not committed yet* |

### BJ-051 — No way to cancel pairing wait on phone
| | |
|---|---|
| **When** | Jun 3, 2026 (`ae82eac`) |
| **Symptom** | Pair button stayed disabled while polling; user had to wait for Mac deny/timeout. |
| **Cause** | No companion cancel path; only Mac could deny. |
| **Fix** | Outlined **Cancel** on host row; `PairingCancellation` + `POST /playnite/v1/pair/cancel`; Mac `cancelPending(deviceID:)`. |
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
| **Cause** | `PlayniteVideoStreamServer` / audio kept one client; companion `startStream` stopped Mac capture whenever `videoStreaming` was already true. |
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
| **Fix** | Channel `playnite_stream_session_v2` (HIGH); custom `playnite_stream_notification.xml`; **no** `DecoratedCustomViewStyle`; duplicate `NotificationCompat.addAction` fallback buttons. |
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
| **Fix** | `PlayniteNWListenerAwait`; deferred native connect result; `macStopGeneration` cancels stale Android background stops on new start; Mac restarts listener if still bound; preemptive `endVideoStream` when listener active. |
| **Commit** | *In progress* |

---

## Companion — session lifecycle

### BJ-070 — `hostStreamActive` stuck after failed connect
| | |
|---|---|
| **When** | Jun 3, 2026 (**in progress**) |
| **Symptom** | Connect failed but app behaved as if stream still active; **Start** disabled. |
| **Cause** | `PlayniteVideoActivity` called `finish()` on connect error without clearing `PlayniteStreamSession` or stopping Mac. |
| **Fix** | `handleConnectFailure()` → `PlayniteStreamStopper.stopAll`; `launchStreamActivity` returns `false` to Flutter when connect fails (no immediate `result.success(true)`). |
| **Commit** | *In progress (with BJ-063)* |

### BJ-071 — **Resume stream view** failed after Back from video
| | |
|---|---|
| **When** | Jun 3, 2026 (regression after Mac-stop-on-destroy work; **fixed**, verified) |
| **Symptom** | **Resume stream view** did not reopen video; Mac had stopped even though user only pressed **Back**. |
| **Cause** | `PlayniteVideoActivity.onDestroy` posted **`stream/stop`** whenever `hostStreamActive` was true, including viewer-only exit via **Back** (`leaveViewerOnly`). |
| **Fix** | **`PlayniteStreamSession.leaveViewerWithoutMacStop`**: set on Back path, cleared in `onDestroy`; Mac stop only when the activity ends for other reasons (force-quit, connect failure teardown, Session **Stop**). **`resumeStream`** clears the flag and relaunches **`PlayniteVideoActivity`**. |
| **Commit** | *Not committed yet* |

### BJ-072 — Swap on but left stick did not move cursor
| | |
|---|---|
| **When** | Jun 3, 2026 (**fixed**, verified) |
| **Symptom** | Notification **Swap** enabled; face buttons worked; left stick had no effect on Mac cursor. |
| **Cause** | **`handleHatDpad`** returned “consumed” whenever any D-pad slot had a binding, even with hat centered—so **`PlayniteGamepadMouseSender`** never ran. Motion order ran mapping before Swap mouse. |
| **Fix** | Hat handler only consumes when a direction actually presses/releases a chord; generic motion runs **Swap mouse first**, then triggers/hat/sticks. Left-stick read includes dead-zone fallback axes on some pads. |
| **Commit** | *Not committed yet* |

### BJ-073 — **Assign Swap** / mapped Swap toggled only once
| | |
|---|---|
| **When** | Jun 3, 2026 (**fixed**, verified) |
| **Symptom** | First Swap toggle worked; later presses did nothing until user relinked the button. |
| **Cause** | **`swapToggleDown`** latch in **`PlayniteGamepadMapping`**; missed **KEY_UP** left latch set so further **ACTION_DOWN** was ignored. |
| **Fix** | Toggle Swap on each **ACTION_DOWN** (`repeatCount == 0`) without latch; **`releaseAllKeys`** on Swap off unchanged. |
| **Commit** | *Not committed yet* |

### BJ-074 — **Link gamepad** ignored D-pad and stick (L3/R3 only)
| | |
|---|---|
| **When** | Jun 3, 2026 (**fixed**, verified for D-pad; stick directions added) |
| **Symptom** | **Link gamepad** only detected face buttons and L3/R3; D-pad and stick pushes did nothing. |
| **Cause** | Capture listened only to **`KeyEvent`**; Samsung and many pads emit D-pad as **`AXIS_HAT_X/Y`** and sticks as **`MotionEvent`**, not **`KEYCODE_DPAD_*`**. |
| **Fix** | **`GamepadLinkCapture.tryConsumeMotion`** (hat + stick deflection); **`dispatchGenericMotionEvent`** on **`MainActivity`** and **`PlayniteVideoActivity`**. Link passes target **`elementId`** so the correct stick direction is learned. Eight stick-direction mapping slots + **`handleAnalogSticks`** at stream time. |
| **Commit** | *Not committed yet* |

### BJ-075 — Phone volume buttons had no effect in companion
| | |
|---|---|
| **When** | Jun 3, 2026 (**fixed**, verified) |
| **Symptom** | Hardware volume keys did not change loudness while the app was open (including during stream). |
| **Cause** | Gamepad filter could interfere; stream notification **`CATEGORY_TRANSPORT`** on some OEMs tied volume to the wrong stream; no explicit **`volumeControlStream`**. |
| **Fix** | **`GamepadInputFilter`**: never treat volume keys as gamepad; **`volumeControlStream = STREAM_MUSIC`** on **`MainActivity`** / **`PlayniteVideoActivity`**; notification category **service**. |
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
| **Symptom** | Remote couch co-op only allowed two companion phones; player order followed join order; host Mac and a second computer could not occupy slots; co-op PNG1 ignored button remaps. |
| **Cause** | `maxSeats` / video-audio `maxClients` / HID pads hardcoded to 2; seats were phone-device identity with no `joinSeat` remap; no host-local or computer-guest client kinds; PNG1 used a fixed Android keycode table. |
| **Fix** | 8 slots (`PlayniteCoopSession`); this Mac counts as a player (**7 remotes**); **8 remotes** only if a companion plays as host; join-order default with Player 1 reserved for the host; `joinSeat` frozen + host translation for **Move to**; virtual pads per occupied seat; computer guests; companion auto-map + overrides. WAN relay remains 2-peer. |
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
| — | WAN 8-player over session relay | Coordinator membership is 8; byte-relay is still two sockets. Use LAN for 3+ remote viewers. |
| — | `stream/start` returns before capture is running | Phone connects to TCP **28766** immediately; first frames may lag until SCK starts (expected). |
| — | Force-quit without **Stop** | Use Session **Stop** or Mac **Stop active stream**; next **Start** sends preflight **`stream/stop`** when **`videoStreaming`** is still true. |
| — | Right stick on some pads uses **AXIS_RX/RY** vs **Z/RZ** | Mapping tries both; link capture matches target element only. |

---

## How to add entries

1. Assign the next **BJ-###** id.
2. Include **symptom**, **cause**, **fix**, and **commit** (or *in progress*).
3. Add a line to `source control log.md` when the fix ships in a release.
4. Agents: project rule **living-docs** (`.cursor/rules/living-docs.mdc`) — keep this journal, `source control log.md`, and `Features and Inner Workings.md` updated when work fits those docs.

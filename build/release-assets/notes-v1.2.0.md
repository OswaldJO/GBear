Your library can now pull from a ROMM server, your Steam, Epic, and GOG accounts, and more cover sources. Emulators for the same console can share one library section.

## ROMM server

A new **ROMM** section in the Library sidebar connects to your ROMM server (address, username, password saved in the Keychain). Link each ROMM platform to an emulator, for example GameCube to Dolphin, then click **Sync Now**. **Scan Paths** syncs as well.

- Games are matched by name, ignoring region tags, extensions, and dump clutter. Disc numbers must agree, so Disc 2 never shows up twice.
- The info panel shows each game's ROMM **Status** (In ROMM / Missing) and a link to its ROMM page.
- **Add games to library that are not on this Mac** (off by default) adds ROMM-only games with ROMM's cover. Their Path says **Not present**, and **Download From ROMM** (or Play) saves the game into the emulator's game folder.
- **Clear Sync** removes ROMM games that are not on this Mac and resets all ROMM statuses. Downloaded games stay.

## Link emulators

In **Emulators**, the link button next to edit links profiles for the same console. Flycast and Redream, for example, become one **Dreamcast** section. A game in a folder both emulators scan shows once. Pick a **Default emulator** that opens the group's games. **Launch with** in the info panel still picks another emulator for one game. Linking and unlinking rescan the library right away.

## Launch with, per game

The info panel has a **Launch with** menu. Pick any emulator profile to open that one game with it, without moving the game to another section.

## Storefront Manager: Steam, Epic, GOG

**Storefront Manager → Show Manager** has checkboxes and a sign-in for each store. Installed games are always imported. Signed in, every game you own is imported too, and installed ones get a green check on the cover. Steam games open through Steam, Epic through the Epic Games Launcher, and GOG directly or in GOG Galaxy. Steam also needs your own Steam Web API key to list owned games.

## More cover sources

Covers now come from ScreenScraper, then IGDB, SteamGridDB, and TheGamesDB, each with your own free key. Paste them under **Manage Providers** (formerly Screen Scrapper). **Search for Covers…** searches every provider you set up at once, grouped by provider. GBear tracks each provider's API limit and pauses a provider until its limit resets, instead of sending requests that fail.

## Removed games stay removed

**Remove from Library** now blocks the game, so **Scan Paths** does not add it back. **Manage Blocked List** in the Library toolbar unblocks games.

## Mac — GBear-macOS.zip

Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel). Remote co-op works the same as v1.1.7.

## Android companion — GBear-companion-android.apk

Same companion build as v1.1.5. Copy the apk to the phone and open it. If Android blocks the install, allow installation from your files app for this one. In the companion, enter the host computer’s IP address. Pairing is approved on the host. The phone still joins on the local network.

An iPhone build is not in this release. iOS installs need TestFlight or a registered device.

## Windows — GBearGuest-windows.exe

Same Windows build as v1.1.5. This is the couch co-op app: **Join** a host, or **Host this PC** so a Mac can join. If SmartScreen warns, choose **More info**, then **Run anyway**. Windows joining and hosting still use the host’s address directly. They do not use the Mac invite line.

Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once, so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

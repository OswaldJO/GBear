The Library gets a search, and the Mac saves a bitrate log every time a stream ends.

## Search the Library

The Library toolbar has a search field. When the window is narrow it shows as a magnifying-glass button next to `>>`. It searches the section selected in the sidebar (All, Mac Games, or one emulator or group) by game name, file name, platform or emulator. You can combine words, like `mario n64`. The game count at the bottom of the sidebar shows how many games match.

## Bitrate log after every stream

When a stream ends (Stop on the Mac or phone, remote co-op ending, or the last viewer leaving), GBear saves `GBear bitrate <date>.csv` to **Downloads**. A summary sits at the top: average, median and peak bitrate, the target, and remote co-op round trip. Below it there's one row per second with the measured and target bitrate, frames and keyframes, biggest frame, viewers, dropped frames, and events like target changes, friends joining or leaving, and congestion. **Streaming → Streaming host** shows the latest log with **Show in Finder**. Very short streams (under two seconds) are not saved.

## Mac — GBear-macOS.zip

New in this release. Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel).

## Android companion — GBear-companion-android.apk

Same as v1.2.5. If you already installed v1.2.5, nothing to do. Otherwise copy the apk to the phone and open it to install over the previous version.

An iPhone build is not in this release. iOS installs need TestFlight or a registered device.

## Windows — GBearGuest-windows.exe

Same Windows build as v1.1.5. This is the couch co-op app: **Join** a host, or **Host this PC** so a Mac can join. If SmartScreen warns, choose **More info**, then **Run anyway**. Windows joining and hosting still use the host’s address directly. They do not use the Mac invite line.

Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once, so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

Remote co-op friends now get a much sharper picture.

## Sharper remote co-op picture

Friends saw the host's screen at roughly 480p quality even when the Mac ran at 1080p. Remote co-op captured the screen at 1280×720, and on a MacBook's taller screen only about 1108×720 of that was actual picture before the phone stretched it. It now captures at **1920×1080**, the same as Wi‑Fi streaming.

A bigger picture needs more data, so the picture rate now starts at 8 Mbit/s and can climb to 20 (it was 6 to 12), and it climbs faster. It still drops back when a friend's connection can't keep up. With several friends, the slowest connection still sets the rate for everyone.

The bitrate log saved to Downloads after each stream should now show `capture 1920x1080`.

## Mac — GBear-macOS.zip

New in this release; the host Mac needs it for the sharper picture. Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel).

## Android companion — GBear-companion-android.apk

New in this release. It opens the remote co-op player at the new size and says 1920×1080 on the Session tab. Friends still on v1.2.5 also get the sharper picture once the host updates. Copy the apk to the phone and open it to install over the previous version.

An iPhone build is not in this release. iOS installs need TestFlight or a registered device.

## Windows — GBearGuest-windows.exe

Same Windows build as v1.1.5. This is the couch co-op app: **Join** a host, or **Host this PC** so a Mac can join. If SmartScreen warns, choose **More info**, then **Run anyway**. Windows joining and hosting still use the host’s address directly. They do not use the Mac invite line.

Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once, so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

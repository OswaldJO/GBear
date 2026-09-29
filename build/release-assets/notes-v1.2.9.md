Remote co-op audio no longer tears or falls behind in busy games.

## Smoother remote co-op

In v1.2.8, the friend's audio crackled and lagged once the game got busy, and the bitrate sat near 20 Mbit/s. On still screens the picture rate crept up to its ceiling without ever being tested. When the action started, the video flooded the connection (round trips up to 1.2 seconds) and the audio got stuck behind it.

- **Bitrate only rises when it's used.** The rate climbs only while the game is actually sending near the target, tops out at 16 Mbit/s (plenty for 1080p at 30 fps), and backs off sooner when the connection starts to queue.
- **No more audio tearing.** The Mac no longer throws away bits of sound while a large video frame is sending.
- **No lasting audio lag.** After a network hiccup, the companion skips ahead instead of staying behind the picture.

## Mac — GBear-macOS.zip

New in this release; the host Mac needs it. Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel).

## Android companion — GBear-companion-android.apk

New in this release (the audio catch-up). Everyone joining should install it. Copy the apk to the phone and open it to install over the previous version.

An iPhone build is not in this release. iOS installs need TestFlight or a registered device.

## Windows — GBearGuest-windows.exe

Same Windows build as v1.1.5. This is the couch co-op app: **Join** a host, or **Host this PC** so a Mac can join. If SmartScreen warns, choose **More info**, then **Run anyway**. Windows joining and hosting still use the host’s address directly. They do not use the Mac invite line.

Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once, so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

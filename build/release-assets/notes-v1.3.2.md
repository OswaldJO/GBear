The Windows guest can join remote co-op with the invite line.

## Windows — GBearGuest-windows.exe

New in this release. Before, pasting the host Mac's remote co-op invite into the Windows guest failed with "Could not connect to host on port 28765", because Windows could only join by IP address.

- The host box now takes either an IP address or the whole `GBEAR1 …` invite line your friend sends. Press **Join** (or Enter).
- With an invite, Windows joins through your friend's Mac the same way the companion does: no pairing, no port forwarding, and up to 7 friends on one invite. Picture, sound, and controller all go through it, and it reconnects on its own after a short drop.
- Invites that a chat app wrapped onto two lines paste in whole.
- Joining by IP address and **Host this PC** work the same as before. Hosting on Windows is still by IP address only.

If SmartScreen warns, choose **More info**, then **Run anyway**. Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once, so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

## Mac — GBear-macOS.zip

Same as v1.3.0; the host Mac does not need an update for Windows invite joins. Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel).

## Android companion — GBear-companion-android.apk

Same as v1.3.0; no need to reinstall if you already have it. Copy the apk to the phone and open it to install over the previous version.

An iPhone build is not in this release. iOS installs need TestFlight or a registered device.

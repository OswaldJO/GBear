Fixes the Android companion closing the picture right after you join with a remote co-op invite line.

## Remote co-op join no longer closes the player

In v1.2.1, joining with the invite line worked and the host gave you a seat, but the picture could open and close at once. The phone turned the player to landscape, and the old copy of the screen shut the connection to the host on its way out. Rotation no longer ends the session.

To join: on the host Mac, open **Streaming**, click **Start remote co-op**, then **Copy invite**, and send the line. On the phone, open the **Session** tab, paste the whole line under **Remote co-op with a friend**, and tap **Join with invite**.

## Android companion — GBear-companion-android.apk

New in this release. Copy the apk to the phone and open it to install over v1.2.1. If Android blocks the install, allow installation from your files app for this one.

An iPhone build is not in this release. iOS installs need TestFlight or a registered device.

## Mac — GBear-macOS.zip

Same Mac build as v1.2.1. Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel).

## Windows — GBearGuest-windows.exe

Same Windows build as v1.1.5. This is the couch co-op app: **Join** a host, or **Host this PC** so a Mac can join. If SmartScreen warns, choose **More info**, then **Run anyway**. Windows joining and hosting still use the host’s address directly. They do not use the Mac invite line.

Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once, so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

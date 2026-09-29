One remote co-op invite line now works for several friends at once.

## Several friends per invite

Before, only the first friend who used the invite line got in. Anyone else using the same line never got a picture, with no explanation. Now up to 7 friends can join with the same line, each as their own player.

1. On the host Mac, open **Streaming**, click **Start remote co-op**, then **Copy invite**, and send the line to everyone.
2. Each friend joins with it: on the Android companion under **Session → Remote co-op with a friend**, or on a Mac with **Join with invite**.
3. The host's Streaming status lists who is which player, for example "Alex is Player 2, Sam is Player 3". In the emulator, set up each friend's player while that friend presses each button.

Everyone sees the same 720p picture. Its quality adjusts to the slowest friend's connection. A friend who joins when every player slot is taken is told the session is full. A friend who drops has a few seconds to reconnect and keeps their player number.

## Mac — GBear-macOS.zip

New in this release, and only the host needs it. Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel).

## Android companion — GBear-companion-android.apk

Same as v1.2.3, which already joins with the invite line. Copy the apk to the phone and open it. If Android blocks the install, allow installation from your files app for this one.

An iPhone build is not in this release. iOS installs need TestFlight or a registered device.

## Windows — GBearGuest-windows.exe

Same Windows build as v1.1.5. This is the couch co-op app: **Join** a host, or **Host this PC** so a Mac can join. If SmartScreen warns, choose **More info**, then **Run anyway**. Windows joining and hosting still use the host’s address directly. They do not use the Mac invite line.

Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once, so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

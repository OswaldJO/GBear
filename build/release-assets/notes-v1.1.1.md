Fixes a crash on the host Mac when clicking **Start remote co-op**. GBear quit before the invite line appeared. If you host remote co-op, install this Mac build. A friend who only joins can keep v1.1.0.

## Remote co-op across networks

On the host Mac, open Streaming and click **Start remote co-op**, then **Copy invite** and send the line. On the other Mac, paste it under **Join with invite**. Both computers connect outbound. No port forwarding. The first time the host starts a session, GBear downloads the connector it uses for that path. The picture is 1280×720. Bind **GBear Virtual Pad 1** and **GBear Virtual Pad 2** in the game.

## Mac — GBear-macOS.zip

Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel).

## Android companion — GBear-companion-android.apk

Same companion build as v1.0.0. Copy the apk to the phone and open it. If Android blocks the install, allow installation from your files app for this one. In the companion, enter the host computer’s IP address. Pairing is approved on the host. The phone still joins on the local network.

An iPhone build is not in this release. iOS installs need TestFlight or a registered device.

## Windows — GBearGuest-windows.exe

Same Windows build as v1.0.0. This is the couch co-op app: **Join** a host, or **Host this PC** so a Mac can join. If SmartScreen warns, choose **More info**, then **Run anyway**. Windows joining and hosting still use the host’s address directly. They do not use the Mac invite line.

Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once, so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

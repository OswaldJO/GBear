Your friend's controller now reaches the game. Before, emulators on the host never saw **GBear Virtual Pad 2**, because macOS only allows virtual controllers for apps Apple has approved, and GBear is not approved yet. The host Mac now turns the friend's controller into key presses that you bind as Player 2. Only the host needs this build.

## Setting up Player 2 in the emulator

1. On the host, allow **GBear** under **System Settings → Privacy & Security → Accessibility**. GBear cannot press keys without it.
2. Start remote co-op and have your friend join.
3. In the emulator's controller settings, keep **Player 1** on your controller. For **Player 2**, choose **Keyboard**, then click each button slot while your friend presses that button. Save it; you only do this once per emulator.

Sticks and triggers act like on/off buttons, similar to a D-pad. The emulator must be the app in front on the host.

## Remote co-op across networks

On the host Mac, open Streaming and click **Start remote co-op**, then **Copy invite** and send the line. On the other Mac, paste the whole line into GBear under **Join with invite**. Opening the link in a browser does not work. Both computers connect outbound. No port forwarding. The picture is 1280×720. The joining Mac shows the stream in its own window that can go full screen.

## Mac — GBear-macOS.zip

Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel).

## Android companion — GBear-companion-android.apk

Same companion build as v1.0.0. Copy the apk to the phone and open it. If Android blocks the install, allow installation from your files app for this one. In the companion, enter the host computer’s IP address. Pairing is approved on the host. The phone still joins on the local network.

An iPhone build is not in this release. iOS installs need TestFlight or a registered device.

## Windows — GBearGuest-windows.exe

Same Windows build as v1.0.0. This is the couch co-op app: **Join** a host, or **Host this PC** so a Mac can join. If SmartScreen warns, choose **More info**, then **Run anyway**. Windows joining and hosting still use the host’s address directly. They do not use the Mac invite line.

Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once, so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

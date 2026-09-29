Your phone can now join a friend's Mac with the remote co-op invite line, and the host can see the stream's bitrate.

## Join remote co-op from the Android companion

Before, the only invite box on the phone (Settings → Remote co-op) wanted a short code for a server that never runs, so the invite line always failed. That box is gone.

1. On the host Mac, open **Streaming**, click **Start remote co-op**, then **Copy invite**, and send the line.
2. On the phone, open the **Session** tab. Under **Remote co-op with a friend**, paste the whole line (the paste button is in the field) and tap **Join with invite**.
3. The picture opens at 1280×720, and the status shows which player you are. On the host, bind that player in the emulator while the phone presses each button.

No pairing or IP address needed, and the phone can be on any network. **Stop** leaves the session, and **Resume stream view** reopens the picture after Back. **Join as player** picks your preferred slot.

## Bitrate on the host

**Streaming → Streaming host** has a **Bitrate** row, for example `7.6 Mbit/s (target 8.0 Mbit/s)`. The first number is the video actually sent over the last second. The target is the encoder setting: fixed on Wi‑Fi, adjusted to your friend's connection in remote co-op.

## Mac — GBear-macOS.zip

Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel). A host on v1.2.0 already works with the new companion; this build adds the bitrate row.

## Android companion — GBear-companion-android.apk

New in this release. Copy the apk to the phone and open it. If Android blocks the install, allow installation from your files app for this one. On the same Wi‑Fi, enter the host computer’s IP address as before, and approve pairing on the host. For another network, use the invite line as above.

An iPhone build is not in this release. iOS installs need TestFlight or a registered device.

## Windows — GBearGuest-windows.exe

Same Windows build as v1.1.5. This is the couch co-op app: **Join** a host, or **Host this PC** so a Mac can join. If SmartScreen warns, choose **More info**, then **Run anyway**. Windows joining and hosting still use the host’s address directly. They do not use the Mac invite line.

Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once, so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

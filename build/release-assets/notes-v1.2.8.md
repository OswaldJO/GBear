Watch the bitrate while you play.

## Detachable bitrate

Click the picture-in-picture button next to **Streaming → Streaming host → Bitrate** to open a small floating **Bitrate** window. It stays on top while you play, even over full-screen games, and clicking it doesn't take focus away from the game.

- Large current bitrate, with the target underneath.
- In remote co-op, the latest round trip to your friends in milliseconds.
- A one-minute graph: the filled area is what's actually sent, the dashed line is the target.
- It updates every second even if GBear is hidden or on another tab.

Friends watching the stream don't see it; it's left out of the picture they receive. Drag it anywhere and it reopens in the same spot. Close it with its close button or the same button in Streaming. A game that takes over the display in exclusive mode can still cover it (rare on the Mac).

## Mac — GBear-macOS.zip

New in this release. Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel).

## Android companion — GBear-companion-android.apk

Same as v1.2.7. If you already installed v1.2.7, nothing to do.

An iPhone build is not in this release. iOS installs need TestFlight or a registered device.

## Windows — GBearGuest-windows.exe

Same Windows build as v1.1.5. This is the couch co-op app: **Join** a host, or **Host this PC** so a Mac can join. If SmartScreen warns, choose **More info**, then **Run anyway**. Windows joining and hosting still use the host’s address directly. They do not use the Mac invite line.

Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once, so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

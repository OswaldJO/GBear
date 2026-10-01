The Windows guest gets a new look that matches the companion app.

## Windows — GBearGuest-windows.exe

New in this release. The app now uses the companion's dark theme:

- A top bar with the GBear bear icon and a reminder that **Esc** leaves the stream and **I** flips the picture.
- A rounded card with the host address box, the player picker, and pill buttons. **Join** is blue and turns into a red **Leave** while connected; **Host this PC** turns red as **Stop hosting**; **Pair** lights up blue when a Mac asks to join.
- A status line with a colored dot: green while streaming, blue while hosting, amber while connecting.
- A "No picture yet" screen before the stream starts, a dark title bar, and the bear icon on the taskbar and in Explorer.
- The window follows Windows display scaling and can be resized.

Joining and hosting work the same as in v1.3.0. This is the couch co-op app: **Join** a host, or **Host this PC** so a Mac can join. If SmartScreen warns, choose **More info**, then **Run anyway**. Windows joining and hosting still use the host’s address directly. They do not use the Mac invite line.

Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once, so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

## Mac — GBear-macOS.zip

Same as v1.3.0; no need to reinstall if you already have it. Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel).

## Android companion — GBear-companion-android.apk

Same as v1.3.0; no need to reinstall if you already have it. Copy the apk to the phone and open it to install over the previous version.

An iPhone build is not in this release. iOS installs need TestFlight or a registered device.

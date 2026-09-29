Joining remote co-op with a pasted invite now works, and the Android companion has a clear way to leave.

## Pasted invites join

Messaging apps wrap the long invite address onto a second line at a hyphen. The companion and the Mac's **Join with invite** only read the part before the break, so joining quietly failed. Paste the invite exactly as it arrives; line breaks inside it no longer matter.

## Leave remote co-op on the phone

- Press **Back** in the picture and choose:
  - **Leave** gives up your player slot. The invite still works if you want to rejoin.
  - **Hide** closes the picture but keeps your slot.
  - **Keep playing** closes the question.
- While you're joined, the **Session** tab shows **Leave remote co-op**, plus **Resume stream view** when the picture is hidden.

## Back on Android 16

On phones with Android 16, Back closed the player and ended the stream. It now works as the app intends: in remote co-op it asks the question above, and on Wi‑Fi it hides the picture while the stream keeps running.

## Android companion — GBear-companion-android.apk

New in this release; everyone joining with an invite should install it. Copy the apk to the phone and open it to install over the previous version. If Android blocks the install, allow installation from your files app for this one.

An iPhone build is not in this release. iOS installs need TestFlight or a registered device.

## Mac — GBear-macOS.zip

New in this release (the invite fix for Mac guests; hosting is the same as v1.2.4, including several friends per invite). Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel).

## Windows — GBearGuest-windows.exe

Same Windows build as v1.1.5. This is the couch co-op app: **Join** a host, or **Host this PC** so a Mac can join. If SmartScreen warns, choose **More info**, then **Run anyway**. Windows joining and hosting still use the host’s address directly. They do not use the Mac invite line.

Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once, so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

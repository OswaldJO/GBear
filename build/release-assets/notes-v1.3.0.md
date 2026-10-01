The streamed picture keeps the host screen's real shape, and Mac guests get Apple's MetalFX upscaler.

## Picture keeps its shape

The host used to squeeze its screen into a 16:9 frame. A MacBook's taller screen got black bars baked into the sides, and then the phone or Windows guest stretched that whole frame to fill its own screen, so everything looked wider and softer than it should.

- The host Mac now captures at its screen's own shape, as big as fits in 1080p. A MacBook sends 1662×1080; a 16:9 monitor still sends 1920×1080. This applies to Wi‑Fi streaming and remote co-op.
- **Companion:** the picture is centered at its real shape with black bars instead of being stretched. The whole screen, bars included, still works as the trackpad.
- **Windows guest:** the picture is fitted with black bars instead of stretched to the window.
- **Mac guest:** the stream window resizes itself to the picture's shape.

## MetalFX on Mac guests

A Mac joining a stream now draws the picture with Metal. When the window shows it bigger than it was sent (almost always on a Retina screen), Apple's MetalFX upscaler enlarges it with sharper edges than plain scaling. It costs about 2 ms of GPU time per frame on Apple silicon. To turn it off, use **Sharpen the picture with MetalFX** under **Streaming → Join another computer** or **Join a remote session**. The option is hidden on Macs whose GPU doesn't support MetalFX.

The Mac guest also stopped rebuilding its video decoder at every keyframe, which could cause small hitches every few seconds.

## Mac — GBear-macOS.zip

New in this release; the host needs it for the new picture shape, and Mac guests for MetalFX. Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel).

## Android companion — GBear-companion-android.apk

New in this release (no more stretching). Copy the apk to the phone and open it to install over the previous version. An older companion still works with the new host, but it keeps stretching the picture.

An iPhone build is not in this release. iOS installs need TestFlight or a registered device.

## Windows — GBearGuest-windows.exe

New in this release (first update since v1.1.5): the joined picture keeps the host's shape instead of stretching. This is the couch co-op app: **Join** a host, or **Host this PC** so a Mac can join. If SmartScreen warns, choose **More info**, then **Run anyway**. Windows joining and hosting still use the host’s address directly. They do not use the Mac invite line.

Hosting on Windows needs [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once, so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

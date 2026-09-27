# GBear

GBear is a game library and launcher, plus a way to play that library from another screen. The Mac app keeps the library, covers, emulators, and the stream host. A phone companion and a Windows app join that host for ordinary streaming or for couch co-op.

Installers are on the [v1.0.0 release](https://github.com/OswaldJO/GBear/releases/tag/v1.0.0).

## Release files

| File | What it is | Who installs it |
|---|---|---|
| [GBear-macOS.zip](https://github.com/OswaldJO/GBear/releases/download/v1.0.0/GBear-macOS.zip) | The Mac app. Library, emulator setup, folder scan, ScreenScraper covers, and the stream host. | The computer that owns the games. Unzip, move `GBear.app` to Applications. macOS 14 or newer, Apple silicon or Intel. |
| [GBear-companion-android.apk](https://github.com/OswaldJO/GBear/releases/download/v1.0.0/GBear-companion-android.apk) | The Android companion. Pair with a host, watch the stream, and send touch, keyboard shortcuts, or a controller. | The phone. Copy the apk over and open it. Allow that one install if Android asks. |
| [GBearGuest-windows.exe](https://github.com/OswaldJO/GBear/releases/download/v1.0.0/GBearGuest-windows.exe) | The Windows couch co-op app. **Join** a host, or **Host this PC** so a Mac can join a game running on Windows. | The Windows PC. If SmartScreen warns, choose **More info**, then **Run anyway**. |

The Mac build is signed with an Apple Development certificate and is not notarized. The first launch is blocked until you right-click `GBear.app`, choose **Open**, then **Open** again.

There is no iPhone build in this release. Installing on an iPhone needs TestFlight or a device registered to the developer account.

When a Windows PC is the host, install [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) once so the other player’s controller shows up as an Xbox pad. Joining a Mac does not need that driver.

## Where the ideas came from

GBear is not a fork of those projects. A few of them were tried, and the streaming path that ships now was written for GBear after that attempt was removed.

**Playnite** was a reference for the library, not a codebase we started from. The Mac app’s shape — one grid of games, per-emulator settings, folder scanning, covers, and a Play button — follows that kind of launcher. There is no Playnite source in this repository.

**Sunshine**, **Apollo**, and **Moonlight** were a real first streaming attempt, not only an idea. Sunshine (and Apollo, which is the same kind of host) ran beside the Mac app. The phone side started from Moonlight, including forks kept in the tree. Pairing was a PIN into Sunshine, and the stream used that project’s control plane. It was awkward to ship: two Sunshine instances fought over ports, the host was a separate program instead of part of GBear, and the phone client was tied to Moonlight’s launch flow. In June 2026 that path was removed, including the vendored clones and the extra Sunshine binary.

The streamer after that point is GBear’s own. The Mac host captures the screen in-process, encodes H.264, and speaks `gbear-stream/1` on its own ports. The Android player, the Windows guest, and the Mac “join another computer” screen are clients of that protocol. They are not Moonlight.

One small convention stayed. Keyboard shortcuts still use Moonlight’s Windows virtual-key numbers, and the Mac translates those to its own key codes. That is a numbering choice. The Moonlight app is not running.

**Steam Link** was a reference for the experience: play a game that lives on one computer from another screen in the house, with a controller in your hands. GBear does not include Steam Link, and it does not talk to Steam’s remote-play protocol.

## Regular streaming and remote couch co-op

Both use the same picture and sound. The host captures its screen and system audio, compresses the picture as H.264, and sends it to whoever joined. What changes is who is playing, and how the computers find each other.

**Regular streaming** is one person on another screen. The phone, or another computer, pairs with the host and watches the desktop. Touch on the phone moves the host’s pointer. Keyboard shortcuts and a single controller can be sent back. On a Mac host, the Mac’s speakers mute while someone is watching, and the sound plays on the device that joined. This path is direct on the local network: the joiner uses the host’s IP address. It is the “play my library from the couch or the phone” mode.

**Remote couch co-op** is several people on that same picture, each with their own controller. The host still runs one game. Each person who joins gets a player slot. The host turns that person’s controller into a virtual gamepad the game can see (`GBear Virtual Pad` on a Mac, an Xbox pad through ViGEm on Windows). The person at the host computer can be Player 1. Everyone else joins in order, and the host can move people between slots afterward. There are eight slots. The host uses one when they are playing, so seven other devices can join. An eighth device fits only when someone else plays as the host and the host computer leaves the pad list.

On a local network, co-op uses the same direct connection as regular streaming. Phones, another Mac, and the Windows app can sit in the same session.

Across the internet, two Macs use a different connection. The host clicks **Start remote co-op**. GBear opens an outbound relay (no port forwarding) and shows an invite line. The other Mac pastes that line under **Join with invite** and connects outbound to the same relay. That relay is a two-person link: one host and one friend. A full table of players belongs on a local network. The Windows app’s **Join** and **Host this PC** buttons still use a direct address.

So: regular streaming is one viewer and the host’s desktop. Couch co-op is the same desktop with a virtual controller per player. “Remote” means those extra players are not sitting at the host, whether they are on the same Wi-Fi or reaching it through an invite.

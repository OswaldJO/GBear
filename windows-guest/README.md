# GBear on Windows

Small Windows app for couch co-op. It is not a port of the library or emulators. Either computer can host the game:

- **Join** watches a host and sends a controller back.
- **Host this PC** captures this PC’s screen and audio, and gives the other player a virtual Xbox pad.

The other computer can be a Mac running GBear (**Streaming → Join another computer**) or this same Windows app.

Built exe (Windows 10 or 11, 64-bit): `build/GBearGuest.exe`

Rebuild on a Mac that has MinGW: `./build.sh`

## Before you start

The two computers have to reach each other. The joiner types the host’s IP.

- **Same Wi-Fi or Ethernet.** Use the host’s LAN address.
- **Different houses.** Install [Tailscale](https://tailscale.com) on both, sign into the same tailnet, and use the host’s Tailscale IP (starts with `100.`). Phone invite codes are not used by this app.

On the Mac, the address is in **System Settings → Network**, or in Terminal: `ipconfig getifaddr en0` (try `en1` if that prints nothing). On Windows, **Host this PC** prints the address to use.

Whoever is hosting must leave their GBear window open. The first connection may ask to allow the app through the firewall.

## This test: Mac hosts, Windows joins

1. Send `GBearGuest.exe` to the Windows PC. SmartScreen may say it is unrecognized. Choose **More info**, then **Run anyway**.
2. On the Mac, plug in your controller. Open GBear → **Streaming**. Confirm **Host plays on** is **This Mac** (you are Player 1).
3. On Windows, run `GBearGuest.exe`. Enter the Mac IP. Leave the seat on **Next open seat** (that is Player 2). Click **Join**. Do not click **Host this PC**.
4. On the Mac, **Streaming → Pairing requests** shows the Windows computer. Click **Pair**.
5. The Windows window should show the Mac screen. Plug an Xbox-style controller into the Windows PC. The first controller found is used.
6. Launch the game on the Mac. In the emulator’s controller settings, assign:
   - Player 1 → **GBear Virtual Pad 1** (your controller on the Mac)
   - Player 2 → **GBear Virtual Pad 2** (your friend’s controller)
7. Press buttons on both controllers. **Leave** or **Esc** on Windows disconnects.

## Later: Windows hosts, Mac joins

Do this once on the Windows PC before that session: install [ViGEmBus](https://github.com/nefarius/ViGEmBus/releases) (the setup exe from the latest release). That driver is what lets the Mac’s controller show up as an Xbox pad in Windows games. Without it, the picture can still stream and the controller will not.

1. On Windows, plug in the controller, run `GBearGuest.exe`, and click **Host this PC**. Allow the firewall prompt. The window shows the IP the Mac should use. This PC is Player 1 on its real controller. The picture sent to the Mac is at most 1280×720.
2. On the Mac, GBear → **Streaming → Join another computer**. Enter that IP. **Pair & join**.
3. On Windows, click **Pair** when the Mac asks.
4. The Mac window shows the Windows screen. In the Windows game or emulator, assign Player 2 to the new Xbox 360 controller (the virtual pad). Player 1 stays the physical controller on the Windows PC.
5. **Stop hosting** ends the session.

While a Windows host is streaming, that PC keeps its own speakers on, and the Mac plays the same audio. A Mac host still mutes the Mac speakers and sends audio to the guest.

No controller on Windows: click the guest window and use **WASD** to move, arrows for the d-pad, **Space** A, **C** B, **F** X, **R** Y, **Q** / **E** bumpers, **Shift** / **Ctrl** triggers, **Enter** Start, **Backspace** Select.

If the picture is upside down, press **I**.

If Join fails, read `gbear-guest.log` in the same folder as the exe. The usual cause is the wrong IP, the Streaming tab not open, or a firewall blocking ports **28765**, **28766**, **28768**, and **28769**.

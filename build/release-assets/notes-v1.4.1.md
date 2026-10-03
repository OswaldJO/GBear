Sleep the Mac from the controller, TV volume on the controller, and covers that were stuck after a scrape or RomM sync now show. Only the Mac app is new; the companion apk and Windows guest are the same as v1.4.0.

## Mac — GBear-macOS.zip

**Sleep from the couch**
- Hold **Start + R2** for 5 seconds to put the Mac to sleep, in GBear or in a game. No Accessibility permission needed.
- In GBear, Start now plays the selected game when you let go of it (and not if R2 was pressed with it).
- Controllers can't wake a Mac: wake it with the keyboard, trackpad, mouse or power button, then press the controller's PS / Xbox button to reconnect. Macs with HDMI-CEC (M4 MacBook Pro, M4 Mac mini and others) turn the TV off and on with the Mac by themselves.

**TV volume on the controller**
- While the Mac's sound plays through a TV over HDMI, **Select + L1 / R1** change the TV's volume instead of the Mac's.
- Works with a Roku TV over Wi‑Fi (allow **Settings → System → Advanced system settings → Control by mobile apps** on the Roku), or with any TV through a Pulse-Eight USB-CEC adapter and `brew install libcec`.
- Set it up under **Streaming → TV**. macOS asks for Local Network access the first time GBear looks for a Roku; allow it.
- Brightness stays on the Mac: TVs don't accept brightness commands.

**Covers**
- Covers that a scrape found but couldn't download no longer count as covers, so the next scrape tries again, and the scrape log says why the download failed.
- Covers from a RomM sync now load (they used RomM's ScreenScraper login, which ScreenScraper refuses from GBear).
- At launch and after each scrape, GBear downloads every cover that was stuck as a web address, so those games fill in on their own.
- Scrape logs saved to Downloads no longer include your ScreenScraper passwords.

Unzip, then move **GBear.app** to Applications. The first time you open it, macOS will block it because this build is signed with an Apple Development certificate and is not notarized. Right-click **GBear.app**, choose **Open**, then **Open** again. Or allow it under **System Settings → Privacy & Security**.

Requires macOS 14 or newer (Apple silicon or Intel).

## Android companion — GBear-companion-android.apk

Same as v1.4.0. An iPhone build is not in this release.

## Windows — GBearGuest-windows.exe

Same as v1.4.0.

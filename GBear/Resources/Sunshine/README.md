# Bundled Sunshine binary

GBear **does not** run Homebrew Sunshine at stream time. The app copies this binary into Application Support and launches it from there so **Screen Recording** targets one stable path.

## Developers (one-time per machine)

From the repo root:

```bash
./Scripts/stage-sunshine-for-mac-app.sh
```

That places an executable `sunshine` in this folder. Rebuild **GBear** in Xcode so `Resources/Sunshine` is copied into the `.app` bundle.

Homebrew is only used by the staging script to **obtain** a binary for bundling—not for end-user streaming.

## End users

1. Open **Streaming** in GBear Mac.
2. Click **Show host in Finder** and enable that `sunshine` in **System Settings → Privacy & Security → Screen Recording**.
3. Click **Restart streaming host**.
4. Status should show **Ready to stream** (not merely “reachable”).

If you previously installed Sunshine via Homebrew, quit that process in Activity Monitor before using GBear.

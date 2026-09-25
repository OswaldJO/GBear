#!/usr/bin/env python3
"""
Reads GBear emulator definitions (emulator.yaml) and emits BuiltinEmulatorCatalog.json.
Source: https://github.com/JosefNemec/GBear (Emulation/Emulators/*/emulator.yaml)
Re-run when updating the vendored catalog from a newer GBear tree.
"""
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("Requires PyYAML: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def fix_mac_launch_arguments(args_str: str) -> str:
    """Normalize GBear’s Windows RetroArch `-L .\\cores\\*.dll` templates for macOS."""
    t = str(args_str)
    t = t.replace(".\\cores\\", "cores/")
    t = t.replace(".\\cores/", "cores/")
    t = t.replace("\\", "/")
    if "cores/" in t and ".dll" in t:
        t = t.replace(".dll", ".dylib")
    return t


def main() -> None:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/GBear")
    emu_dir = root / "source" / "GBear" / "Emulation" / "Emulators"
    out = Path(__file__).resolve().parent.parent / "Sources" / "GBearKit" / "Resources" / "BuiltinEmulatorCatalog.json"
    if not emu_dir.is_dir():
        print(f"Missing GBear emulators dir: {emu_dir}", file=sys.stderr)
        sys.exit(1)

    records = []
    for yaml_path in sorted(emu_dir.glob("*/emulator.yaml")):
        try:
            raw = yaml_path.read_text(encoding="utf-8")
            data = yaml.safe_load(raw)
        except Exception as e:
            print(f"Skip {yaml_path}: {e}", file=sys.stderr)
            continue
        if not isinstance(data, dict):
            continue
        emu_id = data.get("Id") or yaml_path.parent.name
        emu_name = data.get("Name") or emu_id
        website = data.get("Website")
        profiles = data.get("Profiles") or []
        if not isinstance(profiles, list):
            continue
        for prof in profiles:
            if not isinstance(prof, dict):
                continue
            args = prof.get("StartupArguments")
            if not args:
                continue
            args_str = fix_mac_launch_arguments(str(args))
            pname = prof.get("Name") or "Default"
            platforms = prof.get("Platforms") or []
            if not isinstance(platforms, list):
                platforms = []
            exts = prof.get("ImageExtensions") or []
            if not isinstance(exts, list):
                exts = []
            exe_hint = prof.get("StartupExecutable")
            catalog_id = len(records)
            records.append(
                {
                    "catalogId": catalog_id,
                    "emulatorId": str(emu_id),
                    "emulatorName": str(emu_name),
                    "website": website,
                    "profileName": str(pname),
                    "startupArguments": args_str,
                    "platforms": [str(p) for p in platforms],
                    "imageExtensions": [str(x) for x in exts],
                    "startupExecutableHint": str(exe_hint) if exe_hint else None,
                }
            )

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(records, indent=0, ensure_ascii=False), encoding="utf-8")
    print(f"Wrote {len(records)} profiles to {out}")


if __name__ == "__main__":
    main()

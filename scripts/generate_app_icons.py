#!/usr/bin/env python3
"""Export desktop app icons from the ImageGen source (requires Pillow).

Run from any directory: python3 scripts/generate_app_icons.py
Only resizing is applied; the source artwork and transparency are preserved.
"""

from pathlib import Path

from PIL import Image


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    branding = root / "assets" / "branding"
    source = branding / "app-icon-source.png"
    mac_icons = root / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    windows_icon = root / "windows/runner/resources/app_icon.ico"

    with Image.open(source) as image:
        if image.width != image.height:
            raise ValueError("The app icon source must be square")
        icon = image.convert("RGBA")

    for size in (16, 32, 64, 128, 256, 512, 1024):
        resized = icon.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(mac_icons / f"app_icon_{size}.png")
        if size in (128, 256):
            resized.save(branding / f"app-icon-{size}.png")

    icon.save(
        windows_icon,
        format="ICO",
        sizes=[(size, size) for size in (16, 24, 32, 48, 64, 128, 256)],
    )
    print(f"Exported desktop app icons from {source} ({icon.width}×{icon.height})")


if __name__ == "__main__":
    main()

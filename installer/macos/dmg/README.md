# DMG Assets

This folder contains assets for the macOS DMG installer.

## Required Files

### Background Images

The DMG window displays a custom background image guiding users through installation.

| File | Dimensions | Purpose |
|------|------------|---------|
| `background.png` | 600 x 420 px | Standard resolution background |
| `background@2x.png` | 1200 x 840 px | Retina resolution background |

**Design Guidelines:**
- Include visual guides showing:
  - Drag SecureGuard.app to Applications (left side)
  - Double-click PKG installer (bottom center)
- Use the SecureGuard brand colors
- Keep design simple and clear
- Leave space for icons at these positions:
  - SecureGuard.app: (150, 180)
  - Applications: (450, 180)
  - Install PKG: (300, 340)

### Volume Icon (Optional)

| File | Format | Purpose |
|------|--------|---------|
| `VolumeIcon.icns` | macOS ICNS | Custom icon for mounted volume |

Generate from app icon using:
```bash
# From a 1024x1024 PNG
iconutil -c icns icon.iconset
```

## Creating Background Images

You can create backgrounds using:

1. **Figma/Sketch**: Design with proper dimensions
2. **ImageMagick**: Generate programmatically
3. **Preview.app**: Simple editing on macOS

Example ImageMagick command for a solid background:
```bash
convert -size 600x420 xc:'#1a1a2e' \
    -fill white -pointsize 18 \
    -draw "text 100,400 'Drag SecureGuard to Applications'" \
    background.png
```

## Testing

After adding images, run the build script to verify:
```bash
./build-dmg.sh 1.0.0
open build/SecureGuard-1.0.0-macOS.dmg
```

# Assets Documentation

## Icons

### App Icon
**File**: `icons/app-icon-1024.png`
- **Size**: 1024x1024px
- **Format**: PNG RGBA
- **Description**: Main Majik logo - unicorn mascot for Magic Unicorn
- **Usage**: App icon, Mac App Store listing, marketing materials

**Required Icon Sizes**:
- [x] 1024x1024 - App Store (`app-icon-1024.png`)
- [x] 512x512 - macOS app icon (`app-icon-512.png`)
- [x] 256x256 - macOS app icon (`app-icon-256.png`)
- [x] 128x128 - macOS app icon (`app-icon-128.png`)
- [x] 64x64 - macOS app icon (`app-icon-64.png`)
- [x] 32x32 - macOS app icon, MenuBar (`app-icon-32.png`)
- [x] 16x16 - macOS app icon, MenuBar (`app-icon-16.png`)

**Generation Command**:
```bash
# Use sips or third-party tool to generate all sizes from app-icon-1024.png
sips -z 512 512 app-icon-1024.png --out app-icon-512.png
sips -z 256 256 app-icon-1024.png --out app-icon-256.png
sips -z 128 128 app-icon-1024.png --out app-icon-128.png
sips -z 64 64 app-icon-1024.png --out app-icon-64.png
sips -z 32 32 app-icon-1024.png --out app-icon-32.png
sips -z 16 16 app-icon-1024.png --out app-icon-16.png
```

---

## Images

**Planned UI Images:**
- [ ] Splash screen (Majik welcome screen)
- [ ] Empty state illustrations (Majik encouraging)
- [ ] Tutorial step images
- [ ] Error state illustrations (Majik apologizing)
- [ ] App Store screenshots (5-10 images)

---

## Sounds

**Planned UI Sounds:**
- [ ] Generation complete notification sound
- [ ] Error/warning sound
- [ ] Success chime
- [ ] Majik greeting sound (voice?)

---

## Branding

**Colors:**
- Primary: Magic Unicorn purple/rainbow theme
- Secondary: Music-related accents
- Backgrounds: Dark mode support

**Typography:**
- System San Francisco (macOS default)
- Monospace for technical parameters

**Voice/Tone:**
- Friendly and magical
- Encouraging and supportive
- Playful unicorn theme

---

**Last Updated**: February 7, 2026

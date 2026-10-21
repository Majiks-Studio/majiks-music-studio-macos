Majiks Studio v1.1.8
================================

Welcome to Majiks Studio! 🦄

AI-POWERED MUSIC GENERATION FOR macOS

REQUIREMENTS:
-------------
• macOS 14.0 (Sonoma) or later
• ACE-Step 1.5 (for music generation)
• OpenRouter API key or local MLX LLM

INSTALLATION:
-------------
⚠️  IMPORTANT: This app is signed and notarized by Apple.
    You should be able to open it normally after dragging to Applications.

METHOD 1 (Recommended):
1. Extract the ZIP file
2. Open Terminal (Applications → Utilities → Terminal)
3. Run this command to remove the quarantine flag:

   xattr -cr ~/Downloads/Majiks\ Studio.app

   (Adjust path if you extracted it elsewhere)

4. Drag "Majiks Studio.app" to your Applications folder
5. Double-click to open

METHOD 2 (Right-click):
1. Extract the ZIP and drag app to Applications folder
2. Right-click (or Control-click) the app → "Open"
3. If you see "Open Anyway" button, click it
4. If you see "damaged" error, use the notarized build from the latest release

METHOD 3 (System Settings):
1. Try to open the app (it will fail)
2. Go to System Settings → Privacy & Security
3. Look for message about "Majiks Studio"
4. Click "Open Anyway" button
5. If still blocked, use Method 1

SETUP:
------
1. Install ACE-Step 1.5 (REQUIRED for music generation):

   git clone https://github.com/hyperbayse/ACE-Step-1.5.git
   cd ACE-Step-1.5
   # Follow their setup instructions

   The app auto-detects: ~/ACE-Step-1.5/.venv/bin/python

2. First Launch:
   - Open Majiks Studio
   - Click Settings tab
   - Enter your license key (included with purchase)
   - Configure LLM provider (OpenRouter API key recommended)
   - Start creating music!

FEATURES:
---------
✨ Chat with Majik AI to describe your music vision
🎚️ Studio interface with precise parameter control
📚 3-column library browser (Artist → Album → Track)
🎵 Export to WAV, MP3, or FLAC formats
⭐ Rate and organize your tracks
🪄 AI-powered auto-naming and metadata
🎨 Custom artwork support (artist photos, album art)

LICENSING:
----------
This is a PAID LICENSE VERSION ($29).

Your license key (format: MS1-xxxxxx-xxxxxx) was emailed to you.

To activate:
1. Open Settings → License tab
2. Paste your key
3. Click "Activate License"

Demo features (no license needed): Browse UI, play tracks, configure settings
Full features (license required): Music generation, cloud LLM chat

SUPPORT:
--------
Website: https://magicunicorn.tech/majiks-studio
Email: support@magicunicorn.tech
GitHub: https://github.com/hyperbayse/ACE-Step-Music-Generation

TROUBLESHOOTING:
----------------
Q: "Majiks Studio.app is damaged and can't be opened"?
A: This is usually a quarantine/Gatekeeper issue during download. FIX:

   Open Terminal and run:
   xattr -cr "/Applications/Majiks Studio.app"

   Then try opening the app again. This removes the quarantine flag.

   Alternative (disables Gatekeeper completely - not recommended):
   sudo spctl --master-disable

Q: Still won't open after xattr command?
A: Make sure you:
   1. Extracted the ZIP completely (don't open from inside ZIP)
   2. Used the correct path to the app
   3. Dragged it to Applications folder first

   You can also try:
   cd /Applications
   xattr -cr Majiks\ Studio.app
   open Majiks\ Studio.app

Q: Python backend not found?
A: Install ACE-Step 1.5 to ~/ACE-Step-1.5/ exactly:
   git clone https://github.com/hyperbayse/ACE-Step-1.5.git ~/ACE-Step-1.5

Q: License key invalid?
A: Check email for correct format: MS1-xxxxxx-xxxxxx
   Contact support if issues persist

Q: Need a signed version?
A: This release is signed and notarized. If your organization still blocks it, contact support@magicunicorn.tech.

Copyright © 2026 Magic Unicorn Unconventional Technology & Stuff Inc.
All rights reserved.

Built with ❤️ using Swift, SwiftUI, Python, and ACE-Step 1.5

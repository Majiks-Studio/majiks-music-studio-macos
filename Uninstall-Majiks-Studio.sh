#!/bin/bash

echo "🗑️  Uninstalling Majik's Music Studio..."
echo ""
echo "This will remove:"
echo "  • The application"
echo "  • Your music library and generated files"
echo "  • Settings and preferences"
echo "  • License key"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "Removing Majik's Music Studio..."

# 1. Delete the app
echo "1️⃣  Removing application..."
rm -rf "/Applications/Majiks Studio.app"
echo "   ✅ App removed"

# 2. Clear UserDefaults
echo "2️⃣  Removing preferences..."
killall cfprefsd 2>/dev/null || true
sleep 1
defaults delete com.magicunicorn.majiksmusicstudio 2>/dev/null || true
rm -f ~/Library/Preferences/com.magicunicorn.majiksmusicstudio.plist
echo "   ✅ Preferences removed"

# 3. Delete Keychain entry (license)
echo "3️⃣  Removing license from Keychain..."
security delete-generic-password -s "com.majik.musicstudio.license" -a "license_key" 2>/dev/null || true
echo "   ✅ License removed"

# 4. Delete Application Support (library, settings, generated files)
echo "4️⃣  Removing library and generated files..."
rm -rf ~/Library/Application\ Support/MajiksMusicStudio
echo "   ✅ Library removed"

echo ""
echo "✅ Majik's Music Studio has been completely uninstalled."
echo ""
echo "If you reinstall later, you'll start fresh with a clean setup."
echo ""

#!/bin/bash
VERSIONNUM="0.0.16"
VERSION="BarryKN Big Sur Micropatcher Unpatcher v$VERSIONNUM"

echo $VERSION
# Add a blank line of output to make things easier on the eyes.
echo

# Add disclaimer
echo "It's really best to recreate the USB stick using createinstallmedia,"
echo "but this takes much less time and is useful for patcher development."
echo

VOLUME='/Volumes/Install macOS Big Sur Beta'
CORESERVICES="$VOLUME/System/Library/CoreServices/PlatformSupport.plist"
BOOT_PLIST="$VOLUME/Library/Preferences/SystemConfiguration/com.apple.Boot.plist"
PAYLOADS="$VOLUME/payloads"

# Allow the user to drag-and-drop the USB stick in Terminal, to specify the
# path to the USB stick in question. (Otherwise it will try a hardcoded path
# for beta 2 and up, followed by a hardcoded path for beta 1.)
if [ -z "$1" ]
then
    VOLUME='/Volumes/Install macOS Big Sur Beta'
    if [ ! -d "$VOLUME/Install macOS Big Sur Beta.app" ]
    then
        # Check for beta 1 before giving up
        VOLUME='/Volumes/Install macOS Beta'
        if [ ! -d "$VOLUME/Install macOS Beta.app" ]
        then
            echo "Failed to locate Big Sur recovery USB stick for unpatching."
            echo
            echo "Unpatcher cannot continue and will now exit."
            exit 1
        fi
    fi
else
    VOLUME="$1"
    if [ ! -d "$VOLUME/Install macOS"*.app ]
    then
        echo "Failed to locate Big Sur recovery USB stick for unpatching."
        echo "Make sure you specified the correct volume. You may also try"
        echo "not specifying a volume and allowing the unpatcher to find"
        echo "the volume itself."
        echo
        echo "Unpatcher cannot continue and will now exit."
        exit 1
    fi
fi

if [ ! -e "$VOLUME/Patch-Version.txt" ]
then
    echo 'Patch not detected on USB stick, but proceeding with unpatch anyway.'
    echo 'This should do no harm. Any subsequent error messages are,'
    echo 'in all likelihood, harmless.'
    echo
fi

# Undo the boot-time compatibility check patch, if present
echo 'Checking for boot-time compatibility check patch (v0.0.1/v0.0.2).'
if [ -e "$CORESERVICES.inactive" ]
then
    echo 'Removing boot-time compatibility check patch.'
    mv "$CORESERVICES.inactive" "$CORESERVICES"
else
    echo 'Boot-time compatibility check not present; continuing.'
fi

echo

# Undo the com.apple.Boot.plist patch, if present
echo 'Checking for com.apple.Boot.plist patch (v0.0.3+).'
if [ -e "$BOOT_PLIST.original" ]
then
    echo 'Removing com.apple.Boot.plist patch.'
    cat "$BOOT_PLIST.original" > "$BOOT_PLIST"
    rm "$BOOT_PLIST.original"
else
    echo 'com.apple.Boot.plist patch not present; continuing.'
fi

echo
echo 'Removing kexts, shell scripts, and patcher version info.'
# For v0.0.9 and earlier
rm -rf "$PAYLOADS"/*.kext
# For v0.0.10 and later
rm -rf "$PAYLOADS"/kexts
rm -f "$PAYLOADS"/*.kext.zip "$PAYLOADS"/*.sh "$VOLUME/Patch-Version.txt"

# Now that the patcher is going to add the dylib itself, go ahead and
# remove that too.
echo 'Remvoing Hax dylibs...'
rm -f "$PAYLOADS"/Hax*.dylib
rm -rf "$PAYLOADS"/Hax*.app

echo
echo 'Syncing.'
sync

echo
echo 'Unpatcher finished.'

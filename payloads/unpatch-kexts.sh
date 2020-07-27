#!/bin/bash

### begin function definitions ###
# There's only one function for now, but there will probably be more
# in the future.

kmutilErrorCheck () {
    if [ $? -ne 0 ]
    then
        echo 'kmutil failed. See above output for more information.'
        echo 'unpatch-kexts.sh cannot continue.'
        exit 1
    fi
}

### end function definitions ###

IMGVOL="/Volumes/Image Volume"
# Make sure we're inside the recovery environment. This may not be the best
# way to check, but it's simple and should work in the real world.
if [ ! -d "$IMGVOL" ]
then
    echo 'You must use this script from inside the Recovery environment.'
    echo 'Please restart your Mac from the patched Big Sur installer'
    echo 'USB drive, then open Terminal and try again.'
    echo
    echo '(The ability to use this script without rebooting into the'
    echo 'Recovery environment is planned for a future patcher release.)'
    exit 1
fi


# We're uninstalling *all* of the patched kexts that can be installed
# by patch-kexts.sh. If there's any reason to add partial uninstallation,
# that can be implemented in the future.
echo 'Uninstalling patched kexts on volume:'
VOLUME="$1"
echo "$VOLUME"
echo

# Make sure a volume has been specified. (Without this, other error checks
# eventually kick in, but the error messages get confusing.)
if [ -z "$VOLUME" ]
then
    echo 'You must specify a target volume (such as /Volumes/Macintosh\ HD)'
    echo 'on the command line.'
    exit 1
fi

# Sanity checks to make sure that the specified $VOLUME isn't an obvious mistake

# First, make sure the volume exists. (If it doesn't exist, the next check
# will fail anyway, but having a separate check for this case might make
# troubleshooting easier.
if [ ! -d "$VOLUME" ]
then
    echo "Unable to find the volume."
    echo "Cannot proceed. Make sure you specified the correct volume."
    exit 1
fi

# Next, check that the volume has /System/Library/Extensions (i.e. make sure
# it's actually the system volume and not the data volume or something).
# DO NOT check for /System/Library/CoreServices here, or Big Sur data drives
# as well as system drives will pass the check!
if [ ! -d "$VOLUME/System/Library/Extensions" ]
then
    echo "Unable to find /System/Library/Extensions on the volume."
    echo "Cannot proceed. Make sure you specified the correct volume."
    echo "(Make sure to specify the system volume, not the data volume.)"
    exit 1
fi

# Check that the $VOLUME has macOS build 20*. This version check will
# hopefully keep working even after Apple bumps the version number to 11.
SVPL="$VOLUME"/System/Library/CoreServices/SystemVersion.plist
SVPL_VER=`grep '<string>[0-9][0-9][.]' "$SVPL" | sed -e 's@^.*<string>@@' -e 's@</string>@@' | uniq -d`
SVPL_BUILD=`grep '<string>[0-9][0-9][A-Z]' "$SVPL" | sed -e 's@^.*<string>@@' -e 's@</string>@@'`

if echo $SVPL_BUILD | grep -q '^20'
then
    echo -n "Volume appears to have a Big Sur installation (build" $SVPL_BUILD
    echo "). Continuing."
else
    if [ -z "$SVPL_VER" ]
    then
        echo 'Unable to detect macOS version on volume. Make sure you chose'
        echo 'the correct volume. Or, perhaps a newer patcher is required.'
    else
        echo 'Volume appears to have an older version of macOS. Probably'
        echo 'version' "$SVPL_VER" "build" "$SVPL_BUILD"
        echo 'Please make sure you specified the correct volume.'
    fi

    exit 1
fi

# Also check to make sure $VOLUME is an actual volume and not a snapshot.
# Maybe I'll add code later to handle the snapshot case, but in the recovery
# environment for Developer Preview 1, I've always seen it mount the actual
# volume and not a snapshot.
DEVICE=`df "$VOLUME" | tail -1 | sed -e 's@ .*@@'`
echo 'Volume is mounted from device: ' $DEVICE
# The following code is somewhat convoluted for just checking if there's
# a slice within a slice, but it should make things easier for future
# code that will actually handle this case.
POPSLICE=`echo $DEVICE | sed -E 's@s[0-9]+$@@'`
POPSLICE2=`echo $POPSLICE | sed -E 's@s[0-9]+$@@'`

if [ $POPSLICE = $POPSLICE2 ]
then
    echo 'Mounted volume is an actual volume, not a snapshot. Proceeding.'
else
    echo
    echo 'ERROR:'
    echo 'Mounted volume appears to be an APFS snapshot, not the underlying'
    echo 'volume. The patcher was not expecting to encounter this situation'
    echo 'within the Recovery environment, and an update to the patcher will'
    echo 'be required. Kext installation will not proceed.'
    exit 1
fi

# (The following block of code may not be necessary for the kext patch
# uninstaller, but there's nothing to gain and definitely some risk if
# we remove it.)
#
# It's likely that at least one of these was reenabled during installation.
# But as we're in the recovery environment, there's no need to check --
# we'll just redisable these. If they're already disabled, then there's
# no harm done.
csrutil disable
csrutil authenticated-root disable


# Remount the volume read-write
echo "Remounting volume as read-write..."
if ! mount -uw "$VOLUME"
then
    echo "Remount failed. Kext installation cannot proceed."
    exit 1
fi

# Now remove the new kexts and move the old ones back into place.
pushd "$VOLUME/System/Library/Extensions"

if [ -n "`ls -1d *.original`" ]
then
    for x in *.original
    do
        BASENAME=`echo $x|sed -e 's@.original@@'`
        echo 'Unpatching' $BASENAME
        rm -rf "$BASENAME"
        mv "$x" "$BASENAME"
    done
fi

# And remove kexts whch did not overwrite newer versions.
# (This was originally inside the if-then block, but that turned out to
# be fragile when trying to test bug fixes to this script during
# development.)
echo 'Removing kexts for Intel HD 3000 graphics support'
rm -rf AppleIntelHD3000* AppleIntelSNB*
echo 'Removing LegacyUSBInjector'
rm -rf LegacyUSBInjector.kext
echo 'Removing nvenet'
rm -rf IONetworkingFamily.kext/Contents/Plugins/nvenet.kext
echo 'Reactivating telemetry plugin'
mv -f "$VOLUME/System/Library/UserEventPlugins/com.apple.telemetry.plugin.disabled" "$VOLUME/System/Library/UserEventPlugins/com.apple.telemetry.plugin"

popd


# Update the kernel/kext collections.
# kmutil *must* be invoked separately for boot and system KCs when
# LegacyUSBInjector is being used, or the injector gets left out, at least
# as of Big Sur beta 2. So, we'll always do it that way (even without
# LegacyUSBInjector, it shouldn't do any harm).
#
# I suspect it's not supposed to require the chroot, but I was getting weird
# "invalid argument" errors, and chrooting it eliminated those errors.
# BTW, kmutil defaults to "--volume-root /" according to the manpage, so
# it's probably redundant, but whatever.
echo 'Using kmutil to rebuild boot collection...'
chroot "$VOLUME" kmutil create -n boot \
    --kernel /System/Library/Kernels/kernel \
    --volume-root / \
    --boot-path /System/Library/KernelCollections/BootKernelExtensions.kc
kmutilErrorCheck

# When creating SystemKernelExtensions.kc, kmutil requires *both* --boot-path
# and --system-path!
echo 'Using kmutil to rebuild system collection...'
chroot "$VOLUME" kmutil create -n sys \
    --kernel /System/Library/Kernels/kernel \
    --volume-root / \
    --system-path /System/Library/KernelCollections/SystemKernelExtensions.kc \
    --boot-path /System/Library/KernelCollections/BootKernelExtensions.kc
kmutilErrorCheck

# The way you control kcditto's *destination* is by choosing which volume
# you run it *from*. I'm serious. Read the kcditto manpage carefully if you
# don't believe me!
"$VOLUME/usr/sbin/kcditto"

bless --folder "$VOLUME"/System/Library/CoreServices --bootefi --create-snapshot

echo 'Uninstalled patch kexts successfully.'

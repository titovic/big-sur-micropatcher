#!/bin/bash

### begin function definitions ###
# There's only one function for now, but there will probably be more
# in the future.

kmutilErrorCheck () {
    if [ $? -ne 0 ]
    then
        echo 'kmutil failed. See above output for more information.'
        echo
        echo "Do you still want to proceed?"
        read -p "(press y to continue):" -n 1 -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo 'patch-kexts.sh will now exit.'
            exit 1
        fi
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

# See if there's an option on the command line. If so, put it into OPT.
if echo "$1" | grep -q '^--'
then
    OPT="$1"
    shift
fi

# Figure out which kexts we're installing and where we're installing
# them to.

if [ "x$OPT" = "x--2011-no-wifi" ]
then
    INSTALL_WIFI="NO"
    INSTALL_HDA="YES"
    INSTALL_HD3000="YES"
    INSTALL_LEGACY_USB="YES"
    echo 'Installing AppleHDA, HD3000, and LegacyUSBInjector to:'
elif [ "x$OPT" = "x--2011" ]
then
    INSTALL_WIFI="YES"
    INSTALL_HDA="YES"
    INSTALL_HD3000="YES"
    INSTALL_LEGACY_USB="YES"
    echo 'Installing IO80211Family, AppleHDA, HD3000, and LegacyUSBInjector to:'
elif [ "x$OPT" = "x--all" ]
then
    INSTALL_WIFI="YES"
    INSTALL_HDA="YES"
    INSTALL_HD3000="YES"
    INSTALL_LEGACY_USB="YES"
    INSTALL_NVENET="YES"
    DEACTIVATE_TELEMETRY="YES"
    echo 'Installing all kext patches to:'
elif [ "x$OPT" = "x--hda" ]
then
    INSTALL_WIFI="YES"
    INSTALL_HDA="YES"
    INSTALL_HD3000="NO"
    echo 'Installing IO80211Family and AppleHDA to:'
else
    INSTALL_WIFI="YES"
    INSTALL_HDA="NO"
    INSTALL_HD3000="NO"
    echo 'Installing IO80211Family to:'
fi

#Drop any trailing '/' as it may cause trouble later (the mount command will...)
VOLUME=echo "$1"|sed -e 's@/$@@'
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

# Move the old kext out of the way, or delete if needed. Then unzip the
# replacement.
pushd "$VOLUME/System/Library/Extensions"

if [ "x$INSTALL_WIFI" = "xYES" ]
then
    if [ -d IO80211Family.kext.original ]
    then
        rm -rf IO80211Family.kext
    else
        mv IO80211Family.kext IO80211Family.kext.original
    fi

    unzip -q "$IMGVOL/kexts/IO80211Family.kext.zip"
    rm -rf __MACOSX
    chown -R 0:0 IO80211Family.kext
    chmod -R 755 IO80211Family.kext
fi

if [ "x$INSTALL_HDA" = "xYES" ]
then
    if [ -d AppleHDA.kext.original ]
    then
        rm -rf AppleHDA.kext
    else
        mv AppleHDA.kext AppleHDA.kext.original
    fi

    unzip -q "$IMGVOL/kexts/AppleHDA-17G14019.kext.zip"
    chown -R 0:0 AppleHDA.kext
    chmod -R 755 AppleHDA.kext
fi

if [ "x$INSTALL_HD3000" = "xYES" ]
then
    rm -rf AppleIntelHD3000* AppleIntelSNB*

    unzip -q "$IMGVOL/kexts/HD3000-17G14019.zip"
    chown -R 0:0 AppleIntelHD3000* AppleIntelSNB*
    chmod -R 755 AppleIntelHD3000* AppleIntelSNB*
fi

if [ "x$INSTALL_LEGACY_USB" = "xYES" ]
then
    rm -rf LegacyUSBInjector.kext

    unzip -q "$IMGVOL/kexts/LegacyUSBInjector.kext.zip"
    chown -R 0:0 LegacyUSBInjector.kext
    chmod -R 755 LegacyUSBInjector.kext

    # parameter for kmutil later on
    BUNDLE_PATH="--bundle-path /System/Library/Extensions/LegacyUSBInjector.kext"
fi

if [ "x$INSTALL_NVENET" = "xYES" ]
then
    pushd IONetworkingFamily.kext/Contents/Plugins
    rm -rf nvenet.kext
    unzip -q "$IMGVOL/kexts/nvenet-17G14019.kext.zip"
    chown -R 0:0 nvenet.kext
    chmod -R 755 nvenet.kext
    popd
fi

popd

if [ "x$DEACTIVATE_TELEMETRY" = "xYES" ]
then
    pushd "$VOLUME/System/Library/UserEventPlugins"
    mv -f com.apple.telemetry.plugin com.apple.telemetry.plugin.disabled
    popd
fi

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
echo 'Using kmutil to rebuild BOOT collection...'
chroot "$VOLUME" kmutil create -n boot \
    --kernel /System/Library/Kernels/kernel \
    --volume-root / $BUNDLE_PATH \
    --boot-path /System/Library/KernelCollections/BootKernelExtensions.kc
kmutilErrorCheck

# When creating SystemKernelExtensions.kc, kmutil requires *both* --boot-path
# and --system-path!
echo 'Using kmutil to rebuild SYSTEM collection...'
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

# Create a new snapshot we'll boot and contain our kernel changes
bless --folder "$VOLUME"/System/Library/CoreServices --bootefi --create-snapshot

echo 'Installed patch kexts successfully.'

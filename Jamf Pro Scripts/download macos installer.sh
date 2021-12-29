#!/bin/zsh

# Script to download the latest macOS installer
# richard@richard-purves.com - 12-29-2021 - v1.7

# Logging output to a file for testing
#time=$( date "+%d%m%y-%H%M" )
#set -x
#logfile=/Users/Shared/oscache-"$time".log
#exec > $logfile 2>&1

exitcode=0

# Any OS specified?
downloados="$4"
[ -z "$downloados" ] && { /bin/echo "No OS version specified. Defaulting to 12.1"; downloados="12.1"; }

# Check if we're already running
if [ -f "/private/tmp/.downloadmacos" ];
then
	# Work out last modified date on the touch file. Convert to epoch.
    # If it's above 7200 it's been over two hours. We can ignore.
	currentdate=$( /bin/date -j -f "%a %b %d %T %Z %Y" "$( /bin/date )" "+%s" )
	lastmodified=$( /usr/bin/stat -x /private/tmp/.downloadmacos | grep "Access: " | cut -d" " -f2- )
    lastmodepoch=$( /bin/date -j -f "%a %b %d %T %Y" "$lastmodified" "+%s" )
    diff="$((currentdate-lastmodepoch))"
    echo "Difference: $diff"

    [ "$diff" -lt 7200 ] && { echo "Download already in progress."; exit 0; }
fi

# Place a check file to stop this running multiple times
[ ! -f "/private/tmp/.downloadmacos" ] && /usr/bin/touch /private/tmp/.downloadmacos

# Find and delete any existing macOS installers
/usr/bin/find /Applications -iname "Install macOS*" -type d -maxdepth 1 -exec rm -rf {} \;

# A quick disk space check
diskinfo=$( /usr/sbin/diskutil info -plist / )
freespace=$( /usr/libexec/PlistBuddy -c "Print :APFSContainerFree" /dev/stdin <<< "$diskinfo" 2>/dev/null || /usr/libexec/PlistBuddy -c "Print :FreeSpace" /dev/stdin <<< "$diskinfo" 2>/dev/null || /usr/libexec/PlistBuddy -c "Print :AvailableSpace" /dev/stdin <<< "$diskinfo" 2>/dev/null )
requiredspace=$(( 45 * 1000 ** 3 ))

if [ "$freespace" -ge "$requiredspace" ];
then
	 /bin/echo "Disk Check: OK - $((freespace / 1000 ** 3)) GB Free Space Detected"
else
    /bin/echo "Disk Check: ERROR - $((freespace / 1000 ** 3)) GB Free Space Detected."
	exit 1
fi

# Reset the softwareupdate daemon
/usr/bin/defaults delete /Library/Preferences/com.apple.SoftwareUpdate.plist
rm /Library/Preferences/com.apple.SoftwareUpdate.plist
/bin/launchctl kickstart -k system/com.apple.softwareupdated

# Now use softwareupdate to cache the latest app bundle
echo "macOS 10.15 or later"
echo "Downloading macOS $downloados from Software Update"
( cd /Applications ; /usr/sbin/softwareupdate --fetch-full-installer --full-installer-version "$downloados" )
[ ! $? = "0" ] && exitcode=1

# Now find and hide the installer as people keep deleting it
app=$( /usr/bin/find /Applications -iname "Install macOS*" -type d -maxdepth 1 )
[ ! -z "$app" ] && /usr/bin/chflags hidden "$app"

# Clean our download flag file
rm -f /private/tmp/.downloadmacos

# Run a recon
/usr/local/bin/jamf recon

exit $exitcode

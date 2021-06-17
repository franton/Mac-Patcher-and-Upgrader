#!/bin/zsh

# Script to retrieve latest macOS installer
# richard@richard-purves.com - 06-15-2021 - v1.2

# Any OS specified?
downloados="$4"
[ -z "$64" ] && { /bin/echo "No OS version specified. Defaulting to 11.4"; downloados="11.4"; }

# Check if we're already running
if [ -f "/private/tmp/.downloadmacos" ];
then
	# Work out last modified date on the touch file. Convert to epoch.
    # If it's above 86400 it's been over a day. We can ignore.
	currentdate=$( /bin/date -j -f "%a %b %d %T %Z %Y" "$( /bin/date )" "+%s" )
	lastmodified=$( /usr/bin/stat -x /private/tmp/.downloadmacos | grep "Access: " | cut -d" " -f2- )
    lastmodepoch=$( /bin/date -j -f "%a %b %d %T %Y" "$lastmodified" "+%s" )
    diff="$((currentdate-lastmodepoch))"

    [ "$diff" -ge 86400 ] && { echo "Download already in progress."; exit 0; }
fi

# Place a check file to stop this running multiple times
[ ! -f "/private/tmp/.downloadmacos" ] && /usr/bin/touch /private/tmp/.downloadmacos

# Find all macOS installers and place into an array
/usr/bin/find /Applications -iname "Install macOS*" -type d -maxdepth 1 -exec rm -rf {} \;

# Reset the softwareupdate daemon
/usr/bin/defaults delete /Library/Preferences/com.apple.SoftwareUpdate.plist
rm /Library/Preferences/com.apple.SoftwareUpdate.plist
/bin/launchctl kickstart -k system/com.apple.softwareupdated

# Now use softwareupdate to cache the latest app bundle
( cd /Applications ; /usr/sbin/softwareupdate --fetch-full-installer --full-installer-version "$downloados" )

# Clear download flag
/bin/rm /private/tmp/.downloadmacos

exit 0

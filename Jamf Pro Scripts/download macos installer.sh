#!/bin/zsh

# Script to retrieve latest macOS installer
# richard@richard-purves.com - 05-12-2021 - v1.0

# Stop IFS splitting on spaces in filenames
OIFS=$IFS
IFS=$'\n'

# Find all macOS installers and place into an array
apps=($( /usr/bin/find /Applications -iname "Install macOS*" -type d -maxdepth 1 ))

# Process array one by one to remove any out of date ones
for i ($apps);
do
	/bin/rm -rf "$i"
done

# Reset the softwareupdate daemon.
# It occasionally needs a kick to work reliably.
/usr/bin/defaults delete /Library/Preferences/com.apple.SoftwareUpdate.plist
rm /Library/Preferences/com.apple.SoftwareUpdate.plist
/bin/launchctl kickstart -k system/com.apple.softwareupdated

# Now use softwareupdate to cache the latest app bundle    
( cd /Applications ; /usr/sbin/softwareupdate --fetch-full-installer --full-installer-version 11.3.1 )

# Reset IFS
IFS=$OIFS

exit 0
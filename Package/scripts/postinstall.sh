#!/bin/zsh

# Post installation script

# Work out locations of files
pb=$( /usr/bin/find /Applications -type d -iname "Progress.app" -maxdepth 2 )
ld=$( find /Library/LaunchDaemons -iname "*apppatcher*.plist" -type f -maxdepth 1 )

# Clear any quarantine flags because they randomly set for some reason best known to Apple
/usr/bin/xattr -r -d com.apple.quarantine $pb
/usr/bin/xattr -r -d com.apple.quarantine $ld

# Hide the progress app
/usr/bin/chflags hidden "$pb"

# Finally load the launchdaemon
/bin/launchctl load "$ld"

exit

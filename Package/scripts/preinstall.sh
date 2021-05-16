#!/bin/zsh

# Remove any existing patch setup preinstall script

# Work out locations of files
/usr/bin/find /Applications -type d -iname "Progress.app" -maxdepth 2 -exec rm -rf {} \;
/usr/bin/find /Library/LaunchDaemons -iname "*apppatcher*.plist" -type f -maxdepth 1 -exec rm -f {} \;

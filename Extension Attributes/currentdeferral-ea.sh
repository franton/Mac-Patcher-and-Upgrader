#!/bin/zsh

# EA to show how many deferrals are currently used

# Reads from the deferral file on the mac if it exists
# We return an output as an integer only for proper audit and processing later.

test=$( /usr/bin/plutil -extract deferral raw -o - /usr/local/corp/cachedapps/appupdates.plist )

if [ ! -z "$test" ];
then
	echo "<result>$test</result>"
else
	echo "<result>0</result>"
fi

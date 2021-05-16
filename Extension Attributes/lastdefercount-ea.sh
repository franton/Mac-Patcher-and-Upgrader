#!/bin/zsh

# EA to show how many deferrals were used at last update

# Reads from the deferral file on the mac if it exists
# We return an output as an integer only for proper audit and processing later.

test=$( /usr/bin/defaults read /usr/local/corp/cachedapps/appupdates.plist lastdeferral )

if [ ! -z "$test" ];
then
	echo "<result>$test</result>"
else
	echo "<result>0</result>"
fi

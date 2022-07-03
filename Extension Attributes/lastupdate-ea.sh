#!/bin/zsh

# EA to show the date of last update

# Reads from the deferral file on the mac if it exists
# We return an output as a Jamf compliant date YYYY-MM-DD hh:mm:ss

test=$( /usr/bin/plutil -extract lastupdate raw -o - /usr/local/corp/cachedapps/appupdates.plist | /usr/bin/tr 'T' ' ' | /usr/bin/tr -d "Z" )

if [ ! -z "$test" ];
then
	echo "<result>$test</result>"
else
	echo "<result>1970-01-01 09:00:00</result>"
fi

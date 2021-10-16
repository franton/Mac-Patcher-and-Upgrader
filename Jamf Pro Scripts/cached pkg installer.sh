#!/bin/zsh

# Main patching and installer script
# Meant to be run periodically from launchd on macOS endpoint.
# richard@richard-purves.com - 09-02-2021 - v1.9

# Logging output to a file for testing
#set -x
#logfile=/Users/Shared/cachedappinstaller.log
#exec > $logfile 2>&1

# Set user display messages here
msgtitlenewsoft="New Software Available"
msgprogresstitle="Updating Software"
msgosupgtitle="Upgrading macOS"
msgnewsoftware="Important software updates are available!

The following new software is ready for upgrade:"
msgnewsoftforced="Important software updates are available!

You have run out of allowed install deferrals.

The following software will be upgraded now:"
msgrebootwarning="Your computer now needs to restart to complete the updates."
msgpowerwarning="Your computer is about to upgrade installed software.

Please ensure you are connected to AC Power.

Once you are plugged in, please click the Proceed button."
msgosupgradewarning="Your computer will perform a major macOS upgrade.

Please ensure you are connected to AC Power.

Your computer will restart and the OS upgrade process will continue. It will take up to 90 minutes to complete.

IT IS VERY IMPORTANT YOU DO NOT INTERRUPT THIS PROCESS."

# Script variables here
alloweddeferral="5"
forcedupdate="0"
blockingapps=( "Microsoft PowerPoint" "Keynote" "zoom.us" )
silent="0"
waitroom="/Library/Application Support/JAMF/Waiting Room"
workfolder="/usr/local/corp"
infofolder="$workfolder/cachedapps"
imgfolder="$workfolder/imgs"
updatefilename="appupdates.plist"
updatefile="$infofolder/$updatefilename"
pbjson="/private/tmp/progressbar.json"
canceljson="/private/tmp/progresscancel.json"
installoutput="/private/tmp/installout.log"
stosout="/private/tmp/upgrade.log"
jsspkginfo="/private/tmp/jsspkginfo.tsv"

jssurl=$( /usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url )
jb=$( which jamf )
osa="/usr/bin/osascript"
pbapp="/Applications/Utilities/Progress.app"
pb="$pbapp/Contents/MacOS/Progress"
installiconpath="/System/Library/CoreServices/Installer.app/Contents/Resources"
updateicon="/System/Library/PreferencePanes/SoftwareUpdate.prefPane/Contents/Resources/SoftwareUpdate.icns"
currentuser=$( /usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk -F': ' '/[[:space:]]+Name[[:space:]]:/ { if ( $2 != "loginwindow" ) { print $2 }}' )
curuserid=$( id -u "$currentuser" )
homefolder=$( dscl . -read /Users/$currentuser NFSHomeDirectory | awk '{ print $2 }' )
bootvolname=$( /usr/sbin/diskutil info / | /usr/bin/awk '/Volume Name:/ { print substr($0, index($0,$3)) ; }' )

# Check that the info folder exists, create if missing and set appropriate permissions
/bin/mkdir -p "$infofolder"
/bin/chmod 755 "$infofolder"
/usr/sbin/chown root:wheel "$infofolder"

####################
#                  #
# Let's get to it! #
#                  #
####################

# Keep the mac awake while this runs.
/usr/bin/caffeinate -dis &

# Stop IFS splitting on spaces
OIFS=$IFS
IFS=$'\n'

# Is anyone logged in? Engage silent mode.
[[ "$currentuser" = "loginwindow" ]] || [[ -z "$currentuser" ]] && silent="1"

# Is the screen locked? Quit if so.
if [ "$(/usr/libexec/PlistBuddy -c "print :IOConsoleUsers:0:CGSSessionScreenIsLocked" /dev/stdin 2>/dev/null <<< "$(/usr/sbin/ioreg -n Root -d1 -a)")" = "true" ];
then
	echo "Screen Locked. Exiting."
	exit 0
else
	echo "Screen Unlocked."
fi

# Blocking application check here. Find the foreground app with lsappinfo assuming silent mode isn't engaged
if [[ "$silent" == "0" ]];
then
	foregroundapp=$( /usr/bin/lsappinfo list | /usr/bin/grep -B 4 "(in front)" | /usr/bin/awk -F '\\) "|" ASN' 'NF > 1 { print $2 }' )

	# check for blocking apps
	for app ($blockingapps)
	do
		if [[ "$app" == "$foregroundapp" ]];
		then
			echo "Blocking app: $app"
			exit 0
		fi
	done
fi

########################################
#
# Find and process any cached installers
#
########################################

# Do we have a temp file that still exists? Clear it if so to avoid duplicate entries
[ -f "$jsspkginfo" ] && /bin/rm "$jsspkginfo"

# Find all previously cached files
cachedpkg=($( find "$infofolder" -type f \( -iname "*.plist" ! -iname "$updatefilename" \) ))

# Did we find any? Quit if not.
[ ${#cachedpkg[@]} = 0 ] && { echo "No cached files found. Exiting."; exit 0; }

# Process the array of files into a tsv for later sorting
for pkgfilename ($cachedpkg)
do
	# Now read out all the info we've collected from the cache file.
	priority=$( /usr/bin/defaults read "${pkgfilename}" Priority )
	pkgname=$( /usr/bin/defaults read "${pkgfilename}" PkgName )
	displayname=$( /usr/bin/defaults read "${pkgfilename}" DisplayName )
	fullpath=$( /usr/bin/defaults read "${pkgfilename}" FullPath )
	reboot=$( /usr/bin/defaults read "${pkgfilename}" Reboot )
	feu=$( /usr/bin/defaults read "${pkgfilename}" FEU )
	fut=$( /usr/bin/defaults read "${pkgfilename}" FUT )
	osinstall=$( /usr/bin/defaults read "${pkgfilename}" OSInstaller )

	# Check for any spurious no name filenames. Skip if found.
    [[ "$pkgfilename" = ".plist" ]] && continue

	# Check to see if any of the critical fields are blank. Skip if so.
	[[ -z "$pkgname" ]] || [[ -z "$fullpath" ]] && continue

	# Check to see if we've a match in the cached folder. Skip if not.
	# We check for both file and directory in case of dmg, flat pkg or non flat pkg.
	[[ ! -f "$fullpath/$pkgname" ]] && [[ ! -d "$fullpath/$pkgname" ]] && continue

	# Store everything into a tsv temporary file
	echo -e "${priority}\t${pkgname}\t${displayname}\t${fullpath}\t${reboot}\t${feu}\t${fut}\t${osinstall}" >> "$jsspkginfo"

	# Clean up of variables before next loop or end of loop
	unset priority pkgname displayname fullpath reboot feu fut osinstall
done

# Did we even write out a tsv file
if [[ ! -f "$jsspkginfo" ]];
then
    # Output fail message, then clean up files and folders
	echo "No processed tsv file detected. Aborting."
	/usr/bin/find "$infofolder" -type f \( -iname "*.plist" ! -iname "$updatefilename" \) -exec rm {} \;
	/usr/bin/find "$waitroom" \( -iname \*.pkg -o -iname \*.cache.xml \) -exec rm {} \;
    exit 0
fi

# Sort the file using priority number, then alphabetical order on filename
/usr/bin/sort "$jsspkginfo" -o "$jsspkginfo"

# Check to see if there's a macOS installer
osinstall=$( /usr/bin/tail -n 1 "$jsspkginfo" | /usr/bin/cut -f2 -d$'\t' )
[[ "$osinstall" == *"Install macOS"* ]] && osinstall="1" || osinstall="0"

################################
#
# Prompt the user about updating
#
################################

# Do we have a defer file. Initialize one if not.
[ ! -f "$updatefile" ] && /usr/bin/defaults write "$updatefile" deferral -int 0

# Read deferral count
deferred=$( /usr/bin/defaults read "$updatefile" deferral )

# Work out icon path for osascript. It likes paths in the old : separated format
[ -f "$installiconpath/Installer.icns" ] && icon="$installiconpath/Installer.icns"
[ -f "$installiconpath/AppIcon.icns" ] && icon="$installiconpath/AppIcon.icns"
iconposix=$( echo $icon | /usr/bin/sed 's/\//:/g' )
iconposix="$bootvolname$iconposix"

# Prepare list of apps to install in readable format
# Remove trailing blank lines to avoid parsing issues
while read line || [ -n "$line" ];
do
	applist+=$( echo $line | cut -f2 -d$'\t' )"\\n"
done < "$jsspkginfo"

applist=$( echo $applist | awk /./ )

# Check deferral count. Prompt user if under, otherwise force the issue.
# If silent mode then skip all this and just do it
if [[ "$silent" == "0" ]];
then
	if [ "$deferred" -lt "$alloweddeferral" ];
	then
		# Prompt user that updates are ready. Allow deferral.
		test=$( /bin/launchctl asuser "$curuserid" "$osa" -e 'display dialog "'"$msgnewsoftware"'\n\n'"$applist"'\n\nAuto deferral in 60 seconds." giving up after 60 with icon file "'"$iconposix"'" with title "'"$msgtitlenewsoft"'" buttons {"Install", "Defer"} default button 2' )

		# Did we defer?
		if [ $( echo $test | /usr/bin/grep -c -e "Defer" -e "gave up:true" ) = "1" ];
		then
			# Increment counter and store.
			deferred=$(( deferred + 1 ))
			/usr/bin/defaults write "$updatefile" deferral -int "$deferred"

			# Notify user how many deferrals are left and exit.
			/bin/launchctl asuser "$curuserid" "$osa" -e 'display dialog "You have used '"$deferred"' of '"$alloweddeferral"' allowed upgrade deferrals." giving up after 60 with icon file "'"$iconposix"'" with title "'"$msgtitlenewsoft"'" buttons {"Ok"} default button 1'
			exit 0
		fi
	else
		# Prompt user that updates are happening right now.
		forced="1"
		/bin/launchctl asuser "$curuserid" "$osa" -e 'display dialog "'"$msgnewsoftforced"'\n\n'"$applist"'\n\nThe upgrade will start in 60 seconds." giving up after 60 with icon file "'"$iconposix"'" with title "'"$msgtitlenewsoft"'" buttons {"Install"} default button 1'
	fi
fi

# Store deferrals used, time of last update and then reset the deferral count
/usr/bin/defaults write "$updatefile" lastdeferral -int $( /usr/bin/defaults read "$updatefile" deferral )
/usr/bin/defaults write "$updatefile" lastupdate -date "$( /bin/date "+%Y-%m-%d %H:%M:%S" )"
/usr/bin/defaults write "$updatefile" deferral -int 0

###################################
#
# Check to see if we're on AC power
#
###################################

if [[ "$silent" == "0" ]];
then
	# Check if device is on battery or ac power
	# Valid reports are `Battery Power` or `AC Power`
	pwrAdapter=$( /usr/bin/pmset -g ps | /usr/bin/grep "Now drawing" | /usr/bin/cut -d "'" -f2 )

	# Warn the user if not on AC power
	count=1
	while [[ "$count" -le "3" ]];
	do
		[[ "$pwrAdapter" = "AC Power" ]] && break
		count=$(( count + 1 ))
		/bin/launchctl asuser "$curuserid" "$osa" -e 'display dialog "'"$msgpowerwarning"'" giving up after 60 with icon file "'"$iconposix"'" with title "'"$msgtitlenewsoft"'" buttons {"Proceed"} default button 1'
		pwrAdapter=$( /usr/bin/pmset -g ps | /usr/bin/grep "Now drawing" | /usr/bin/cut -d "'" -f2 )
	done

################################
#
# Close all running applications
#
################################

	# Find all applications with osascript and process them into an array.
	# Big thanks to William 'talkingmoose' Smith for this way of parsing lsappinfo
	runningapps=($( /usr/bin/lsappinfo list | /usr/bin/grep -B 4 Foreground | /usr/bin/awk -F '\\) "|" ASN' 'NF > 1 { print $2 }' ))

	# Process the new array of apps and gently kill them off one by one.
	# Obviously we don't want to kill a few apps we don't routinely update.
	for app ($runningapps)
	do
		[[ "$app" =~ (Finder|Progress|Google Chrome|Safari|Self Service|Terminal|Adobe*) ]] && continue
		/usr/bin/killall "$app"
	done
fi

######################################
#
# Start installing from the build list
#
######################################

# Store total number of applications to install
# Displayed to user later during progress bar
appcounter=0
totalappnumber=${#cachedpkg[@]}

# Invoke our progress bar application.
# Set initial message and then run the app as a background app.
cat <<EOF > "$pbjson"
{
    "percentage": -1,
    "title": "$msgprogresstitle",
    "message": "Preparing to upgrade ...",
    "icon": "$updateicon"
}
EOF

[[ "$silent" == "0" ]] && $pb $pbjson $canceljson &

# Read the tsv line by line and install
while read line
do
	# Increment the app counter
	appcounter=$(( appcounter + 1 ))

	# Batch process the line we just read out into its component parts
	pkgname=$( echo "$line" | cut -f2 )
	displayname=$( echo "$line" | cut -f3 )
	fullpath=$( echo "$line" | cut -f4 )
	reboot=$( echo "$line" | cut -f5 )
	feu=$( echo "$line" | cut -f6 )
	fut=$( echo "$line" | cut -f7 )
	osinstall=$( echo "$line" | cut -f8 )

	# Does this or any other installer require a restart.
	# Mark it so with an empty file.
	[[ "$reboot" == "1" ]] && touch /private/tmp/.apppatchreboot

	# Have the Jamf FEU/FUT options been set for this package
	[[ "$feu" == "1" ]] && installoption="$installoption -feu"
	[[ "$fut" == "1" ]] && installoption="$installoption -fut"

	# Is this an OS install. Break out of the loop. Handle this separately.
	[[ "$osinstall" == "1" ]] && continue

	# Perform the installation as a background task with the correct options
	# Output progress to a text file. We'll use that next.
	$jb install $installoption -package $pkgname -path $fullpath -target / -showProgress > "$installoutput" &

	while :;
	do
		# Wait three seconds for Progress to update, then work out current percentage.
		# We make sure the percentage never hits 100 or the progress bar will stop.
		sleep 1

		# Did someone try to hit the cancel button? Kill the generated file and restart the progress bar.
		# They had a chance to defer earlier.
		if [ "$forced" = "0" ];
		then
			if [ -f "$canceljson" ];
			then
				/bin/rm "$canceljson"
				/usr/bin/killall Progress 2>/dev/null
				/bin/rm /private/tmp/.apppatchreboot
				break
			fi
		else
			[ -f "$canceljson" ] && { /bin/rm "$canceljson"; killall Progress; $pb $pbjson $canceljson &; }
		fi

		percent=$( /bin/cat "$installoutput" | /usr/bin/grep "installer:%" | /usr/bin/cut -d"%" -f2 | /usr/bin/awk '{ print int($1) }' | /usr/bin/tail -n1 )
		[ "$percent" -eq 100 ] && percent="99"

		# Correct the file that Progress is using to display the bar.
cat <<EOF > "$pbjson"
{
	"percentage": $percent,
	"title": "Installing $displayname",
	"message": "Install $percent% completed - (Updating $appcounter of $totalappnumber)",
	"icon": "$updateicon"
}
EOF

		# Check to see if we've had a finished install. Break out the loop if so.
		complete=$( /bin/cat "$installoutput" | /usr/bin/grep -c -E "Successfully installed|failed" )
		[ "$complete" = "1" ] && { /bin/rm -f "$installoutput"; break; }
	done

	# Clean up of variables before next loop or end of loop
	unset priority pkgname displayname fullpath reboot feu fut

done < "$jsspkginfo"

# Finally end the progress bar
if [[ "$osinstall" == "0" ]];
then
cat <<EOF > "$pbjson"
{
	"percentage": 99,
	"title": "$msgprogresstitle",
	"message": "Application Updates Completed",
	"icon": "$updateicon"
}
EOF
fi

# Kill Progress and warn the user if any impending reboots, if not in silent mode
sleep 3
if [[ "$silent" == "0" ]];
then
	[[ -f /private/tmp/.apppatchreboot ]] && "$osa" -e 'display dialog "'"$msgrebootwarning"'" giving up after 15 with icon file "'"$iconposix"'" with title "'"$msgtitlenewsoft"'" buttons {"Ok"} default button 1'
fi

############################
#
# OS Upgrade code goes here
#
############################

if [[ "$osinstall" == "1" ]];
then
	# Work out where startosinstaller binary is located
	# Most of this work should be done already from the cached file info.
	startos=$( /usr/bin/find "$fullpath/$pkgname" -iname "startosinstall" -type f )

	# Set up a future interminate progress bar here. We'll invoke this after.
cat <<EOF > "$pbjson"
{
    "percentage": -1,
    "title": "$msgosupgtitle",
    "message": "Preparing to upgrade ..",
    "icon": "$updateicon"
}
EOF

	# Attempt to suppress certain update dialogs
	/usr/bin/touch "$homefolder"/.skipbuddy

	# Create a post install script and launchd for use after the OS upgrade.
	# This is why we don't need to run a recon immediately after the script runs. We do it later.

cat << "EOF" > /usr/local/corp/finishOSInstall.sh
#!/bin/zsh

# First Run Script after an OS upgrade.

# Wait until /var/db/.AppleUpgrade disappears
while [ -e /var/db/.AppleUpgrade ]; do sleep 5; done

# Wait until the upgrade process completes
INSTALLER_PROGRESS_PROCESS=$( /usr/bin/pgrep -l "Installer Progress" )
until [ "$INSTALLER_PROGRESS_PROCESS" = "" ];
do
    sleep 15
    INSTALLER_PROGRESS_PROCESS=$( /usr/bin/pgrep -l "Installer Progress" )
done

# Update Device Information
/usr/local/bin/jamf manage
/usr/local/bin/jamf recon
/usr/local/bin/jamf policy

# Remove LaunchDaemon
/bin/rm -f /Library/LaunchDaemons/com.corp.cleanupOSInstall.plist

# Remove Script
/bin/rm -f /usr/local/corp/finishOSInstall.sh

exit 0
EOF

	/usr/sbin/chown root:admin /usr/local/corp/finishOSInstall.sh
	/bin/chmod 755 /usr/local/corp/finishOSInstall.sh

	# Create a LaunchDaemon to run the above script
cat << "EOF" > /Library/LaunchDaemons/com.corp.cleanupOSInstall.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.corp.cleanupOSInstall</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>-c</string>
        <string>/usr/local/corp/finishOSInstall.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

	/usr/sbin/chown root:wheel /Library/LaunchDaemons/com.corp.cleanupOSInstall.plist
	/bin/chmod 644 /Library/LaunchDaemons/com.corp.cleanupOSInstall.plist

	# Are we running on Intel or Arm based macs? Apple Silicon macs require user credentials.
	if [[ $( /usr/bin/arch ) == "arm64" ]];
	then
		# Apple Silicon macs. We need to prompt for the users credentials or this won't work. Skip this totally if in silent mode.
		if [[ "$silent" == "0" ]];
		then

			# Work out appropriate icon for use
			icon="/System/Applications/Utilities/Keychain Access.app/Contents/Resources/AppIcon.icns"
			iconposix=$( echo $icon | /usr/bin/sed 's/\//:/g' )
			iconposix="$bootvolname$iconposix"

			# Warn user of what's about to happen
			/bin/launchctl asuser "$curuserid" "$osa" -e 'display dialog "We about to upgrade your macOS and need you to authenticate to continue.\n\nPlease enter your password on the next screen.\n\nPlease contact IT Helpdesk with any issues." giving up after 60 with icon file "'"$iconposix"'" with title "macOS Upgrade" buttons {"OK"} default button 1'

			# Loop three times for password validation
			count=1
			while [[ "$count" -le 3 ]];
			do

				# Prompt for a password. Verify it works a maximum of three times before quitting out.
				# Also have timeout on the prompt so it doesn't just sit there.
				password=$( /bin/launchctl asuser "$curuserid" "$osa" -e 'display dialog "Please enter your macOS login password:" default answer "" with title "macOS Update - Authentication Required" giving up after 300 with text buttons {"OK"} default button 1 with hidden answer with icon file "'"$iconposix"'" ' -e 'return text returned of result' '' )

				# Escape any spaces in the password
				escapepassword=$( echo ${password} | /usr/bin/sed 's/ /\\\ /g' )

				# Ok verify the input we got is correct
				validpassword=$( /usr/bin/expect <<EOF
spawn /usr/bin/dscl /Local/Default -authonly ${currentuser}
expect {
	"Password:" {
		send "${escapepassword}\r"
		exp_continue
	}
}
EOF
)

				if [[ "${validpassword}" == *"eDSAuthFailed"* ]];
				then
					# Warn of incorrect password if counter is not set to three.
					echo "Incorrect password. Counter: $count"
					[[ "$count" -le 2 ]] && /bin/launchctl asuser "$curuserid" "$osa" -e 'display dialog "Your entered password was incorrect.\n\nPlease try again." giving up after 60 with icon file "'"$iconposix"'" with title "Incorrect Password" buttons {"OK"} default button 1'
				else
					# Set flag for securetoken user
					echo "Correct password. Proceeding."
					break
				fi

				# Increment counter before looping
				count=$(( count + 1 ))
			done

			# Final check of output. Quit here if we don't have a valid password after three attempts
			if [[ "${validpassword}" == *"eDSAuthFailed"* ]];
			then
				echo "Invalid password entered three times. Exiting."
				/bin/launchctl asuser "$curuserid" "$osa" -e 'display dialog "We could not validate your password.\n\nPlease try again later." giving up after 60 with icon file "'"$iconposix"'" with title "Incorrect Password" buttons {"OK"} default button 1'

				# Quit the screenlock, caffeinate and clean up.
				/usr/bin/killall Dock 2>/dev/null
				/usr/bin/killall caffeinate 2>/dev/null
				/bin/rm -R "$fullpath/$pkgfilename"
				/bin/rm -f /Library/LaunchDaemons/com.corp.cleanupOSInstall.plist
				/bin/rm -f "$workfolder"/finishOSInstall.sh
				/usr/bin/find "$infofolder" -type f \( -iname "*.plist" ! -iname "$updatefilename" \) -exec rm {} \;
				/usr/bin/find "$waitroom" \( -iname \*.pkg -o -iname \*.cache.xml \) -exec rm {} \;
				exit 1
			fi

			# Invoke startosinstall to perform the OS upgrade with the accepted credential. Run that in background.
			# Then start up the progress bar app.
			"$startos" --agreetolicense --forcequitapps --user "$currentuser" --stdinpass <<< "$password" &> "$stosout" &
		fi
	else
		# Intel macs. We can just go for it.

		# Invoke startosinstall to perform the OS upgrade. Run that in background.
		# Then start up the progress bar app.
		"$startos" --agreetolicense --forcequitapps &> "$stosout" &
	fi

	# Code to allow people to cancel the update window. Also will not proceed until startosinstall is complete.
	while :;
	do
		sleep 1

		# Stops the user cancelling the progress bar by force reloading it if we're not forcing things.
		if [ "$forced" = "0" ];
		then
			if [ -f "$canceljson" ];
			then
				/bin/rm "$canceljson"
				/usr/bin/killall startosinstall 2>/dev/null
				break 3
			fi
		else
			[ -f "$canceljson" ] && { /bin/rm "$canceljson"; killall Progress; $pb $pbjson $canceljson &; }
		fi

		# This was such a pain to work out. We have to cat the entire file out,
		# then use grep to find the particular line we want but this is also a trap.
		# Apple's startosinstall is using ^M characters to backspace and overwrite the percentage line in Terminal.
		# Unfortunately nohup is capturing all those characters and not doing that. We must then clean up.
		# So change all those to unix linefeeds with tr, grab the latest (last) line and ...
		# finally awk to convert to a suitable integer for use with Progress.
		percent=$( /bin/cat "$stosout" | /usr/bin/grep "Preparing: " | /usr/bin/tr '\r' '\n' | /usr/bin/tail -n1 | /usr/bin/awk '{ print int($2) }' )
		waittest=$( /bin/cat "$stosout" | /usr/bin/grep -c "Waiting to restart" | /usr/bin/tr '\r' '\n' )

		# Trap edge cases of numbers being 0, which won't display or 100 which stops the progress bar.
		[ "$percent" -eq 0 ] && percent="1"
		[ "$percent" -ge 99 ] && percent="99"

cat <<EOF > "$pbjson"
{
	"percentage": $percent,
	"title": "$msgosupgtitle",
	"message": "macOS upgrade $percent% completed. Please wait.",
	"icon": "$updateicon"
}
EOF
		# If we detected the restart message, break out the loop here.
		[ "$waittest" = "1" ] && break

		# If startosinstall quit suddenly, break here too
		[ -z $( /usr/bin/pgrep startosinstall ) ] && { error=1; break; }
	done
fi

# Did startosinstall quit part way? Warn user.
if [ "$error" = "1" ];
then
	/bin/launchctl asuser "$curuserid" "$osa" -e 'display dialog "The upgrade encountered an unexpected error.\n\nPlease try again later." giving up after 60 with icon file "'"$iconposix"'" with title "Error" buttons {"OK"} default button 1'
fi

# Run a jamf recon here so we don't overdo it by having it run every policy, only on success.
# Unless we're doing an OS install, we have other ways for that above.
# Was a reboot requested? We should oblige IF we're not doing an OS upgrade
# Give it a 1 minute delay to allow for policy reporting to finish
if [[ "$osinstall" == "0" ]];
then
    $jb recon
	if [ -f "/private/tmp/.apppatchreboot" ];
	then
		/bin/rm /private/tmp/.apppatchreboot
		/sbin/shutdown -r +0.1 &
	fi
fi

# Stop caffeinate so we can sleep again, then clean up files
/usr/bin/killall Progress 2>/dev/null
/usr/bin/killall caffeinate 2>/dev/null
/bin/rm -f "$jsspkginfo"

# Clean these ONLY if we didn't cancel out
if [ ! -f "$canceljson" ];
then
	/usr/bin/find "$infofolder" -type f \( -iname "*.plist" ! -iname "$updatefilename" \) -exec rm {} \;
	/usr/bin/find "$waitroom" \( -iname \*.pkg -o -iname \*.cache.xml \) -exec rm {} \;
fi

# Reset IFS
IFS=$OIFS

# All done
exit 0

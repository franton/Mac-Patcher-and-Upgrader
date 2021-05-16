#!/bin/zsh

# Main patching and installer script
# Meant to be run periodically from launchd on macOS endpoint
# richard@richard-purves.com - 05-14-2021 - v1.0

# Logging output to a file for testing
#time=$( date "+%d%m%y-%H%M" )
#set -x
#logfile=/Users/Shared/cachedappinstaller-"$time".log
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
msgrebootwarning="Your computer will need to reboot at the completion of the upgrades."
msgpowerwarning="Your computer is about to upgrade installed software.

Please ensure you are connected to AC Power.

Once you are plugged in, please click the Proceed button."
msgosupgradewarning="Your computer will perform a major macOS upgrade.

Please ensure you are connected to AC Power.

Your computer will restart and the OS upgrade process will continue. It will take up to 90 minutes to complete.

IT IS VERY IMPORTANT YOU DO NOT INTERRUPT THIS PROCESS."

# Script variables here
alloweddeferral="5"
blockingapps=( "Microsoft PowerPoint" "Keynote" "zoom.us" )

waitroom="/Library/Application Support/JAMF/Waiting Room"
workfolder="/usr/local/corp"
infofolder="$workfolder/cachedapps"
jsspkginfo="/private/tmp/jsspkginfo.tsv"
updatefilename="appupdates.plist"
updatefile="$infofolder/$updatefilename"
pbjson="/private/tmp/progressbar.json"
canceljson="/private/tmp/progresscancel.json"

jssurl=$( /usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url )
jb=$( which jamf )
os=$( /usr/bin/which osascript )
pbapp="/Applications/Utilities/Progress.app"
pb="$pbapp/Contents/MacOS/Progress"

installiconpath="/System/Library/CoreServices/Installer.app/Contents/Resources"
updateicon="/System/Library/PreferencePanes/SoftwareUpdate.prefPane/Contents/Resources/SoftwareUpdate.icns"

currentuser=$( /usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk -F': ' '/[[:space:]]+Name[[:space:]]:/ { if ( $2 != "loginwindow" ) { print $2 }}' )
homefolder=$( dscl . -read /Users/$currentuser NFSHomeDirectory | awk '{ print $2 }' )

# Check that the info folder exists, create if missing and set appropriate permissions
/bin/mkdir -p "$infofolder"
/bin/chmod 755 "$infofolder"
/usr/sbin/chown root:wheel "$infofolder"

####################
#                  #
# Let's get to it! #
#                  #
####################

# Stop IFS splitting on spaces
OIFS=$IFS
IFS=$'\n'

# Is anyone logged in? Quit silently if not.
if [[ "$currentuser" = "loginwindow" ]] || [[ -z "$currentuser" ]];
then
	echo "No user present. Exiting."
	exit 0
fi

# Blocking application check here
foregroundapp=($( /usr/bin/sudo -u "$currentuser" "$os" -e "tell application \"System Events\"" -e "return name of first application process whose frontmost is true" -e "end tell" 2> /dev/null))

# check for blocking apps
for app ($blockingapps)
do
	if [[ "$app" == "$foregroundapp" ]];
	then
		echo "Blocking app: $app"
		exit 0
	fi
done

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

	# Store everything into a tsv temporary file
	echo -e "${priority}\t${pkgname}\t${displayname}\t${fullpath}\t${reboot}\t${feu}\t${fut}\t${osinstall}" >> "$jsspkginfo"

	# Clean up of variables before next loop or end of loop
	unset priority pkgname displayname fullpath reboot feu fut osinstall
done

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
iconposix=$( "$os" -e 'tell application "System Events" to return POSIX file "'"$icon"'" as text' )

# Prepare list of apps to install in readable format
# Remove trailing blank lines to avoid parsing issues
while read line || [ -n "$line" ];
do
	applist+=$( echo $line | cut -f2 -d$'\t' )"\\n"
done < "$jsspkginfo"

applist=$( echo $applist | awk /./ )

# Check deferral count. Prompt user if under, otherwise force the issue.
if [ "$deferred" -lt "$alloweddeferral" ];
then
	# Prompt user that updates are ready. Allow deferral.
	test=$( "$os" -e 'display dialog "'"$msgnewsoftware"'\n\n'"$applist"'\n\nAuto deferral in 30 seconds." giving up after 30 with icon file "'"$iconposix"'" with title "'"$msgtitlenewsoft"'" buttons {"Install", "Defer"} default button 2' )

	# Did we defer?
	if [ $( echo $test | /usr/bin/grep -c -e "Defer" -e "gave up:true" ) = "1" ];
	then
		# Increment counter and store.
		deferred=$(( deferred + 1 ))
		/usr/bin/defaults write "$updatefile" deferral -int "$deferred"
		
		# Notify user how many deferrals are left and exit.
		"$os" -e 'display dialog "You have used '"$deferred"' of '"$alloweddeferral"' allowed upgrade deferrals." giving up after 30 with icon file "'"$iconposix"'" with title "'"$msgtitlenewsoft"'" buttons {"Ok"} default button 1'
		exit 0
	fi
else
	# Prompt user that updates are happening right now.
	"$os" -e 'display dialog "'"$msgnewsoftforced"'\n\n'"$applist"'\n\nThe upgrade will start in 30 seconds." giving up after 30 with icon file "'"$iconposix"'" with title "'"$msgtitlenewsoft"'" buttons {"Install"} default button 1'
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

# Check if device is on battery or ac power
# Valid reports are `Battery Power` or `AC Power`
pwrAdapter=$( /usr/bin/pmset -g ps | /usr/bin/grep "Now drawing" | /usr/bin/cut -d "'" -f2 )

# Warn the user if not on AC power
count=1
while [[ "$count" -le "3" ]];
do
	[[ "$pwrAdapter" = "AC Power" ]] && break
	count=$(( count + 1 ))
	"$os" -e 'display dialog "'"$msgpowerwarning"'" giving up after 30 with icon file "'"$iconposix"'" with title "'"$msgtitlenewsoft"'" buttons {"Proceed"} default button 1'
	pwrAdapter=$( /usr/bin/pmset -g ps | /usr/bin/grep "Now drawing" | /usr/bin/cut -d "'" -f2 )
done

#############################################
#
# Prepare and lockout the screen for installs
#
#############################################

# Copy lockscreen to location where we can modify it. SIP prevents us doing necessary changes.
/usr/bin/rsync -avrz /System/Library/CoreServices/RemoteManagement/AppleVNCServer.bundle/Contents/Support/LockScreen.app /private/tmp

# Set the Info.plist to ensure we take over the entire display. Correct any permissions changes afterwards.
/usr/bin/defaults write /private/tmp/LockScreen.app/Contents/Info.plist LSUIElement -int 0
/usr/bin/defaults write /private/tmp/LockScreen.app/Contents/Info.plist LSUIPresentationMode -int 3
/bin/chmod 644 /private/tmp/LockScreen.app/Contents/Info.plist

# lock screen icon stuff here
/bin/rm /private/tmp/LockScreen.app/Contents/Resources/Lock.jpg
/bin/cp /usr/local/trr/imgs/trr-login-logo.png /private/tmp/LockScreen.app/Contents/Resources/Lock.jpg

# Progress.app seems to only like running with current user as owner.
# We must "fix" every time we run.
/usr/sbin/chown -R "$currentuser":staff "$pbapp"

# Activate the LockScreen and background so we don't get stuck
/private/tmp/LockScreen.app/Contents/MacOS/LockScreen &

################################
#
# Close all running applications
#
################################

# Find all applications with osascript and process them into an array.
runningapps=($( /usr/bin/sudo -u "$currentuser" "$os" -e "tell application \"System Events\" to return displayed name of every application process whose (background only is false and displayed name is not \"Finder\")" | /usr/bin/sed 's/, /\n/g' ))

# Process the new array of apps and gently kill them off one by one.
# We'll use Lachlan (loceee) Stewart's technique of applescript run as the current user.
# Obviously we don't want to kill off either LockScreen or jamfHelper!
for app ($runningapps)
do
	[[ "$app" =~ ^(LockScreen|Progress|Terminal)$ ]] && continue
	/usr/bin/sudo -u "$currentuser" "$os" -e "ignoring application responses" -e "tell application \"$app\" to quit" -e "end ignoring"
done

######################################
#
# Start installing from the build list
#
######################################

# Store total number of applications to install
# Displayed to user later during progress bar
appcounter=0
percent=1
totalappnumber=${#cachedpkg[@]}
percentapps=$(( 100 / $totalappnumber ))

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

$pb $pbjson $canceljson &
sleep 1

# Read the tsv line by line and install
while read line
do
	# Batch process the line we just read out into its component parts
	pkgname=$( echo "$line" | cut -f2 )
	displayname=$( echo "$line" | cut -f3 )
	fullpath=$( echo "$line" | cut -f4 )
	reboot=$( echo "$line" | cut -f5 )
	feu=$( echo "$line" | cut -f6 )
	fut=$( echo "$line" | cut -f7 )
	osinstall=$( echo "$line" | cut -f8 )

	# Does this or any other installer require a restart.
	# Mark it so with an empty file. Warn the user.
	if [ "$reboot" = "1" ];
	then
		touch /private/tmp/.apppatchreboot
		"$os" -e 'display dialog "'"$msgrebootwarning"'" giving up after 15 with icon file "'"$iconposix"'" with title "'"$msgtitlenewsoft"'" buttons {"Ok"} default button 1'
	fi

	# Have the Jamf FEU/FUT options been set for this package
	[ "$feu" = "1" ] && installoption="$installoption -feu"
	[ "$fut" = "1" ] && installoption="$installoption -fut"

	# Is this an OS install. Break out of the loop. Handle this separately.
	[ "$osinstall" = "1" ] && continue

	# Did someone try to hit the cancel button? Kill the generated file and restart the progress bar.
	# They had a chance to defer earlier.
	[ -f "$canceljson" ] && { /bin/rm "$canceljson"; killall Progress; $pb $pbjson $canceljson &; }

	# Work out total percent done, bit of a fudge for when we get close to 100% done
	# Increment app counter. Means first display goes 0 to 1 which is good.
	percent=$(( percent + percentapps ))
	[ "$percent" -ge 90 ] && percent="99"
	appcounter=$(( appcounter + 1 ))

	# Update progress bar we started earlier and wait 3 seconds
	# Only thing we have to do is rewrite the .json file it's looking at.
	# And wait three seconds.
	/bin/cat <<EOF > $pbjson
{
    "percentage": $percent,
    "title": "Installing $displayname",
    "message": "Installing application $appcounter of $totalappnumber",
    "icon": "$updateicon"
}
EOF

	sleep 1

	# Perform the installation with the correct options
	$jb install $installoption -package $pkgname -path $fullpath -target /

	# Clean up of variables before next loop or end of loop
	unset priority pkgname displayname fullpath reboot feu fut osinstall

done < "$jsspkginfo"

# Finally end the progress bar
if [ "$osinstall" = "0" ];
then
cat <<EOF > $pbjson
{
    "percentage": 100,
    "title": "$msgprogresstitle",
    "message": "Application Updates Completed",
    "icon": "$updateicon"
}
EOF
fi

# Remove the progress bar. LockScreen if arm64. Intel is ok.
/usr/bin/killall Progress 2>/dev/null
[ $( /usr/bin/arch ) = "arm64" ] && /usr/bin/killall LockScreen 2>/dev/null

############################
#
# OS Upgrade code goes here
#
############################

if [ "$osinstall" = "1" ];
then
	# Work out where startosinstaller binary is located
	# Most of this work should be done already from the cached file info.
	startos=$( /usr/bin/find "$fullpath" -iname "startosinstall" -type f )

	# Set up a future interminate progress bar here. We'll invoke this later.
cat <<EOF > $pbjson
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

cat << "EOF" > "$workfolder"/finishOSInstall.sh
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

	/usr/sbin/chown root:admin "$workfolder"/finishOSInstall.sh
	/bin/chmod 755 "$workfolder"/finishOSInstall.sh

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
	if [[ $( /usr/bin/arch ) = "arm64" ]];
	then
		# Apple Silicon macs. We need to prompt for the users credentials or this won't work.

		# Work out appropriate icon for use
		icon="/System/Applications/Utilities/Keychain Access.app/Contents/Resources/AppIcon.icns"
		iconposix=$( "$os" -e 'tell application "System Events" to return POSIX file "'"$icon"'" as text' )

		# Warn user of what's about to happen
		"$os" -e 'display dialog "We about to upgrade your macOS and need you to authenticate to continue.\n\nPlease enter your password on the next screen.\n\nPlease contact IT Helpdesk with any issues." giving up after 30 with icon file "'"$iconposix"'" with title "macOS Upgrade" buttons {"OK"} default button 1'

		# Loop three times for password validation
		count=1
		while [[ "$count" -le 3 ]];
		do

			# Prompt for a password. Verify it works a maximum of three times before quitting out.
			# Also have timeout on the prompt so it doesn't just sit there.
			password=$( "$os" -e 'display dialog "Please enter your macOS login password:" default answer "" with title "macOS Update - Authentication Required" giving up after 300 with text buttons {"OK"} default button 1 with hidden answer with icon file "'"$iconposix"'" ' -e 'return text returned of result' '' )
	
			# Escape any spaces in the password
			escapepassword=$( echo ${password} | /usr/bin/python -c "import re, sys; print(re.escape(sys.stdin.read().strip()))" )

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
				[[ "$count" -le 2 ]] && "$os" -e 'display dialog "Your entered password was incorrect.\n\nPlease try again." giving up after 30 with icon file "'"$iconposix"'" with title "Incorrect Password" buttons {"OK"} default button 1'
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
			"$os" -e 'display dialog "We could not validate your password.\n\nPlease try again later." giving up after 30 with icon file "'"$iconposix"'" with title "Incorrect Password" buttons {"OK"} default button 1'

			# Quit the screenlock, caffeinate and clean up.
			/usr/bin/killall caffeinate 2>/dev/null
			/bin/rm -R "$fullpath/$pkgfilename"
			/bin/rm -rf /private/tmp/LockScreen.app
			/bin/rm -f /Library/LaunchDaemons/com.corp.cleanupOSInstall.plist
			/bin/rm -f "$workfolder"/finishOSInstall.sh
			/usr/bin/find "$infofolder" -type f \( -iname "*.plist" ! -iname "$updatefilename" \) -exec rm {} \;
			/usr/bin/find "$waitroom" \( -iname \*.pkg -o -iname \*.cache.xml \) -exec rm {} \;
			exit 1
		fi

		# Invoke startosinstall to perform the OS upgrade with the accepted credential. Run that in background.
		# Then start up the progress bar app.
		/private/tmp/LockScreen.app/Contents/MacOS/LockScreen &
		/usr/bin/nohup $startos --agreetolicense --rebootdelay 120 --forcequitapps --user "$currentuser" --stdinpass <<< "$password" > /private/tmp/nohup.log &
		$pb $pbjson $canceljson &

	else
		# Intel macs. We can just go for it.

		# Invoke startosinstall to perform the OS upgrade. Run that in background.
		# Then start up the progress bar app.
		/usr/bin/nohup $startos --agreetolicense --rebootdelay 120 --forcequitapps > /private/tmp/nohup.log &
		$pb $pbjson $canceljson &
	fi

	# Code to stop people cancelling the update window. Also will not proceed until startosinstall is complete.
	sleep 2
	while :;
	do
		# Stops the user cancelling the progress bar by force reloading it.
		[ -f "$canceljson" ] && { /bin/rm "$canceljson"; killall Progress; $pb $pbjson $canceljson &; }
		
		# This was such a pain to work out. We have to cat the entire file out,
		# then use grep to find the particular line we want but this is also a trap.
		# Apple's startosinstall is using ^M characters to backspace and overwrite the percentage line in Terminal.
		# Unfortunately nohup is capturing all those characters and not doing that. We must then clean up.
		# So change all those to unix linefeeds with tr, grab the latest (last) line and ...
		# finally awk to convert to a suitable integer for use with Progress.
		percent=$( /bin/cat /private/tmp/nohup.log | /usr/bin/grep "Preparing: " | /usr/bin/tr '\r' '\n' | /usr/bin/tail -n1 | /usr/bin/awk '{ print int($2) }' )
		
		# Trap edge cases of numbers being 0, which won't display or 100 which stops the progress bar.
		[ "$percent" -eq 0 ] && percent="1"
		[ "$percent" -ge 99 ] && percent="99"
		
		# Unless we get the restart message, then we should cancel the bar by setting it to 100 then breaking out of the loop.
		test=$( /bin/cat /private/tmp/nohup.log | /usr/bin/tr '\r' '\n' | /usr/bin/grep -c "Waiting to restart" )
		[ "$test" = "1" ] && percent="100"
cat <<EOF > $pbjson
{
    "percentage": $percent,
    "title": "$msgosupgtitle",
    "message": "macOS upgrade $percent% completed. Please wait.",
    "icon": "$updateicon"
}
EOF
		[ "$test" = "1" ] && { sleep 3; break; }
	done
fi

# Run a jamf recon here so we don't overdo it by having it run every policy, only on success.
# Unless we're doing an OS install, we have other ways for that above.
[ "$osinstall" = "0" ] && $jb recon

# Was a reboot requested? We should oblige IF we're not doing an OS upgrade
# Give it a 1 minute delay to allow for policy reporting to finish
if [ "$osinstall" = "0" ];
then
	[ -f "/private/tmp/.apppatchreboot" ] && { /bin/rm /private/tmp/.apppatchreboot; /sbin/shutdown -r +1; }
fi

# Kill the lockscreen and clean up files
/usr/bin/killall LockScreen 2>/dev/null
/usr/bin/killall Progress 2>/dev/null
/usr/bin/killall caffeinate 2>/dev/null
/bin/rm -rf /private/tmp/LockScreen.app
/bin/rm -f "$jsspkginfo"
/usr/bin/find "$infofolder" -type f \( -iname "*.plist" ! -iname "$updatefilename" \) -exec rm {} \;
/usr/bin/find "$waitroom" \( -iname \*.pkg -o -iname \*.cache.xml \) -exec rm {} \;

# Reset IFS
IFS=$OIFS

# All done.
exit 0
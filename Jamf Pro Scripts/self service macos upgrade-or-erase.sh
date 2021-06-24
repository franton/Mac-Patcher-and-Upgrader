#!/bin/zsh

# Script to either upgrade or erase and reinstall macOS on a target device
# richard@richard-purves.com - 09-16-2021

# Relies on https://github.com/adriannier/swift-progress to provide an accurate progress bar.

# Choices are "upgrade" or "erase". Users will never see "erase", that one is locked to IT only.
mode="$4"
[ -z "$4" ] && { /bin/echo "ERROR - No operating mode specified"; exit 1; }
mode=$( echo $mode | tr '[:upper:]' '[:lower:]' )

# Which OS do we want to keep
osexclude="$5"
[ -z "$5" ] && { /bin/echo "ERROR - No OS name specified"; exit 1; }

# Any OS specified?
downloados="$6"
[ -z "$6" ] && { /bin/echo "No OS version specified. Defaulting to 11.4"; downloados="11.4"; }

#
# Set up the variables here
#

# Work out machine type
[[ $( /usr/bin/arch ) = "arm64" ]] && asmac=true || asmac=false

# Work out where helper apps exist
jb=$( which jamf )
os=$( /usr/bin/which osascript )
pbapp="/Applications/Utilities/Progress.app"
pb="$pbapp/Contents/MacOS/Progress"

# Work out current user
currentuser=$( /usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk -F': ' '/[[:space:]]+Name[[:space:]]:/ { if ( $2 != "loginwindow" ) { print $2 }}' )

# Now what is the boot volume called, just in case someone renamed it
bootvolname=$( /usr/sbin/diskutil info / | /usr/bin/awk '/Volume Name:/ { print substr($0, index($0,$3)) ; }' )

# Work out update icon location
updateicon="/System/Library/PreferencePanes/SoftwareUpdate.prefPane/Contents/Resources/SoftwareUpdate.icns"
iconposix=$( echo $updateicon | /usr/bin/sed 's/\//:/g' )
iconposix="$bootvolname$iconposix"

# File locations
workfolder="/private/tmp"
pbjson="$workfolder/progressbar.json"
canceljson="$workfolder/cancelfile.json"

# Display messages are set here
[[ "$mode" = "upgrade" ]] && msgosupgtitle="Upgrading macOS" || msgosupgtitle="Erasing macOS"
msgpowerwarning="Your computer is about to upgrade installed software.

Please ensure you are connected to AC Power.

Once you are plugged in, please click the Proceed button."
msgdltitle="Downloading macOS"
msgdlfailed="The macOS download failed.

Please check your network connection and try again later."

# Keep the mac awake while this runs.
/usr/bin/caffeinate -dis &

# Check for Progress.app and install if not
[ ! -d "/Applications/Utilities/Progress.app" ] && $jb policy -event patchinstall

#
# Check to see if we're on AC power
#

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

#
# Clear any existing installers and download the specified one
#

# Find all macOS installers and clear them out
/usr/bin/find /Applications -iname "Install macOS*" -type d -maxdepth 1 -exec rm -rf {} \;

#
# Download the latest approved macOS
#

# Reset the softwareupdate daemon
/usr/bin/defaults delete /Library/Preferences/com.apple.SoftwareUpdate.plist
rm /Library/Preferences/com.apple.SoftwareUpdate.plist
/bin/launchctl kickstart -k system/com.apple.softwareupdated

# Prep the progress bar info
cat <<EOF > "$pbjson"
{
    "percentage": -1,
    "title": "$msgdltitle $osexclude $downloados",
    "message": "Preparing to download ...",
    "icon": "$updateicon"
}
EOF

# Now use softwareupdate to cache the latest app bundle
( cd /Applications ; /usr/sbin/softwareupdate --fetch-full-installer --full-installer-version "$downloados" &> /private/tmp/su.log & )
$pb $pbjson $canceljson &

while :;
do

	sleep 2
	[ -f "$canceljson" ] && { /bin/rm "$canceljson"; killall Progress; $pb $pbjson $canceljson &; }

	percent=$( /bin/cat /private/tmp/su.log | /usr/bin/grep "Installing: " | /usr/bin/tr '\r' '\n' | /usr/bin/tail -n1 | /usr/bin/awk '{ print int($2) }' )
	[ "$percent" -eq 0 ] && percent="1"
	[ "$percent" -ge 99 ] && percent="99"

	complete=$( /bin/cat /private/tmp/su.log | /usr/bin/tr '\r' '\n' | /usr/bin/grep -c "Install finished successfully" )
	failed=$( /bin/cat /private/tmp/su.log | /usr/bin/tr '\r' '\n' | /usr/bin/grep -c "Install failed with error" )

	[[ "$complete" == "1" ]] || [[ "$failed" == "1" ]] && { sleep 3; break; }

cat <<EOF > "$pbjson"
{
	"percentage": $percent,
	"title": "$msgdltitle $osexclude $downloados",
	"message": "macOS $percent% downloaded. Please wait.",
	"icon": "$updateicon"
}
EOF

done

[[ "$complete" == "1" ]] && message="macOS Download Completed" || message="macOS Download Failed"

cat <<EOF > "$pbjson"
{
	"percentage": 100,
	"title": "$msgdltitle $osexclude $downloados",
	"message": "$message",
	"icon": "$updateicon"
}
EOF

sleep 2
/usr/bin/killall Progress 2>/dev/null

# Error out if fail at this point
if [ "$failed" = "1" ];
then
	/usr/bin/killall Progress
	/bin/rm -f "$pbjson"
	/bin/rm -f "$canceljson"
	/bin/rm -f /private/tmp/su.log
	"$os" -e 'display dialog "'"$msgdlfailed"'" giving up after 15 with icon file "'"$iconposix"'" with title "'"$msgdltitle"'" buttons {"Ok"} default button 1'
	exit 0
fi

#
# Proceed with the OS work
#

startos=$( /usr/bin/find "/Applications" -iname "startosinstall" -type f )

[ "$mode" = "upgrade" ] && msgosupgtitle="Upgrading macOS" || msgosupgtitle="Erasing macOS to $downloados"

cat <<EOF > "$pbjson"
{
    "percentage": -1,
    "title": "$msgosupgtitle",
    "message": "Preparing to $mode ..",
    "icon": "$updateicon"
}
EOF

if [[ "$asmac" == "true" ]];
then
	# Apple Silicon macs. We need to prompt for the users credentials or this won't work. Skip this totally if in silent mode.

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

		# Clean up and quit.
		/usr/bin/killall Progress 2>/dev/null
		/usr/bin/killall caffeinate 2>/dev/null
		/bin/rm -f "$pbjson"
		/bin/rm -f "$canceljson"
		/bin/rm -f /private/tmp/su.log
		exit 1
	fi
fi

$pb $pbjson $canceljson &

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

if [ "$mode" = "upgrade" ];
then
	# macOS upgrade mode
	if [[ "$asmac" == "true" ]];
	then
		# Apple Silicon Macs
		echo "apple silicon upgrade startosinstall"
		"$startos" --agreetolicense --rebootdelay 120 --forcequitapps --user "$currentuser" --stdinpass <<< "$password" &> /private/tmp/upgrade.log &
	else
		# Intel Macs
		echo "intel upgrade startosinstall"
		"$startos" --agreetolicense --rebootdelay 120 --forcequitapps &> /private/tmp/update.log &
	fi
fi

if [ "$mode" = "erase" ];
then
	# macos erase to default mode
	if [[ "$asmac" == "true" ]];
	then
		# Apple Silicon Macs
		echo "apple silicon erase startosinstall"
		"$startos" --agreetolicense --eraseinstall --newvolumename "Macintosh HD" --rebootdelay 120 --forcequitapps --user "$currentuser" --stdinpass <<< "$password" &> /private/tmp/update.log &
	else
		# Intel Macs
		echo "intel erase startosinstall"
		"$startos" --agreetolicense --eraseinstall --newvolumename "Macintosh HD" --rebootdelay 120 --forcequitapps &> /private/tmp/update.log &
	fi
fi

while :;
do
	sleep 2
	[ -f "$canceljson" ] && { /bin/rm "$canceljson"; killall Progress; $pb $pbjson $canceljson &; }

	percent=$( /bin/cat /private/tmp/update.log | /usr/bin/grep "Preparing: " | /usr/bin/tr '\r' '\n' | /usr/bin/tail -n1 | /usr/bin/awk '{ print int($2) }' )

	[ "$percent" -eq 0 ] && percent="1"
	[ "$percent" -ge 99 ] && percent="99"

	test=$( /bin/cat /private/tmp/update.log | /usr/bin/tr '\r' '\n' | /usr/bin/grep -c "Waiting to restart" )
	[[ "$test" == "1" ]] && { break; }

cat <<EOF > "$pbjson"
{
	"percentage": $percent,
	"title": "$msgosupgtitle",
	"message": "macOS $mode $percent% completed. Please wait.",
	"icon": "$updateicon"
}
EOF
done

sleep 3

cat <<EOF > "$pbjson"
{
	"percentage": 100,
	"title": "$msgosupgtitle",
	"message": "macOS $mode completed. Restart IMMINENT.",
	"icon": "$updateicon"
}
EOF

# Clean up all files
/usr/bin/killall Progress 2>/dev/null
/usr/bin/killall caffeinate 2>/dev/null
/bin/rm -f "$pbjson"
/bin/rm -f "$canceljson"
/bin/rm -f /private/tmp/su.log
/bin/rm -f /private/tmp/update.log

exit

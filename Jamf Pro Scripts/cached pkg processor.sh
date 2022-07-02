#!/bin/zsh

# Cached application pkg processor script
# Meant to be run after an application installer is cached to the mac
# richard@richard-purves.com - 07-02-2022 - v1.3

# Variables here
waitroom="/Library/Application Support/JAMF/Waiting Room"
infofolder="/usr/local/corp/cachedapps"
apiusr=""
apipwd=""
jssurl=$( /usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url )

# Check that the info folder exists
# Create if missing and set appropriate permissions
/bin/mkdir -p "$infofolder"
/bin/chmod 755 "$infofolder"
/usr/sbin/chown root:wheel "$infofolder"

# Let's get to it!

# Check to see if the OS Install switch has been used
osappbundle="$4"

# Lastly work out todays date.
# We may use this in the future, but at the moment it probably won't be.
tdydate=$( /bin/date "+%Y-%m-%d %H:%M:%S" )

# Special case for the OS installer switch
if [ -z "$osappbundle" ];
then
  # We're not an OS install bundle
  /bin/echo "OS Installer not specified"

  # Find the most recent file in the Jamf Waiting Room folder
  # We're specifically looking for .pkg or .pkg.zip files. We don't want to deal with DMG packages and should not.
  # We also have to avoid any .pkg.cache.xml files as well. These contain info but it's not useful to us.

  # Find all the *.pkg or *.pkg.zip files in thw waiting room. Sort them by last modified date, old to new and then grab the last one.
  cachedpkg=$( find "$waitroom" -type f \( -iname \*.pkg -o -iname \*.pkg.zip \) -print0 |\
               xargs -0 ls -tr |\
               tail -n1 )

  # Did we pick up a file? Fail here if not.
  [[ -z "$cachedpkg" ]] && { echo "No package found."; exit 1; }

  # Strip off the full file path so we just have the name
  # Then remove the file extension from the name
  # Finally work out the cache folder patch
  pkgfilename=$( /usr/bin/basename "$cachedpkg" )
  displayname=${pkgfilename%.*}
  cachepath=$( /usr/bin/dirname "$cachedpkg" )

  # Use a Jamf API request to pull the pkg record from Jamf Pro.
  # Use xmllint's xpath to parse through the xml output to get the field we want.
  # Strip off the xml open and close tags, then store in a variable.
  pkgrecord=$( /usr/bin/curl -H "Accept: application/xml" -s -u "${apiusr}:${apipwd}" "${jssurl}JSSResource/packages/name/${pkgfilename}" -X GET )
  priority=$( echo $pkgrecord | /usr/bin/xmllint --format --xpath '//package/priority' - | /usr/bin/sed -e 's/<[^>]*>//g' )
  reboot=$( echo $pkgrecord | /usr/bin/xmllint --format --xpath '//package/reboot_required' - | /usr/bin/sed -e 's/<[^>]*>//g' )
  feu=$( echo $pkgrecord | /usr/bin/xmllint --format --xpath '//package/fill_existing_users' - | /usr/bin/sed -e 's/<[^>]*>//g' )
  fut=$( echo $pkgrecord | /usr/bin/xmllint --format --xpath '//package/fill_user_template' - | /usr/bin/sed -e 's/<[^>]*>//g' )

  # Now write out all the info we've collected to our cache file. We'll process these in another script.
  # The name of the file should be date-name.plist.
  # Create the file with plutil and then insert the keys required afterwards. Original defaults code was throwing weird errors from macOS 12.
  /usr/bin/plutil -create xml1 "$infofolder"/"${pkgfilename}".plist
  /usr/bin/plutil -insert PkgName -string "$pkgfilename" "$infofolder"/"${pkgfilename}".plist
  /usr/bin/plutil -insert FullPath -string "$cachepath" "$infofolder"/"${pkgfilename}".plist
  /usr/bin/plutil -insert DisplayName -string "$displayname" "$infofolder"/"${pkgfilename}".plist
  /usr/bin/plutil -insert Priority -integer "$priority" "$infofolder"/"${pkgfilename}".plist
  /usr/bin/plutil -insert Reboot -bool "$reboot" "$infofolder"/"${pkgfilename}".plist
  /usr/bin/plutil -insert CacheDate -date "$tdydate" "$infofolder"/"${pkgfilename}".plist
  /usr/bin/plutil -insert FEU -bool "$feu" "$infofolder"/"${pkgfilename}".plist
  /usr/bin/plutil -insert FUT -bool "$fut" "$infofolder"/"${pkgfilename}".plist
  /usr/bin/plutil -insert OSInstaller -bool FALSE "$infofolder"/"${pkgfilename}".plist

  # Look for any already cached pkgs and cache files. We already have a processed name from earlier.
  # Count number of dash characters in filename, then count number of spaces
  dashes=$( echo "$displayname" | awk -F\- '{print NF-1}' )
  spaces=$( echo "$displayname" | awk -F\  '{print NF-1}' )

  # Slice the name after the delimiter.
  # If we have dashes, process those otherwise move to spaces.
  # Thanks to many things here's the insanity that we have:
  # echo out the name of the package. Reverse it so it's backwards.
  # split the reversed name and tell cut command to include everything forward.
  # reverse everything again to get the correct output.
  # I wish there was something better than this but limited on our cli tools.
  if [ "$dashes" -gt "0" ];
  then
      name=$( echo $displayname | rev | cut -d"-" -f2- | rev )
  elif [ "$spaces" -gt "0" ];
  then
      name=$( echo $pkgname | rev | cut -d" " -f2- | rev )
  else
      echo "ERROR: Can't split filename. Can't detect duplicate names."
      exit 1
  fi

  # Remove any duplicates using some zsh search to exclude most recent modified date files.
  # Direct output from the rm commands to null because if there's no duplicates, it'll error.
  /bin/rm ${waitroom}/${name}*.pkg(.om[2,-1]) 2>&1 > /dev/null
  /bin/rm ${waitroom}/${name}*.pkg.zip(.om[2,-1]) 2>&1 > /dev/null
  /bin/rm ${waitroom}/${name}*.pkg.cache.xml(.om[2,-1]) 2>&1 > /dev/null
  /bin/rm ${infofolder}/*${name}*.plist(.om[2,-1]) 2>&1 > /dev/null
else
	# We are an OS installer. Special rules apply
	/bin/echo "OS Installer specified"

	# First find the app installer
	app=$( /usr/bin/find /Applications -iname "Install macOS*" -type d -maxdepth 1 )

	# Did we pick up an installer?
	if [ ! -z "$app" ];
	then
		# We did
		echo "Installer found: $app"

		# Work out it's name and path
		appname=$( /usr/bin/basename $app )
		apppath=$( /usr/bin/dirname $app )

		# Write out a mostly hard coded file for later processing. Make sure OSInstaller is set for later use.
		/usr/bin/plutil -create xml1 "$infofolder"/"$appname".plist
		/usr/bin/plutil -insert PkgName -string "$appname" "$infofolder"/"$appname".plist
		/usr/bin/plutil -insert FullPath -string "$apppath" "$infofolder"/"$appname".plist
		/usr/bin/plutil -insert DisplayName -string "$appname" "$infofolder"/"$appname".plist
		/usr/bin/plutil -insert Priority -integer 20 "$infofolder"/"$appname".plist
		/usr/bin/plutil -insert Reboot -bool FALSE "$infofolder"/"$appname".plist
		/usr/bin/plutil -insert CacheDate -date "$tdydate" "$infofolder"/"$appname".plist
		/usr/bin/plutil -insert FEU -bool FALSE "$infofolder"/"$appname".plist
		/usr/bin/plutil -insert FUT -bool FALSE "$infofolder"/"$appname".plist
		/usr/bin/plutil -insert OSInstaller -bool TRUE "$infofolder"/"$appname".plist
	else
		echo "Installer not found: $app"
	fi
fi

# All done. Package is ready for next cache install cycle.
exit 0

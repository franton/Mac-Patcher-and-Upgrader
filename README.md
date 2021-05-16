Mac Patcher and Upgrader
========================

This is a series of scripts and a deployment pkg to plug into your Jamf Pro system for both Application and OS based upgrades.

### Overview ###
  
* Gives a nice UI prompt to end users showing updates are available.
* Deferment mechanism allowing users not to update immediately unless they run out.
* Will update installed applications.
* If available, will upgrade the installed OS.
* Accurate progress bar information such as:
Installing application Cyberduck (1 of 5)
macOS upgrade 37% completed. Please wait.
* Default behavior is to NOT restart, but enabling that option on a pkg in Jamf will ensure particular upgrade(s) restarts the mac.
* Supports both Intel and Apple Silicon macs and all their little foibles.
* Uses familiar Jamf Pro constructs such as triggers, smart groups and policies.
* Local record of deferments used, last update time and last number of deferrments used for that update.
This is readable via standard defaults read commands in the supplied extension attributes.

Requirements
------------
* macOS 10.15 and above
* Jamf Pro. v10 is preferred but we're not using anything version specific.
* Cloud Distribution point or On-Prem HTTP distribution server(s).
* Progress Bar requires the [swift-progress](https://github.com/adriannier/swift-progress) app from [Adrian Nier](https://github.com/adriannier).

How to use
----------

1) Make sure your deployment pkgs have the format "name-version". e.g. "Cyberduck-7.9.0.pkg"
This ensures the app processing script will function. You will get an error if it can't parse the name!
2) Download the latest swift-progress release from the link above.
3) Make a signed deployment pkg with the files and folders in the "Package" folder.
4) Check then upload that pkg to your Jamf Pro instance. You will deploy this via existing mechanisms and/or deploy processes to your fleet.
5) Upload the main scripts to your Jamf Pro instance.
6) The cached pkg processor script can utilise the parameter four value. Call this "OS Installer (blank for no)"

API User Required
-----------------

Create a user account on your Jamf Pro instance. Give it an appropriate username and complex password. The ONLY permission that it requires is read access to "Packages".

The cached pkg processor will need those credentials in order to properly process the cached installer.

Jamf Pro Extension Attributes
-----------------------------

Upload the three supplied extension attribute scripts. You may need to customise the folder path they are using.

The EA's provide auditing information that may be useful such as current deferrals used, last update time and last number of deferrals used at last update.

Jamf Pro Smart Groups
---------------------

##### Example Application Update Group

You will need one of these per application. In this example, I'll be using CyberDuck.

**Name:** Update Cyberduck 7.9.0
**Criteria 1:** "Application Title" "is" "Cyberduck.app" 
**Criteria 2:** "and" "Application Version" "is not" "7.9.0"
**Criteria 3:** "and" "Cached Packages" "does not have" "Cyberduck-7.9.0.pkg"

What this does is to see if CyberDuck is installed, check the installed version and to then see if we've already cached an upgrade installer. That way we don't run unnecessarily.

Every time you update an application in Jamf, the appropriate group **must** be updated as well!

##### Example macOS Update Group

This is a special case and is not formatted like the other groups. For this example, macOS 11.3.1 is the latest version being offered.

**Name:** Update macOS Installer
**Criteria 1:** "Operating System Version" "less than" "11.3.1"
**Criteria 2:** "Application Title" "does not have" "Install macOS Big Sur.app"

Jamf Pro Scripts
----------------

##### main patcher installer.sh

This requires the simplest policy of all, as it's called every two hours by the LaunchDaemon in the deployment pkg.

**Name:** Run Patcher
**Trigger:** Custom
**Trigger event:** apppatch
**Execution Frequency:** ongoing
**Scripts:** Set this to run the main patcher installer script
**Maintenance:** Enable Update Inventory

This is the script that does all the user prompting, displays the progress bars and performs clean up.

##### cached pkg processor.sh

Once again, we'll use Cyberduck as an example but you'll have to create this per application.

**Name:** Cache Cyberduck
**Trigger:** Recurring Check-in
**Execution Frequency:** ongoing
**Packages:** Set this to **cache** Cyberduck-7.9.0.pkg
**Scripts:** Set this to run the cached pkg processor script
**Maintenance:** Enable Update Inventory

Scope any policies using this to the appropriate smart group for that application you created earlier.

##### download macos installer.sh

This again is a special case because the script is using softwareupdate to download the Install macOS app bundle directly to the Applications folder. As a result the policy is different to caching an application installer.

**Name:** Cache Cyberduck
**Trigger:** Recurring Check-in
**Execution Frequency:** ongoing
**Scripts:** Run the download macos installer script as "Before".
**Scripts:** Set this to run the cached pkg processor script as "After" and setting script parameter 4 to "yes"
**Maintenance:** Enable Update Inventory

Scope this policy to the macOS update group from earlier.

The script will attempt to download the latest macOS installer (caching server really useful here) and the special setting on the cached pkg script will cause that to look for an installer app bundle instead of a cached pkg.

### Enjoy! ###

### Special Thanks ###

[Lachlan Stewart](https://github.com/loceee). Without [patchoo](http://patchoo.github.io/patchoo) to inspire (and borrow ideas), this wouldn't exist.
[Joshua Roskos](https://github.com/kc9wwh). Your work on macOS startosinstall was invaluable and this is a massive extension on your work.
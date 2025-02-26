============================================================
Info:
============================================================

Windows NT 10.0 Updates Installer

Automated script to install or integrate updates for:
- Windows 10
- Windows 11
- Windows Server 2016, 2019, 2022

============================================================
Features:
============================================================

# Supported targets:
- Current Online OS
- Offline image (already mounted directory, or another partition)
- Distribution folder (extracted iso, copied dvd/usb)
- Distribution Drive (virtual mounted iso, inserted dvd drive, usb drive)
- WIM file directly (unmounted)

# Supports having updates in one folder:
- Detect and install servicing stack update first
- Skip installing non-winpe updates for boot.wim/winre.wim (flash, oobe, .net 4.x)
- Skip installing Adobe Flash update if not applicable
- Handle dynamic updates for setup media 'sources' folder (skip installing it, extract it for distribution target)

# Enable .NET Framework 3.5 if available source detected, and reinstall Cumulative updates afterwards
valid locations: mounted iso, inserted dvd/usb, sxs folder for distribution target, custom specified folder path

# Detect Windows ADK (Deployment Tools) for offline integration
https://docs.microsoft.com/windows-hardware/get-started/adk-install

# Perform pending cleanup operation for online OS after restarting:
you must run W10UI.cmd at least once after restart to perform Cleanup or Reset OS image, before installing any new updates

============================================================
Updated ISO recommendation:
============================================================

Creating updated iso file for a distribution target require either of:
- install Windows ADK
- place oscdimg.exe or cdimage.exe in the same folder next to W10UI.cmd

otherwise, embedded Powershell/.NET function DIR2ISO will be used to create the iso

============================================================
Limitations:
============================================================

- Updates version will not be checked for applicability
meaning for example, if 10240 updates are specified for 10586 target, the script will still proceed to install them
make sure to specify the correct updates files

- These extra updates are not processed correctly
the script will try to install them whether applicable, already installed or not
therefore, avoid using them with the script and install them manually

Remote Server Administration Tools (RSAT)
https://support.microsoft.com/en-us/help/2693643/

Media Feature Pack for Windows N editions
https://support.microsoft.com/en-us/help/3145500/

============================================================
How to:
============================================================

- Recommended Host OS: Windows 8.1 or later
- Updating offline images of Windows 11 builds 22567 and later, require at least Windows 10 v1607 Host OS
- Optional: place W10UI.cmd next to the updates (.msu/.cab) to detect them by default
- Run the script as administrator
- Change the options to suit your needs, make sure all are set correctly, do not use quotes marks "" in paths
- Press zero 0 to start the process
- At the end, Press 9 or q to exit, or close the windows with red X button

============================================================
Options:
============================================================

Press each option corresponding number/letter to change it

1. Target
target windows image, default is current online system if supported
if a wim file is available besides the script, it will be detected automatically

2. Updates
location of updates files

3. DISM
the path for custom dism.exe
required when the current Host OS is lower than Windows NT 10.0 and without ADK installed

4. Enable .NET 3.5
enable or disable adding .NET 3.5 feature

5. Cleanup System Image: YES      6. Reset Image Base: NO
in this choice, the OS images will be cleaned and superseded components will be "delta-compressed"
safe operation, but might take long time to complete.

5. Cleanup System Image: YES      6. Reset Image Base: YES
in this choice, the OS images will be rebased and superseded components will be "removed"
quick operation and reduce size further more, but will break "Reset this PC" feature.

7. Update WinRE.wim
available only if the target is a distribution folder, or WIM file
enable or disable updating winre.wim inside install.wim

8. Install.wim selected indexes
available only if the target is a distribution folder, or WIM file
a choice to select specific index(s) to update from install.wim, or all indexes by default

K. Keep indexes
available only if you selected specific index(s) in above option 8
a choice to only keep selected index(s) when rebuilding install.wim, or keep ALL indexes

M. Mount Directory
available only if the target is a distribution folder, or WIM file
mount directory for updating wim files, default is on the same drive as the script

E. Extraction Directory
directory for temporary extracted files, default is on the same drive as the script

============================================================
Configuration options (for advanced users):
============================================================

- Edit W10UI.ini to change the default value of the main options:
# Target
# Repo
# DismRoot
# Net35
# Cleanup
# ResetBase
# WinRE
# _CabDir
# MountDir

or set extra manual options below:

# Net35Source
specify custom "folder" path which contain microsoft-windows-netfx3-ondemand-package.cab

# ResetBase
require first to set Cleanup=1
change to 2 to run rebase after each LCU for builds 26052 and later

# LCUwinre
force updating winre.wim with Cumulative Update even if SafeOS update detected
auto enabled for builds 22000-26050, change to 2 to disable
ignored and auto disabled for builds 26052 and later

# LCUmsuExpand
expand Cumulative Update and install from loose files via update.mum, instead adding msu files directly
applicable only for builds 22621 and later
auto enabled for builds 26052 and later, change to 2 to disable

# UpdtBootFiles
update ISO boot files bootmgr/memtest/efisys.bin from Cumulative Update
this will also update new UEFI CA 2023 boot files if detected. See KB5053484 for details
note: the two default files bootmgr.efi/bootmgfw.efi will be updated if this option is OFF

# SkipEdge
1 = do not install EdgeChromium with Enablement Package or Cumulative Update
2 = alternative workaround to skip EdgeChromium with Cumulative Update only

# SkipWebView
do not install Edge WebView with Cumulative Update  

# wim2esd
convert install.wim to install.esd, if the target is a distribution
warning: the process will consume very high amount of CPU and RAM resources

# wim2swm
split install.wim into multiple install.swm files, if the target is a distribution

note: if both wim2esd/wim2swm are 1, install.esd takes precedence over split install.swm

# ISO
create new iso file, if the target is a distribution

# ISODir
folder path for iso file, leave it blank to create in the script current directory

# Delete_Source
keep or delete DVD distribution folder after creating updated ISO

# AutoStart
start the process automatically once you execute the script
the option will also auto exit at the end without prompt

# UseWimlib
detect and use wimlib-imagex.exe for exporting wim files / processing msu wim files, instead dism.exe

# WimCreateTime
change install.wim image creation time to match last modification time
this option require wimlib-imagex.exe, but it doesn't require to enable UseWimlib option itself

# AddDrivers
add drivers to install.wim and boot.wim / winre.wim

this is basic feature support, and should be used only with tested working compatible drivers.
it is meant for simple and boot critical drivers (chipsets, disk controllers, LAN/WiFi..), to allow easier installation, not for large drivers, or drivers that may break setup.
it will not check or verify drivers, it simply point DISM towards the drivers folders.

How To Use:

enable "AddDrivers" option

place the drivers (loose inf files) you want to add inside the proper subfolder:

ALL   / drivers will be added to all wim files
OS    / drivers will be added to install.wim only
WinPE / drivers will be added to boot.wim / winre.wim only

# Drv_Source
optional, specify different source folder path for drivers
the folder must contain subfolder for each drivers target, as explained above.

- Note: Do not change the structure of W10UI.ini, just set your options after the equal sign =

- To restore old behavior and change options by editing the script, simply delete W10UI.ini file

============================================================
Debug Mode (for advanced users):
============================================================

# Create a log file of the integration process for debugging purposes

# The operation progress will not be shown in this mode

# How To:
- edit the script and change set _Debug=0 to 1
- set main manual options correctly, specially "target" and "repo"
- save and run the script as admin
- wait until command prompt window is closed and W10UI_Debug.log is created

============================================================
Credits:
============================================================

Created:
https://forums.mydigitallife.net/members/abbodi1406.204274/

Concept:
https://forums.mydigitallife.net/members/burfadel.84828/

WHDownloader:
https://forums.mydigitallife.net/threads/44645

PSFExtractor:
https://www.betaworld.org
https://github.com/Secant1006/PSFExtractor

SxSExpand:
Melinda Bellemore
https://forums.mydigitallife.net/members/superbubble.250156/

DIR2ISO code / Compressed2TXT:
https://github.com/AveYo

Powershell .NET Reflection code for msu wim:
https://github.com/ave9858

WinSxS Suppressors:
https://github.com/asdcorp/haveSxS

Special thanks for testing and feedback:
@Enthousiast, @Paul Mercer, @Clusterhead

============================================================
Changelog:
============================================================

https://github.com/abbodi1406/BatUtil/tree/master/W10UI#changelog

or

https://pastebin.com/raw/iyePnwV1

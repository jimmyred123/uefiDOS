@echo off
cls
echo ===================================================================
echo               uefiDOS APPLIANCE - EDIT MODE REQUEST
echo ===================================================================
echo Requesting reboot into Maintenance & Edit Mode...
echo When the system prompts at boot, enter the 5-character
echo verification code to unlock slot management and VHD tools.
echo ===================================================================
if exist B:\REBOOT.COM B:\REBOOT.COM
if exist REBOOT.COM REBOOT.COM

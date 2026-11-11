@echo off
cls
echo ===================================================================
echo               uefiDOS STORAGE & DRIVE ROUTING TABLE
echo ===================================================================
if exist B:\PARTMAP.CFG (
    type B:\PARTMAP.CFG
) else (
    echo [i] Dynamic drive router inactive. Direct RAW Passthrough mode.
)
echo ===================================================================

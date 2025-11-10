@echo off
REM sync-comics.bat - Synchronize local pictures folder to phone's DCIM\Comics
REM 
REM Features:
REM - Only synchronizes .jpg files (all other file types ignored)
REM - Silently skips files that already exist on phone (no output)
REM - Creates new directories on phone as needed
REM - Moves orphaned .jpg files (files on phone not found locally) to 'Purchased' folder
REM - Moves all .jpg files from orphaned directories to 'Purchased'
REM - Empty directories require manual deletion (MTP limitation)
REM - Excludes 'Purchased' folder from sync
REM - Never deletes local files

REM Configuration
set PHONE_NAME=rakshasa
set LOCAL_PATH=D:\src\legalize\ComicCovers\pictures

echo ============================================
echo Comic Cover Synchronization (.jpg only)
echo ============================================
echo.
echo Phone: %PHONE_NAME%
echo Local Path: %LOCAL_PATH%
echo.
echo This script will:
echo  1. Move orphaned .jpg files/directories to 'Purchased'
echo  2. Create new directories as needed
echo  3. Copy only new .jpg files to phone
echo  4. Skip existing files (silent)
echo  5. Ignore all non-.jpg files
echo  6. List empty directories at the end
echo.
echo Note: Empty directories are not deleted automatically
echo.
echo ============================================
echo.

powershell -ExecutionPolicy Bypass -File "%~dp0sync-comics-to-phone.ps1" -LocalPath "%LOCAL_PATH%" -PhoneName "%PHONE_NAME%"

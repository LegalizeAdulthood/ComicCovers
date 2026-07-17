@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM sync-comics.bat - Synchronize local pictures folder to phone's DCIM\Comics
REM 
REM Features:
REM - Only synchronizes .jpg files under DCIM\Comics
REM - Silently skips files that already exist under DCIM\Comics
REM - Creates new directories under DCIM\Comics as needed
REM - Reports same-named folders directly under DCIM without using them
REM - Leaves phone-only .jpg files in place unless --move-orphans is passed
REM - With --move-orphans, moves phone-only .jpg files/directories to 'Purchased'
REM - With --count n, stops after n planned or real phone filesystem changes
REM - Empty directories require manual deletion (MTP limitation)
REM - Excludes 'Purchased' folder from sync
REM - Never deletes local files

REM Configuration
set PHONE_NAME=rakshasa
set "LOCAL_PATH=%~dp0pictures"
set "EXTRA_ARGS="

:parse_args
if "%~1"=="" goto args_done
if /I "%~1"=="--dry-run" (
    set "EXTRA_ARGS=!EXTRA_ARGS! -DryRun"
    shift
    goto parse_args
)
if /I "%~1"=="--move-orphans" (
    set "EXTRA_ARGS=!EXTRA_ARGS! -MoveOrphans"
    shift
    goto parse_args
)
if /I "%~1"=="--count" (
    if "%~2"=="" (
        echo Error: --count requires a value.
        exit /b 1
    )
    set "EXTRA_ARGS=!EXTRA_ARGS! -Count %~2"
    shift
    shift
    goto parse_args
)
set "EXTRA_ARGS=!EXTRA_ARGS! %1"
shift
goto parse_args

:args_done

echo ============================================
echo Comic Cover Synchronization (.jpg only)
echo ============================================
echo.
echo Phone: %PHONE_NAME%
echo Local Path: %LOCAL_PATH%
if not "%EXTRA_ARGS%"=="" echo Options:%EXTRA_ARGS%
echo.
echo This script will:
echo  1. Leave phone-only .jpg files in place unless --move-orphans is passed
echo  2. Create new directories as needed
echo  3. Copy only new .jpg files to phone
echo  4. Skip existing files under DCIM\Comics (silent)
echo  5. Ignore all non-.jpg files
echo  6. List empty directories at the end
echo  7. Report same-named folders directly under DCIM as stale
echo  8. Stop after --count filesystem changes when --count is passed
echo.
echo Note: Empty directories are not deleted automatically
echo.
echo ============================================
echo.

powershell -ExecutionPolicy Bypass -File "%~dp0sync-comics-to-phone.ps1" -LocalPath "%LOCAL_PATH%" -PhoneName "%PHONE_NAME%" %EXTRA_ARGS%

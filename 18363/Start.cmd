@echo off
title 官方 ISO 打补丁… Patching Official ISO... 19H2-1909 - v18363 x64

cd /d "%~dp0"
if NOT "%cd%"=="%cd: =%" (
	echo 当前路径目录包含空格。
	echo 请移除或重命名目录不包含空格。
	echo Current directory contains spaces in its path.
    echo Please move or rename the directory to one not containing spaces.
    echo.
    pause
    goto :EOF
)

if "[%1]" == "[49127c4b-02dc-482e-ac4f-ec4d659b7547]" goto :START_PROCESS
REG QUERY HKU\S-1-5-19\Environment >NUL 2>&1 && goto :START_PROCESS

set command="""%~f0""" 49127c4b-02dc-482e-ac4f-ec4d659b7547
SETLOCAL ENABLEDELAYEDEXPANSION
set "command=!command:'=''!"

powershell -NoProfile Start-Process -FilePath '%COMSPEC%' ^
-ArgumentList '/c """!command!"""' -Verb RunAs 2>NUL

IF %ERRORLEVEL% GTR 0 (
    echo =====================================================
    echo 此脚本需要使用管理员权限执行。
    echo This script needs to be executed as an administrator.
    echo =====================================================
    echo.
    pause
)

SETLOCAL DISABLEDELAYEDEXPANSION
goto :EOF

:START_PROCESS
set "isofile=cn_windows_10_consumer_editions_version_1903_x64_dvd_8f05241d.iso"
set "aria2=aria2c.exe"
set "a7z=7z.exe"
set "patchDir=patch"
set "ISODir=ISO"
set "aria2Script=aria2_script_x64.txt"

if NOT EXIST %aria2% goto :NO_ARIA2_ERROR
if NOT EXIST %a7z% goto :NO_FILE_ERROR

if NOT EXIST "%isofile%" (set "isofile=cn_windows_10_business_editions_version_1903_x64_dvd_e001dd2c.iso")
if NOT EXIST "%isofile%" goto :NO_ISO_ERROR

echo 正在下载补丁…
echo Patch Downloading...
"%aria2%" --no-conf -x16 -s16 -j5 -c -R -d"%patchDir%" -i"%aria2Script%"
if %ERRORLEVEL% GTR 0 call :DOWNLOAD_ERROR & exit /b 1

if EXIST "%~dp0%ISODir%" rmdir /s /q "%~dp0%ISODir%"
%a7z% x "%~dp0%isofile%" -o"%~dp0%ISODir%" -r

if EXIST W10UI.cmd goto :START_WORKWORK
pause
goto :EOF

:START_WORKWORK
call W10UI.cmd
goto :EOF

:NO_ARIA2_ERROR
echo 当前目录未找到 %aria2%。
echo We couldn't find %aria2% in current directory.
echo.
echo 可以从此下载 aria2：
echo You can download aria2 from:
echo https://aria2.github.io/
echo.
pause
goto :EOF

:NO_FILE_ERROR
echo 没发现脚本所需文件。
echo We couldn't find one of needed files for this script.
pause
goto :EOF

:NO_ISO_ERROR
echo 请把官方 ISO 文件放到脚本同目录下。
echo Please put official  ISO file next to the script.
pause
goto :EOF

:DOWNLOAD_ERROR
echo.
echo 下载文件错误，请重新尝试。
echo We have encountered an error while downloading files.
pause
goto :EOF

echo 输入 7 退出。
echo Press 7 to exit.
choice /c 7 /n
if errorlevel 1 (goto :eof) else (rem.)

:EOF


@echo off
for /f "tokens=2 delims=:" %%a in ('chcp') do set oldchcp=%%a
set oldchcp=%oldchcp: =%
chcp 65001
title 官方 ISO 打补丁… Patching Official ISO...

cd /d "%~dp0"
if not "%cd%"=="%cd: =%" (
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
set "aria2=bin\aria2c.exe"
set "a7z=bin\7z.exe"
set "patchDir=patch"
set "ISODir=ISO"
set "build="
set "arch="
set "isServer="

if not exist "%patchDir%" mkdir "%patchDir%"
if exist "%patchDir%\aria2.log" del /f /q "%patchDir%\aria2.log"

setlocal EnableDelayedExpansion
set /a isoCount=0
set "isofile="

for %%f in (*.iso) do (
    set /a isoCount+=1
    set "isofile=%%f"
)

if !isoCount! EQU 0 (
    endlocal
    goto :NO_ISO_ERROR
)

if !isoCount! GTR 1 (
    endlocal
    goto :NO_ISO_PATCHED_ERROR
)

endlocal & set "isofile=%isofile%"

if exist "%~dp0%ISODir%" rmdir /s /q "%~dp0%ISODir%"
%a7z% x "%~dp0%isofile%" -o"%~dp0%ISODir%" -r
if %ERRORLEVEL% NEQ 0 (
    echo =====================================================
    echo ISO 解压失败，文件可能已损坏。
    echo ISO extraction failed, the file may be corrupted.
    echo =====================================================
    pause
    goto :EOF
)

set "IMG=%~dp0%ISODir%\sources\install.wim"
if not exist "%IMG%" set "IMG=%~dp0%ISODir%\sources\install.esd"

%a7z% l "%IMG%" | findstr /i "Windows\\winsxs\\pending.xml" >nul
if not errorlevel 1 (
    echo =====================================================
    echo 警告：该 ISO 包含 pending.xml。请使用干净官方 ISO。
    echo Warning: This ISO contains pending.xml. Please use a clean official ISO.
    echo =====================================================
    pause
    goto :EOF
)

set imgcount=0
if exist "%~dp0%ISODir%\sources\install.esd" (
    for /f "tokens=2 delims=: " %%# in ('dism.exe /English /Get-WimInfo /WimFile:"%~dp0%ISODir%\sources\install.esd" ^| find /i "Index"') do (
        set imgcount=%%#
    )
)
for /L %%# in (1,1,%imgcount%) do (
    dism.exe /English /Export-Image /SourceImageFile:"%~dp0%ISODir%\sources\install.esd" /SourceIndex:%%# /DestinationImageFile:"%~dp0%ISODir%\sources\install.wim" /Compress:max
)
if exist "%~dp0%ISODir%\sources\install.wim" if exist "%~dp0%ISODir%\sources\install.esd" del /f /q "%~dp0%ISODir%\sources\install.esd"

if not exist "%~dp0%ISODir%\sources\install.wim" (goto :NOT_SUPPORT)

dism.exe /english /get-wiminfo /wimfile:"%~dp0%ISODir%\sources\install.wim" /index:1 | findstr /i /c:"Version : 10." /c:"Version : 11." >nul || (
    set "MESSAGE=发现 wim 版本不是 Windows 10 或 11 / Detected wim version is not Windows 10 or 11"
    goto :EOF
)

for /f "tokens=4 delims=:. " %%# in ('dism.exe /english /get-wiminfo /wimfile:"%~dp0%ISODir%\sources\install.wim" /index:1 ^| find /i "Version :"') do set build=%%#
for /f "tokens=2 delims=: " %%# in ('dism.exe /english /get-wiminfo /wimfile:"%~dp0%ISODir%\sources\install.wim" /index:1 ^| find /i "Architecture"') do set arch=%%#
for /f "tokens=1" %%i in ('dism.exe /english /get-wiminfo /wimfile:"%~dp0%ISODir%\sources\install.wim" /index:1 ^| find /i "Default"') do set lang=%%i
dism.exe /english /get-wiminfo /wimfile:"%~dp0%ISODir%\sources\install.wim" /index:1 | findstr /i /c:"ProductType : ServerNT" >nul && set isServer=1

if %build%==19042 (set "build=19041"
) else if %build%==19043 (set "build=19041"
) else if %build%==19044 (set "build=19041"
) else if %build%==19045 (set "build=19041"
) else if %build%==20349 (set "build=20348"
) else if %build%==22631 (set "build=22621"
) else if %build%==26200 (set "build=26100")

if not exist %aria2% goto :NO_ARIA2_ERROR
if not exist %a7z% goto :NO_FILE_ERROR

set "metaFile=Scripts\script_%build%_%arch%.meta4"

if "%build%"=="26100" if defined isServer (
    set "metaFile=Scripts\script_server_%build%_%arch%.meta4"
)

if not exist "%metaFile%" goto :NOT_SUPPORT

echo 正在下载补丁…
echo Patches Downloading...
"%aria2%" --no-conf --check-certificate=false -x16 -s16 -j5 -c -R -d "%patchDir%" -M "%metaFile%" --log="%patchDir%\aria2.log" --log-level=notice
if %ERRORLEVEL% GTR 0 (
    call :DOWNLOAD_ERROR
    exit /b 1
)

set netfx481=
for /f "tokens=2 delims==" %%i in ('findstr /b "netfx481" W10UI.ini') do (
    set netfx481=%%i
)

rem === Download .NET Framework patches ===
if "%build%" geq "19041" if "%build%" leq "22000" (
    if "%netfx481%" equ "1" (
        if exist "Scripts\netfx4.8.1\script_netfx4.8.1_%build%_%arch%.meta4" (
            "%aria2%" --no-conf --check-certificate=false -x16 -s16 -j5 -c -R -d "%patchDir%" -M "Scripts\netfx4.8.1\script_netfx4.8.1_%build%_%arch%.meta4" --metalink-language="neutral" --log="%patchDir%\aria2.log" --log-level=notice
            if "%lang%" neq "en-US" (
                "%aria2%" --no-conf --check-certificate=false -x16 -s16 -j5 -c -R -d "%patchDir%" -M "Scripts\netfx4.8.1\script_netfx4.8.1_%build%_%arch%.meta4" --metalink-language="%lang%" --log="%patchDir%\aria2.log" --log-level=notice
            )
        ) else if exist "Scripts\netfx4.8\script_netfx4.8_%build%_%arch%.meta4" (
            "%aria2%" --no-conf --check-certificate=false -x16 -s16 -j5 -c -R -d "%patchDir%" -M "Scripts\netfx4.8\script_netfx4.8_%build%_%arch%.meta4" --metalink-language="neutral" --log="%patchDir%\aria2.log" --log-level=notice
        )
    ) else if "%netfx481%" neq "1" if exist "Scripts\netfx4.8\script_netfx4.8_%build%_%arch%.meta4" (
        "%aria2%" --no-conf --check-certificate=false -x16 -s16 -j5 -c -R -d "%patchDir%" -M "Scripts\netfx4.8\script_netfx4.8_%build%_%arch%.meta4" --metalink-language="neutral" --log="%patchDir%\aria2.log" --log-level=notice
    )
)

if "%build%" geq "14393" if "%build%" leq "17763" (
    if exist "Scripts\netfx4.8\script_netfx4.8_%build%_%arch%.meta4" (
        "%aria2%" --no-conf --check-certificate=false -x16 -s16 -j5 -c -R -d "%patchDir%" -M "Scripts\netfx4.8\script_netfx4.8_%build%_%arch%.meta4" --metalink-language="neutral" --log="%patchDir%\aria2.log" --log-level=notice
        if "%lang%" neq "en-US" (
            "%aria2%" --no-conf --check-certificate=false -x16 -s16 -j5 -c -R -d "%patchDir%" -M "Scripts\netfx4.8\script_netfx4.8_%build%_%arch%.meta4" --metalink-language="%lang%" --log="%patchDir%\aria2.log" --log-level=notice
        )
    )
)

if exist W10UI.cmd goto :START_WORKWORK
pause
goto :EOF

:START_WORKWORK
chcp %oldchcp% >nul
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
echo 未发现脚本所需文件。
echo We couldn't find one of needed files for this script.
pause
goto :EOF

:NO_ISO_ERROR
echo 请把官方 ISO 文件放到脚本同目录下。
echo Please put official ISO file next to the script.
pause
goto :EOF

:NO_ISO_PATCHED_ERROR
echo 目录中存在多个 ISO 文件，请检查是否已经生成或复制过多 ISO 文件。
echo Multiple ISO files found, please check if already generated or copied extra ISOs.
pause
goto :EOF

:DOWNLOAD_ERROR
echo 下载文件错误，请重新尝试。
echo We have encountered an error while downloading files.
pause
goto :EOF

:NOT_SUPPORT
rmdir /s /q "%~dp0%ISODir%"
echo 不支持此 ISO 版本。或 ISO 文件异常。
echo 版本：%build%，架构：%arch%
echo Not support this version ISO. or the ISO file error.
echo Version: %build%, Architecture: %arch%
pause
goto :EOF

:EOF
echo 输入 7 退出。
echo Press 7 to exit.
choice /c 7 /n
if errorlevel 1 (goto :eof) else (rem.)

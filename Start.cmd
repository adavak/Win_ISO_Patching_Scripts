@echo off
for /f "tokens=2 delims=:" %%a in ('chcp') do set "oldchcp=%%a"
set "oldchcp=%oldchcp: =%"
if not "%oldchcp%"=="65001" chcp 65001 >nul
set "langCN="
for /f "tokens=3" %%i in ('reg query "HKCU\Control Panel\Desktop" /v PreferredUILanguages 2^>nul') do if /i "%%i"=="zh-CN" set "langCN=1"
if not defined langCN for /f "tokens=3" %%i in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\MUI\Settings" /v PreferredUILanguages 2^>nul') do if /i "%%i"=="zh-CN" set "langCN=1"
if not defined langCN for /f "tokens=3" %%i in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Nls\Language" /v Default 2^>nul') do if /i "%%i"=="0804" set "langCN=1"
set "zh="
set "en="
if defined langCN set "en=rem "
if not defined langCN set "zh=rem "
%zh%title 官方 ISO 打补丁…
%en%title Patching Official ISO...
color 0A

cd /d "%~dp0"
if not "%cd%"=="%cd: =%" (
    echo.
    echo ================================================
%zh%    echo 当前路径目录包含空格。
%zh%    echo 请移除或重命名目录不包含空格。
%en%    echo Current directory contains spaces in its path.
%en%    echo Please move or rename the directory to one not containing spaces.
    echo ================================================
    echo.
pause
    goto :EXIT
)

if "[%1]" == "[49127c4b-02dc-482e-ac4f-ec4d659b7547]" goto :START_PROCESS
REG QUERY HKU\S-1-5-19\Environment >NUL 2>&1 && goto :START_PROCESS

set "command="""%~f0""" 49127c4b-02dc-482e-ac4f-ec4d659b7547"
setlocal EnableDelayedExpansion
set "command=!command:'=''!"

powershell -NoProfile Start-Process -FilePath '%COMSPEC%' ^
-ArgumentList '/c """!command!"""' -Verb RunAs 2>NUL

if %ERRORLEVEL% EQU 1223 (
    echo.
    echo ================================================
%zh%    echo 已取消管理员提权。本脚本需要管理员权限运行。
%en%    echo UAC prompt cancelled. This script needs administrator rights.
    echo ================================================
    echo.
pause
) else if %ERRORLEVEL% GTR 0 (
    echo.
    echo ================================================
%zh%    echo 此脚本需要使用管理员权限执行。
%en%    echo This script needs to be executed as an administrator.
    echo ================================================
    echo.
pause
) else (
    endlocal
    exit /b 0
)
endlocal
goto :EXIT

:START_PROCESS
echo.
echo ================================================
%zh%echo   官方 ISO 打补丁工具
%en%echo   Official ISO Patching
echo ================================================
echo.

rem --- detect host architecture (works across WOW64) ---
set "xOS=amd64"
if /i "%PROCESSOR_ARCHITECTURE%"=="arm64" set "xOS=arm64"
if /i "%PROCESSOR_ARCHITECTURE%"=="x86" if "%PROCESSOR_ARCHITEW6432%"=="" set "xOS=x86"
if /i "%PROCESSOR_ARCHITEW6432%"=="amd64" set "xOS=amd64"
if /i "%PROCESSOR_ARCHITEW6432%"=="arm64" set "xOS=arm64"

for /f "tokens=3,* delims= " %%i in ('REG QUERY "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v "CurrentBuildNumber"') do (
set OSBuildNumber=%%i
)

if /i "%xOS%"=="amd64" if exist "bin\bin64\7z.exe" if exist "bin\bin64\aria2c.exe" (
    set "aria2=bin\bin64\aria2c.exe"
    set "a7z=bin\bin64\7z.exe"
)
if /i "%xOS%"=="arm64" if %OSBuildNumber% GEQ 22000 if exist "bin\bin64\7z.exe" if exist "bin\bin64\aria2c.exe" (
    set "aria2=bin\bin64\aria2c.exe"
    set "a7z=bin\bin64\7z.exe"
)
if /i "%xOS%"=="x86" if exist "bin\7z.exe" if exist "bin\aria2c.exe" (
    set "aria2=bin\aria2c.exe"
    set "a7z=bin\7z.exe"
)
if /i "%xOS%"=="arm64" if %OSBuildNumber% LSS 22000 if exist "bin\7z.exe" if exist "bin\aria2c.exe" (
    set "aria2=bin\aria2c.exe"
    set "a7z=bin\7z.exe"
)
set "patchDir=patch"
set "ISODir=ISO"
set "build="
set "arch="
set "lang="
set "isServer="

set "dism=dism.exe"
set "dismroot="
for /f "tokens=2 delims==" %%i in ('findstr /b /i "DismRoot" W10UI.ini') do set "dismroot=%%i"
if /i not "%dismroot%"=="dism.exe" if defined dismroot if exist "%dismroot%" set "dism=%dismroot%"
set "KitsRoot="
if "%dism%"=="dism.exe" for /f "skip=2 tokens=2*" %%i in ('reg.exe query "HKLM\Software\Wow6432Node\Microsoft\Windows Kits\Installed Roots" /v KitsRoot10 2^>nul') do set "KitsRoot=%%j"
if "%dism%"=="dism.exe" if not defined KitsRoot for /f "skip=2 tokens=2*" %%i in ('reg.exe query "HKLM\Software\Microsoft\Windows Kits\Installed Roots" /v KitsRoot10 2^>nul') do set "KitsRoot=%%j"
if defined KitsRoot if exist "%KitsRoot%Assessment and Deployment Kit\Deployment Tools\%xOS%\DISM\dism.exe" set "dism=%KitsRoot%Assessment and Deployment Kit\Deployment Tools\%xOS%\DISM\dism.exe"
if not "%dism%"=="dism.exe" (
%zh%    echo 使用 DISM: "%dism%"
%en%    echo Using DISM: "%dism%"
)

if not exist "%patchDir%" mkdir "%patchDir%"
if exist "%patchDir%\aria2.log" del /f /q "%patchDir%\aria2.log"

echo.
%zh%echo [1/4] 检查 ISO 文件
%en%echo [1/4] Checking ISO...
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

echo.
%zh%echo [2/4] 解压 ISO
%en%echo [2/4] Extracting ISO...
"%dism%" /cleanup-wim >nul 2>&1
if exist "%~dp0%ISODir%" rmdir /s /q "%~dp0%ISODir%"
%a7z% x "%~dp0%isofile%" -o"%~dp0%ISODir%" -r
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ================================================
%zh%    echo ISO 解压失败，文件可能已损坏。
%en%    echo ISO extraction failed, the file may be corrupted.
    echo ================================================
pause
    goto :EXIT
)

set "IMG=%~dp0%ISODir%\sources\install.wim"
if not exist "%IMG%" set "IMG=%~dp0%ISODir%\sources\install.esd"

%a7z% l "%IMG%" | findstr /i "Windows\\winsxs\\pending.xml" >nul
if not errorlevel 1 (
    echo.
    echo ================================================
%zh%    echo 警告：该 ISO 包含 pending.xml。请使用干净官方 ISO。
%en%    echo Warning: This ISO contains pending.xml. Please use a clean official ISO.
    echo ================================================
pause
    goto :EXIT
)

set imgcount=0
if exist "%~dp0%ISODir%\sources\install.esd" (
    echo.
    %zh%echo [3/4] 转换 ESD 为 WIM
    %en%echo [3/4] Converting ESD to WIM...
    for /f "tokens=2 delims=: " %%# in ('"%dism%" /English /Get-WimInfo /WimFile:"%~dp0%ISODir%\sources\install.esd" ^| find /i "Index"') do (
        set imgcount=%%#
    )
    if exist "%~dp0%ISODir%\sources\install.wim" del /f /q "%~dp0%ISODir%\sources\install.wim"
)
for /L %%# in (1,1,%imgcount%) do (
    "%dism%" /English /Export-Image /SourceImageFile:"%~dp0%ISODir%\sources\install.esd" /SourceIndex:%%# /DestinationImageFile:"%~dp0%ISODir%\sources\install.wim" /Compress:max
    if errorlevel 1 (
        echo.
        echo ================================================
%zh%        echo ESD 转 WIM 失败（索引 %%#）。
%en%        echo ESD to WIM conversion failed ^(index %%#^).
        echo ================================================
pause
        goto :EXIT
    )
)
if exist "%~dp0%ISODir%\sources\install.wim" if exist "%~dp0%ISODir%\sources\install.esd" del /f /q "%~dp0%ISODir%\sources\install.esd"

if not exist "%~dp0%ISODir%\sources\install.wim" goto :NOT_SUPPORT

"%dism%" /english /get-wiminfo /wimfile:"%~dp0%ISODir%\sources\install.wim" /index:1 | findstr /i /c:"Version : 10." /c:"Version : 11." >nul || (
    echo.
    echo ================================================
%zh%    echo 发现 wim 版本不是 Windows 10 或 11。
%en%    echo Detected wim version is not Windows 10 or 11.
    echo ================================================
pause
    goto :EXIT
)

set "wiminfo=%TEMP%\wiminfo_%RANDOM%.txt"
"%dism%" /english /get-wiminfo /wimfile:"%~dp0%ISODir%\sources\install.wim" /index:1 > "%wiminfo%"
for /f "tokens=4 delims=:. " %%# in ('findstr /i /c:"Version :" "%wiminfo%"') do set build=%%#
for /f "tokens=2 delims=: " %%# in ('findstr /i /c:"Architecture" "%wiminfo%"') do set arch=%%#
for /f "tokens=1" %%i in ('findstr /i /c:"Default" "%wiminfo%"') do set lang=%%i
findstr /i /c:"ProductType : ServerNT" "%wiminfo%" >nul && set isServer=1
del /f /q "%wiminfo%"

if "%build%"=="" goto :NOT_SUPPORT
if %build% GEQ 19042 if %build% LEQ 19045 set "build=19041"
if %build% EQU 20349 set "build=20348"
if %build% EQU 22631 set "build=22621"
if %build% GEQ 26200 if %build% LEQ 26300 set "build=26100"

if not exist "%aria2%" goto :NO_ARIA2_ERROR
if not exist "%a7z%" goto :NO_FILE_ERROR

set "metaFile=Scripts\script_%build%_%arch%.meta4"

if "%build%"=="26100" if defined isServer (
    set "metaFile=Scripts\script_server_%build%_%arch%.meta4"
)

if not exist "%metaFile%" goto :NOT_SUPPORT

echo.
%zh%echo [4/4] 下载补丁
%en%echo [4/4] Downloading patches...
%zh%echo 构建: %build%   架构: %arch%   语言: %lang%
%en%echo Build: %build%   Arch: %arch%   Lang: %lang%
%zh%echo 正在下载补丁…
%en%echo Patches Downloading...
call :ARIA2_DL_RETRY "%metaFile%"
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
            call :ARIA2_DL_RETRY "Scripts\netfx4.8.1\script_netfx4.8.1_%build%_%arch%.meta4" neutral
            if "%lang%" neq "en-US" call :ARIA2_DL_RETRY "Scripts\netfx4.8.1\script_netfx4.8.1_%build%_%arch%.meta4" "%lang%"
        ) else if exist "Scripts\netfx4.8\script_netfx4.8_%build%_%arch%.meta4" (
            call :ARIA2_DL_RETRY "Scripts\netfx4.8\script_netfx4.8_%build%_%arch%.meta4" neutral
        )
    ) else if "%netfx481%" neq "1" if exist "Scripts\netfx4.8\script_netfx4.8_%build%_%arch%.meta4" (
        call :ARIA2_DL_RETRY "Scripts\netfx4.8\script_netfx4.8_%build%_%arch%.meta4" neutral
    )
)

if "%build%" geq "14393" if "%build%" leq "17763" (
    if exist "Scripts\netfx4.8\script_netfx4.8_%build%_%arch%.meta4" (
        call :ARIA2_DL_RETRY "Scripts\netfx4.8\script_netfx4.8_%build%_%arch%.meta4" neutral
        if "%lang%" neq "en-US" call :ARIA2_DL_RETRY "Scripts\netfx4.8\script_netfx4.8_%build%_%arch%.meta4" "%lang%"
    )
)

echo.
%zh%echo 补丁下载完成
%en%echo Patches downloaded.
if exist W10UI.cmd goto :START_WORKWORK
pause
goto :EXIT

:START_WORKWORK
chcp %oldchcp% >nul
call W10UI.cmd
goto :EXIT

:ARIA2_DL_RETRY
rem %1 = meta4 路径 / meta4 path
rem %2 = metalink 语言(可选)/ language (optional)
rem Retry up to 5 attempts. Clear downloaded patches between attempts so that
rem aria2 -c does not skip files that failed SHA-1 verification.
set /a dlretry=0
:ARIA2_DL_RETRY_LOOP
set /a dlretry+=1
if !dlretry! GTR 5 exit /b 1
call :ARIA2_DL "%~1" %2
if %ERRORLEVEL% EQU 0 exit /b 0
if !dlretry! GEQ 5 exit /b 1
%zh%echo 下载失败（第 !dlretry! 次/共 5 次），清除补丁文件后重试…
%en%echo Download failed (attempt !dlretry!/5), clearing patches and retrying...
del /q "%patchDir%\*.msu" "%patchDir%\*.cab" "%patchDir%\*.msu.aria2" "%patchDir%\*.cab.aria2" 2>nul
goto :ARIA2_DL_RETRY_LOOP

:ARIA2_DL
rem %1 = meta4 路径 / meta4 path
rem %2 = metalink 语言(可选)/ language (optional)
if "%~2"=="" (
    "%aria2%" --no-conf --check-certificate=false -x16 -s16 -j5 -c -R -d "%patchDir%" -M "%~1" --log="%patchDir%\aria2.log" --log-level=notice
) else (
    "%aria2%" --no-conf --check-certificate=false -x16 -s16 -j5 -c -R -d "%patchDir%" -M "%~1" --metalink-language=%~2 --log="%patchDir%\aria2.log" --log-level=notice
)
exit /b

:NO_ARIA2_ERROR
echo.
echo ================================================
%zh%echo 当前目录未找到 %aria2%。
%en%echo We couldn't find %aria2% in current directory.
echo.
%zh%echo 可以从此下载 aria2：
%en%echo You can download aria2 from:
echo https://aria2.github.io/
echo ================================================
pause
goto :EXIT

:NO_FILE_ERROR
echo.
echo ================================================
%zh%echo 未发现脚本所需文件。
%en%echo We couldn't find one of needed files for this script.
echo ================================================
pause
goto :EXIT

:NO_ISO_ERROR
echo.
echo ================================================
%zh%echo 请把官方 ISO 文件放到脚本同目录下。
%en%echo Please put official ISO file next to the script.
echo ================================================
pause
goto :EXIT

:NO_ISO_PATCHED_ERROR
echo.
echo ================================================
%zh%echo 目录中存在多个 ISO 文件，请检查是否已经生成或复制过多 ISO 文件。
%en%echo Multiple ISO files found, please check if already generated or copied extra ISOs.
echo ================================================
pause
goto :EXIT

:DOWNLOAD_ERROR
echo.
echo ================================================
%zh%echo 下载文件错误，请重新尝试。
%en%echo We have encountered an error while downloading files.
echo ================================================
pause
goto :EXIT

:NOT_SUPPORT
rmdir /s /q "%~dp0%ISODir%"
echo.
echo ================================================
%zh%echo 不支持此 ISO 版本。或 ISO 文件异常。
%zh%echo 版本：%build%，架构：%arch%
%en%echo Not support this version ISO. or the ISO file error.
%en%echo Version: %build%, Architecture: %arch%
echo ================================================
pause
goto :EXIT

:EXIT
echo.
%zh%echo 按 7 退出
%en%echo Press 7 to exit.
choice /c 7 /n
exit /b 0

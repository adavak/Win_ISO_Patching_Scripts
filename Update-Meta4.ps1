<#
.SYNOPSIS
    Auto-update meta4 patch manifest files for Win_ISO_Patching_Scripts
.DESCRIPTION
    Searches Microsoft Update Catalog for the latest Windows updates and
    generates/updates .meta4 files (aria2 Metalink format) in the Scripts directory.
    
    Usage:
    1. Install MSCatalogLTS module: Install-Module -Name MSCatalogLTS -Scope CurrentUser -Force
    2. Run: .\Update-Meta4.ps1
    
    The script automatically:
    - Finds latest Cumulative Updates (LCU) for each Windows version
    - Finds latest Servicing Stack Updates (SSU)
    - Finds latest Setup Dynamic Updates (Setup DU)
    - Generates corresponding meta4 files
.PARAMETER ScriptsDir
    Directory containing meta4 files (default: Scripts folder next to this script)
.PARAMETER OutputDir
    Output directory (default: same as ScriptsDir)
.PARAMETER WhatIf
    Preview changes without writing files
.PARAMETER InstallModule
    Auto-install MSCatalogLTS module if missing
.EXAMPLE
    .\Update-Meta4.ps1
    Update all meta4 files
.EXAMPLE
    .\Update-Meta4.ps1 -WhatIf
    Preview changes
.EXAMPLE
    .\Update-Meta4.ps1 -InstallModule
    Install dependencies and update
.NOTES
    Author: adavak
    Requires: MSCatalogLTS module, PowerShell 5.1+, internet access
#>

param(
    [string]$ScriptsDir = "",
    [string]$OutputDir = "",
    [switch]$WhatIf,
    [switch]$InstallModule
)

# Resolve directories
if (-not $ScriptsDir) {
    $ScriptsDir = Join-Path $PSScriptRoot "Scripts"
}
if (-not $OutputDir) {
    $OutputDir = $ScriptsDir
}

# Validate directories
if (-not (Test-Path $ScriptsDir)) {
    Write-Error "Scripts directory not found: $ScriptsDir"
    exit 1
}
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# ============================================================
# Windows version configuration
# ============================================================
$WindowsVersions = @(
    @{ Build = "14393"; Arch = @("x64","x86"); SearchName = @("Windows 10 Version 1607","Windows Server 2016"); NeedSSU = $true; NeedSetupDU = $false }
    @{ Build = "17763"; Arch = @("x64","x86","arm64"); SearchName = @("Windows 10 Version 1809","Windows Server 2019"); NeedSSU = $true; NeedSetupDU = $false }
    @{ Build = "19041"; Arch = @("x64","x86","arm64"); SearchName = @("Windows 10 Version 22H2","Windows 10 Version 21H2"); NeedSSU = $true; NeedSetupDU = $true }
    @{ Build = "20348"; Arch = @("x64"); SearchName = @("Windows Server 2022"); NeedSSU = $true; NeedSetupDU = $true }
    @{ Build = "22621"; Arch = @("x64","arm64"); SearchName = @("Windows 11 Version 23H2","Windows 11 Version 22H2"); NeedSSU = $true; NeedSetupDU = $true }
    @{ Build = "26100"; Arch = @("x64","arm64"); SearchName = @("Windows 11 Version 24H2","Windows 11 Version 25H2","Windows Server 2025"); NeedSSU = $true; NeedSetupDU = $true }
    @{ Build = "28000"; Arch = @("x64","arm64"); SearchName = @("Windows 11 Version 26H1"); NeedSSU = $true; NeedSetupDU = $true }
)

# ============================================================
# Helper functions
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

function New-Meta4Content {
    param([array]$Files)
    if ($Files.Count -eq 0) { return $null }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    $null = $sb.AppendLine('<metalink xmlns="urn:ietf:params:xml:ns:metalink"')
    $null = $sb.AppendLine('	xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="metalink4.xsd">')
    foreach ($file in $Files) {
        $null = $sb.AppendLine("	<file name=""$($file.Name)"">")
        $null = $sb.AppendLine("		<hash type=""sha-1"">$($file.Hash)</hash>")
        $null = $sb.AppendLine("		<url>$($file.Url)</url>")
        $null = $sb.AppendLine("	</file>")
    }
    $null = $sb.AppendLine('</metalink>')
    return $sb.ToString()
}

function Get-ExistingMeta4Files {
    param([string]$MetaFilePath)
    $files = @()
    if (-not (Test-Path $MetaFilePath)) { return $files }
    try {
        [xml]$xml = Get-Content $MetaFilePath -ErrorAction Stop
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace("ml", "urn:ietf:params:xml:ns:metalink")
        $fileNodes = $xml.SelectNodes("//ml:file", $ns)
        if ($fileNodes.Count -eq 0) { $fileNodes = $xml.SelectNodes("//file") }
        foreach ($fileNode in $fileNodes) {
            $name = $fileNode.GetAttribute("name")
            $hashNode = $fileNode.SelectSingleNode("ml:hash", $ns)
            if (-not $hashNode) { $hashNode = $fileNode.SelectSingleNode("hash") }
            $urlNode = $fileNode.SelectSingleNode("ml:url", $ns)
            if (-not $urlNode) { $urlNode = $fileNode.SelectSingleNode("url") }
            if ($name -and $hashNode -and $urlNode) {
                $files += @{ Name = $name; Hash = $hashNode.InnerText.Trim(); Url = $urlNode.InnerText.Trim() }
            }
        }
    }
    catch {
        Write-Log "  Failed to read existing meta4: $_" -Color "Yellow"
    }
    return $files
}

function Save-Meta4File {
    param([string]$FilePath, [string]$Content)
    if ($WhatIf) {
        Write-Log "  [WhatIf] Would write: $FilePath" -Color "DarkYellow"
        return $true
    }
    try {
        $Content | Out-File -FilePath $FilePath -Encoding utf8 -Force
        Write-Log "  Saved: $FilePath" -Color "Green"
        return $true
    }
    catch {
        Write-Log "  Save failed: $_" -Color "Red"
        return $false
    }
}

function Ensure-MSCatalogLTSModule {
    $moduleName = "MSCatalogLTS"
    $module = Get-Module -Name $moduleName -ListAvailable -ErrorAction SilentlyContinue
    if ($module) {
        Write-Log "MSCatalogLTS v$($module.Version) is available" -Color "Green"
        Import-Module -Name $moduleName -Force -ErrorAction SilentlyContinue
        return $true
    }
    try {
        Import-Module -Name $moduleName -ErrorAction SilentlyContinue -PassThru | Out-Null
        if (Get-Module -Name $moduleName -ErrorAction SilentlyContinue) {
            Write-Log "MSCatalogLTS module loaded" -Color "Green"
            return $true
        }
    }
    catch {}
    if ($InstallModule) {
        Write-Log "Installing MSCatalogLTS module..." -Color "Yellow"
        try {
            Install-Module -Name $moduleName -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Import-Module -Name $moduleName -Force -ErrorAction Stop
            Write-Log "MSCatalogLTS installed successfully" -Color "Green"
            return $true
        }
        catch {
            Write-Log "Installation failed: $_" -Color "Red"
            Write-Log "Please run: Install-Module -Name MSCatalogLTS -Scope CurrentUser -Force" -Color "Yellow"
            return $false
        }
    }
    Write-Log "MSCatalogLTS module not found" -Color "Red"
    Write-Log "Please run: Install-Module -Name MSCatalogLTS -Scope CurrentUser -Force" -Color "Yellow"
    return $false
}

# ============================================================
# Search functions
# ============================================================

function Find-LatestLCU {
    param([string]$SearchName, [string]$Arch)
    Write-Log "    Searching LCU: $SearchName $Arch" -Color "DarkGray"
    try {
        $results = Get-MSCatalogUpdate -Search "$SearchName $Arch Cumulative Update" -ErrorAction SilentlyContinue |
            Where-Object { $_.Title -match "Cumulative Update" -and $_.Title -match "\b$Arch\b" } |
            Sort-Object LastUpdated -Descending | Select-Object -First 1
        if (-not $results) {
            $results = Get-MSCatalogUpdate -Search "$SearchName Cumulative Update" -ErrorAction SilentlyContinue |
                Where-Object { $_.Title -match "Cumulative Update" -and $_.Title -match "\b$Arch\b" } |
                Sort-Object LastUpdated -Descending | Select-Object -First 1
        }
        return $results
    }
    catch {
        Write-Log "    Search failed: $_" -Color "Red"
        return $null
    }
}

function Find-LatestSSU {
    param([string]$SearchName, [string]$Arch)
    Write-Log "    Searching SSU: $SearchName $Arch" -Color "DarkGray"
    try {
        $results = Get-MSCatalogUpdate -Search "$SearchName Servicing Stack $Arch" -ErrorAction SilentlyContinue |
            Where-Object { $_.Title -match "Servicing Stack" -and $_.Title -match "\b$Arch\b" } |
            Sort-Object LastUpdated -Descending | Select-Object -First 1
        return $results
    }
    catch { return $null }
}

function Find-LatestSetupDU {
    param([string]$SearchName, [string]$Arch)
    Write-Log "    Searching Setup DU: $SearchName $Arch" -Color "DarkGray"
    try {
        $results = Get-MSCatalogUpdate -Search "$SearchName Setup Dynamic Update $Arch" -ErrorAction SilentlyContinue |
            Where-Object { $_.Title -match "Setup Dynamic Update" -and $_.Title -match "\b$Arch\b" } |
            Sort-Object LastUpdated -Descending | Select-Object -First 1
        return $results
    }
    catch { return $null }
}

function Get-UpdateFiles {
    param([object]$Update)
    if (-not $Update) { return @() }
    try {
        # 直接调用 MSCatalogLTS 内部的 Get-UpdateLinks 获取下载链接
        # 不需要实际下载任何文件
        $links = & (Get-Command Get-UpdateLinks -Module MSCatalogLTS) -Guid $Update.Guid
        if ($links) {
            return $links | ForEach-Object {
                $url = $_.URL
                $fileName = $url.Split('/')[-1]
                # 从文件名提取 SHA1 哈希（文件名格式: kbXXXXXX-arch_HASH.ext）
                $hash = if ($fileName -match '_([a-f0-9]{40})\.') { $matches[1] } else { "" }
                @{ Name = $fileName; Url = $url; Hash = $hash }
            }
        }
    }
    catch {
        Write-Log "    Get-UpdateLinks failed: $_" -Color "Red"
    }
    return @()
}

# ============================================================
# Main
# ============================================================

Write-Log "============================================================" -Color "Cyan"
Write-Log "  Win_ISO_Patching_Scripts Meta4 Updater" -Color "Cyan"
Write-Log "============================================================" -Color "Cyan"
Write-Log ""

if (-not (Ensure-MSCatalogLTSModule)) { exit 1 }

Write-Log "Checking network..." -Color "Gray"
try {
    $wc = New-Object System.Net.WebClient
    $wc.DownloadString("https://www.catalog.update.microsoft.com") | Out-Null
    $wc.Dispose()
    Write-Log "Network OK" -Color "Green"
}
catch {
    Write-Log "Cannot reach Microsoft Update Catalog" -Color "Red"
    exit 1
}

Write-Log ""

$totalUpdated = 0
$totalSkipped = 0
$totalErrors = 0

foreach ($version in $WindowsVersions) {
    $build = $version.Build
    foreach ($arch in $version.Arch) {
        $metaFileName = "script_${build}_${arch}.meta4"
        $metaFilePath = Join-Path $OutputDir $metaFileName
        
        if (-not (Test-Path $metaFilePath)) {
            Write-Log "Skip $metaFileName (not found)" -Color "Gray"
            continue
        }
        
        Write-Log "Processing: $metaFileName" -Color "Yellow"
        
        $existingFiles = Get-ExistingMeta4Files $metaFilePath
        Write-Log "  Existing: $($existingFiles.Count) file(s)" -Color "Gray"
        
        $newFiles = @()
        $foundAny = $false
        
        foreach ($searchName in $version.SearchName) {
            $lcu = Find-LatestLCU -SearchName $searchName -Arch $arch
            if ($lcu) {
                $kbMatch = [regex]::Match($lcu.Title, 'KB(\d+)')
                $kbStr = if ($kbMatch.Success) { "KB$($kbMatch.Groups[1].Value)" } else { "?" }
                Write-Log "  Found LCU: $kbStr - $($lcu.LastUpdated)" -Color "Green"
                $foundAny = $true
                $lcuFiles = Get-UpdateFiles -Update $lcu
                foreach ($f in $lcuFiles) {
                    if ($f.Name -match "\.(msu|cab)$" -and $f.Name -match $arch) {
                        $newFiles += $f
                    }
                }
            }
            
            if ($version.NeedSSU) {
                $ssu = Find-LatestSSU -SearchName $searchName -Arch $arch
                if ($ssu) {
                    $kbMatch = [regex]::Match($ssu.Title, 'KB(\d+)')
                    $kbStr = if ($kbMatch.Success) { "KB$($kbMatch.Groups[1].Value)" } else { "?" }
                    Write-Log "  Found SSU: $kbStr - $($ssu.LastUpdated)" -Color "Green"
                    $foundAny = $true
                    $ssuFiles = Get-UpdateFiles -Update $ssu
                    foreach ($f in $ssuFiles) {
                        if ($f.Name -match "\.(msu|cab)$" -and $f.Name -match $arch) {
                            $newFiles += $f
                        }
                    }
                }
            }
            
            if ($version.NeedSetupDU) {
                $du = Find-LatestSetupDU -SearchName $searchName -Arch $arch
                if ($du) {
                    $kbMatch = [regex]::Match($du.Title, 'KB(\d+)')
                    $kbStr = if ($kbMatch.Success) { "KB$($kbMatch.Groups[1].Value)" } else { "?" }
                    Write-Log "  Found Setup DU: $kbStr - $($du.LastUpdated)" -Color "Green"
                    $foundAny = $true
                    $duFiles = Get-UpdateFiles -Update $du
                    foreach ($f in $duFiles) {
                        if ($f.Name -match "\.(msu|cab)$" -and $f.Name -match $arch) {
                            $newFiles += $f
                        }
                    }
                }
            }
        }
        
        if ($foundAny -and $newFiles.Count -gt 0) {
            $newFiles = $newFiles | Sort-Object Name -Unique
            Write-Log "  Generating meta4 with $($newFiles.Count) file(s)" -Color "Green"
            $meta4Content = New-Meta4Content -Files $newFiles
            if ($meta4Content) {
                if (Save-Meta4File -FilePath $metaFilePath -Content $meta4Content) {
                    $totalUpdated++
                } else {
                    $totalErrors++
                }
            }
        } else {
            if (-not $foundAny) {
                Write-Log "  No updates found" -Color "Red"
            } else {
                Write-Log "  Found updates but could not get download info" -Color "Yellow"
            }
            $totalSkipped++
        }
        
        Write-Log ""
        Start-Sleep -Milliseconds 500
    }
}

Write-Log ""
Write-Log "============================================================" -Color "Cyan"
Write-Log "  Complete" -Color "Cyan"
Write-Log "  Updated: $totalUpdated" -Color "Green"
Write-Log "  Skipped: $totalSkipped" -Color "Gray"
Write-Log "  Errors: $totalErrors" -Color "Red"
Write-Log "============================================================" -Color "Cyan"

if ($WhatIf) {
    Write-Log ""
    Write-Log "Note: -WhatIf was used, no files were written" -Color "DarkYellow"
    Write-Log "Remove -WhatIf to actually update files" -Color "DarkYellow"
}

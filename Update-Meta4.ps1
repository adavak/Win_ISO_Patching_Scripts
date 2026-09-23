# Update-Meta4.ps1
# Generates .meta4 files via the Update Catalog supersedence chain + version name cross-validation.
# README build versions come from the Catalog title, then the KB article on support.microsoft.com, then the LCU itself.
[CmdletBinding()]
param([string[]]$Build = @(), [string[]]$Arch = @(), [string]$OutputDir = "", [switch]$TestMode)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ScriptRoot = $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $ScriptRoot "Scripts" }
if (-not (Test-Path $OutputDir)) { New-Item $OutputDir -ItemType Directory -Force | Out-Null }

$reCatId = [regex]"id='([a-f0-9\-]{36})_link'"
$reDlUrl = [regex]"downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']*)'"
$reScopedKb = [regex]'(?s)<div id="supersededbyInfo">(.*?)<span'
$reScopedLink = [regex]"<a[^>]*href='([^']*)'[^>]*>([^<]+)</a>"
$reScopedGuid = [regex]'updateid=([a-f0-9\-]{36})'

$reBuildSuffix = [regex]'\((\d{4,6})\.(\d+)\)'
$reOsBuild = [regex]'\(OS Builds? ([\d.]+(?:\s+and\s+[\d.]+)*)\)'
$reAssemblyId = [regex]'<assemblyIdentity\b[^>]*>'

$CFG = @{}
$w10 = "windows10.0"; $w11 = "windows11.0"

function BuildCfg($op, $lb, $ver=$null, $s3, $s1=$null, $s4=$null, $srvVer=$null) {
    $os = if ($op -eq $w11) { "Windows 11" } else { "Windows 10" }
    $pfx = if ($ver) { "$os Version $ver" } elseif ($srvVer) { "Microsoft server operating system version $srvVer" } else { "Microsoft server operating system version 21H2" }
    $h = @{OP=$op; L=$lb; S1="Cumulative Update for $pfx"; S3=$s3; S5="Setup Dynamic Update for $pfx"; S6="Safe OS Dynamic Update for $pfx"}
    if ($s4)  { $h.S4 = $s4 }
    if ($srvVer) { $h.SRV = $true }
    return $h
}

$CFG["14393"] = BuildCfg $w10 "LTSB 2016"        "1607" ".NET Framework 4.8 Windows 10 1607"               -s1 $true
$CFG["17763"] = BuildCfg $w10 "LTSC 2019"        "1809" ".NET Framework 4.8 Windows 10 1809"
$CFG["19041"] = BuildCfg $w10 "22H2 / LTSC 2021" "22H2" ".NET Framework 4.8 Windows 10 22H2"            -s4 ".NET Framework 4.8.1 Windows 10 22H2"
$CFG["20348"] = BuildCfg $w10 "Server 2022"      $null  ".NET Framework 4.8 Microsoft server operating system version 21H2" -s4 "Cumulative Update for .NET Framework 3.5 and 4.8.1 Microsoft server operating system version 21H2"
$CFG["22621"] = BuildCfg $w11 "Win 11 23H2"      "23H2" $null            -s4 ".NET Framework 4.8.1 Windows 11 23H2"
$CFG["26100"] = BuildCfg $w11 "25H2"             "25H2" $null            -s4 ".NET Framework 3.5 and 4.8.1 for Windows 11, version 25H2"
$CFG["26100-server"] = BuildCfg $w11 "Server 2025" -s3 $null -s4 ".NET Framework 3.5 and 4.8.1 Microsoft server operating system version 24H2" -srvVer "24H2"
$CFG["28000"] = BuildCfg $w11 "26H1"             "26H1" $null            -s4 ".NET Framework 4.8.1 Windows 11 26H1"
$ARCH_LABEL = @{x64="for x64-based Systems"; x86="for x86-based Systems"; arm64="for Arm64-based Systems"}

function Retry-WebRequest {
    param($Url, [hashtable]$Body, $ContentType, [int]$TimeoutSec = 30)
    $delays = @(0, 30, 120, 300)  # 4 total attempts
    $retry = 0
    while ($retry -lt $delays.Count) {
        if ($delays[$retry] -gt 0) { Start-Sleep -Seconds $delays[$retry] }
        try {
            $params = @{ UseBasicParsing = $true; TimeoutSec = $TimeoutSec }
            if ($Body) { $params['Method'] = 'Post'; $params['Body'] = $Body; $params['ContentType'] = $ContentType }
            return Invoke-WebRequest $Url @params
        } catch {
            $retry++
            if ($retry -ge $delays.Count) { throw }
        }
    }
}
$searchCache = @{}
function Search-Catalog { param($Q)
    if ($searchCache.ContainsKey($Q)) { return $searchCache[$Q] }
    $r = Retry-WebRequest -Url ("https://www.catalog.update.microsoft.com/v7/site/Search.aspx?q=" + [uri]::EscapeDataString($Q))
    $h = $r.Content; $ret = @()
    foreach ($m in $reCatId.Matches($h)) {
        $g = $m.Groups[1].Value; $e = $h.IndexOf("</a>", $m.Index + $m.Length)
        if ($e -le 0) { continue }
        $r2 = $h.Substring($m.Index + $m.Length, $e - $m.Index - $m.Length)
        $gt = $r2.IndexOf('>'); if ($gt -ge 0) { $r2 = $r2.Substring($gt + 1) }
        $t = ($r2 -replace '<[^>]+>', '').Trim()
        if ($t) { $ret += [PSCustomObject]@{Guid = $g; Title = $t} }
    }
    $searchCache[$Q] = $ret
    return $ret
}
$linksCache = @{}
function Get-Links { param($Guid)
    if ($linksCache.ContainsKey($Guid)) { return $linksCache[$Guid] }
    $r = Retry-WebRequest -Url "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" -Body @{UpdateIDs = "[{size:0,UpdateID:'$Guid',UpdateIDInfo:'$Guid'}]"} -ContentType "application/x-www-form-urlencoded"
    $c = $r.Content -replace "www.download.windowsupdate", "download.windowsupdate"
    $out = @()
    foreach ($m in $reDlUrl.Matches($c)) {
        $url = $m.Groups[1].Value; $fn = $url.Split('/')[-1]
        $sha1 = ""; if ($fn -match '_([a-f0-9]{40})\.(msu|cab)$') { $sha1 = $matches[1] }
        $kb = 0; if ($url -match 'kb(\d+)') { $kb = [int]$matches[1] }
        $out += [PSCustomObject]@{FileName = $fn; Url = $url; Sha1 = $sha1; KB = $kb}
    }
    $result = @($out | Sort-Object Url -Unique)
    $linksCache[$Guid] = $result
    return $result
}

$chainCache = @{}
$chainDegraded = $true    # cleared by Follow-Chain only when it resolves a real supersedence chain
function Follow-Chain { param($OldKb, $ArchPat, $OsPref, [switch]$Server)
    # Filters by server operating system when -Server is set.
    $key = "$OldKb|$ArchPat|$Server"; if ($chainCache.ContainsKey($key)) { return $chainCache[$key] }
    $r = Search-Catalog "$OldKb"
    if ($Server) {
        $first = $r | Where-Object { $_.Title -match $ArchPat -and $_.Title -match 'server operating system' } | Select-Object -First 1
    } else {
        $first = $r | Where-Object { $_.Title -match $ArchPat -and $_.Title -notmatch 'server operating system' } | Select-Object -First 1
    }
    if (-not $first) { $chainCache[$key] = $null; return $null }
    try { $sv = Retry-WebRequest -Url ("https://www.catalog.update.microsoft.com/v7/site/ScopedViewInline.aspx?updateid=" + $first.Guid)
    } catch { $chainCache[$key] = $null; return $null }
    $html = $sv.Content
    $match = $reScopedKb.Match($html)
    if (-not $match.Success) {
        Write-Host "  [chain] KB$OldKb supersedence page unusable, using its own file list" -ForegroundColor Yellow
        $script:chainDegraded = $true
        $ll = Get-Links $first.Guid; $chainCache[$key] = $ll; return $ll
    }
    $links = $reScopedLink.Matches($match.Groups[1].Value)
    if ($links.Count -eq 0) {
        Write-Host "  [chain] KB$OldKb has no supersedence links, using its own file list" -ForegroundColor Yellow
        $script:chainDegraded = $true
        $ll = Get-Links $first.Guid; $chainCache[$key] = $ll; return $ll
    }
    $sorted = $links | Sort-Object { $_.Groups[2].Value } -Descending
    $guid = if ($sorted[0].Groups[1].Value -match $reScopedGuid) { $matches[1] }
    if (-not $guid) { $chainCache[$key] = $null; return $null }
    $result = Get-Links $guid
    $script:chainDegraded = $false
    $chainCache[$key] = $result; return $result
}

function Bootstrap-Search { param($Term, $ArchPat, $OsPref, $Kind)
    $r = Search-Catalog $Term
    if ($Kind -eq "LCU") {
        $best = $r | Where-Object { $_.Title -match $ArchPat -and $_.Title -match 'Cumulative Update' -and $_.Title -notmatch '\.NET' } | Sort-Object Title -Descending | Select-Object -First 1
    } else {
        # For .NET: prefer pure "4.8" over combined updates including "4.8.1" or "4.7.2"
        $candidates = $r | Where-Object { $_.Title -match $ArchPat -and $_.Title -match '\.NET' }
        $best = $candidates | Where-Object { $_.Title -notmatch '4\.7\.2' }
        if ($Term -notmatch '4\.8\.1') { $best = $best | Where-Object { $_.Title -notmatch '4\.8\.1' } }
        if ($Term -match '4\.8\.1') { $best = $best | Where-Object { $_.Title -notmatch '4\.8\s+and\s+4\.8\.1' } }
        $best = $best | Sort-Object Title -Descending | Select-Object -First 1
        if (-not $best) { $best = $candidates | Sort-Object Title -Descending | Select-Object -First 1 }
    }
    # If arch-specific search fails (some x86 .NET updates lack "for x86" in title),
    # try finding an entry without any architecture tag
    if (-not $best -and $Kind -ne "LCU") {
        $candidates = $r | Where-Object { $_.Title -match '\.NET' -and $_.Title -notmatch 'for (x64|arm64)' }
        $best = $candidates | Where-Object { $_.Title -notmatch '4\.7\.2' }
        if ($Term -notmatch '4\.8\.1') { $best = $best | Where-Object { $_.Title -notmatch '4\.8\.1' } }
        if ($Term -match '4\.8\.1') { $best = $best | Where-Object { $_.Title -notmatch '4\.8\s+and\s+4\.8\.1' } }
        $best = $best | Sort-Object Title -Descending | Select-Object -First 1
        if (-not $best) { $best = $candidates | Sort-Object Title -Descending | Select-Object -First 1 }
    }
    if (-not $best) { return $null }
    $links = Get-Links $best.Guid
    # If the top candidate has no ndp*.msu files, try the next in descending order
    $ndpCount = ($links | Where-Object { $_.FileName -match 'ndp.*\.msu$' }).Count
    if ($ndpCount -eq 0 -and $Kind -ne 'LCU') {
        $altCandidates = $candidates | Where-Object { $_.Guid -ne $best.Guid } | Sort-Object Title -Descending
        foreach ($alt in $altCandidates) {
            $altLinks = Get-Links $alt.Guid
            if (($altLinks | Where-Object { $_.FileName -match 'ndp.*\.msu$' }).Count -gt 0) { $links = $altLinks; $best = $alt; break }
        }
    }
    $m = $links | Where-Object { $_.FileName -match [regex]::Escape($OsPref) }
    if (-not $m) { $m = $links }
    if ($Kind -eq "LCU") { return ($m | Where-Object { $_.FileName -match '\.msu$' -and $_ -notmatch 'ndp' } | Sort-Object KB -Descending | Select-Object -First 1) }
    return ($m | Where-Object { $_.FileName -match 'ndp.*\.msu$' } | Select-Object -First 1)
}

function Pick-File($Links, $Kind, $OsPref) {
    $m = $Links | Where-Object { $_.FileName -match [regex]::Escape($OsPref) }
    if (-not $m) { $m = $Links }
    if ($Kind -eq "LCU") { return ($m | Where-Object { $_.FileName -match '\.msu$' -and $_ -notmatch 'ndp' } | Sort-Object KB -Descending | Select-Object -First 1) }
    if ($Kind -eq "SSU") { return ($m | Where-Object { $_.FileName -match '\.msu$' -and $_ -notmatch 'ndp' } | Sort-Object KB | Select-Object -First 1) }
    if ($Kind -eq "NET") {
        # Ensure .NET OS prefix matches the target build (e.g. windows10.0 != windows11.0)
        $r = $m | Where-Object { $_.FileName -match 'ndp.*\.msu$' }
        $filtered = $r | Where-Object { $_.FileName -match "^$OsPref" }
        if ($filtered) { $r = $filtered }
        return $r | Select-Object -First 1
    }
    return $m | Select-Object -First 1
}

function New-Meta4($F) {
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('<metalink xmlns="urn:ietf:params:xml:ns:metalink"')
    $null = $sb.AppendLine("`txmlns:xsi=""http://www.w3.org/2001/XMLSchema-instance"" xsi:noNamespaceSchemaLocation=""metalink4.xsd"">")
    foreach ($f in $F) {
        $null = $sb.AppendLine("`t<file name=""$($f.FileName)"">")
        # Preserve <language> tag (used in netfx subdirs)
        if ($f.Language -and $f.Language -ne "") {
            $null = $sb.AppendLine("`t`t<language>$($f.Language)</language>")
        }
        $null = $sb.AppendLine("`t`t<hash type=""sha-1"">$($f.Sha1)</hash>")
        $null = $sb.AppendLine("`t`t<url>$($f.Url)</url>")
        $null = $sb.AppendLine("`t</file>")
    }
    $null = $sb.AppendLine('</metalink>')
    return $sb.ToString()
}
function Get-Cabs($P) {
    if (-not (Test-Path $P)) { return @() }
    try { $x = [xml](Get-Content $P -Raw)
        return ,($x.metalink.file | Where-Object { $_.name -match '\.cab$' } | ForEach-Object {
            $ckb = 0; if ($_.name -match 'kb(\d+)') { $ckb = [int]$matches[1] }
            [PSCustomObject]@{FileName = $_.name; Url = $_.url; Sha1 = $_.hash.'#text'; KB = $ckb} })
    } catch { return @() }
}
function Get-KB($F) { if ($F.FileName -match 'kb(\d+)') { $matches[1] } else { "" } }
function Get-OldKB($Path, $Kind, $ArchPat = "") {
    if (-not (Test-Path $Path)) { return $null }
    try { $x = [xml](Get-Content $Path -Raw)
        $all = $x.metalink.file
        if ($Kind -eq "LCU") {
            # Search catalog to find the actual LCU (title contains "Cumulative Update")
            # SSU/Safe OS/Setup DU titles don't contain "Cumulative Update", so they're auto-excluded
            $cands = $all | Where-Object { $_.name -match '\.msu$' -and $_.name -notmatch 'ndp' } | Sort-Object { if ($_.name -match 'kb(\d+)') { [int]$matches[1] } else { 0 } } -Descending
            foreach ($c in $cands) {
                if ($c.name -match 'kb(\d+)') {
                    $ckb = [int]$matches[1]
                    try {
                        $r = Search-Catalog "kb$ckb"
                        $t = ($r | Where-Object { $_.Title -match $ArchPat } | Select-Object -First 1).Title
                        if ($t -match 'Cumulative Update' -and $t -notmatch '\.NET') {
                            return $ckb
                        }
                    } catch { continue }
                }
            }
            # Fallback: all catalog requests failed — abort
            throw "Catalog unreachable: all Get-OldKB LCU queries failed for $Path"
        }
        if ($Kind -eq "NET") {
            $first = $all | Where-Object { $_.name -match 'ndp.*\.msu$' } | Select-Object -First 1
            if ($first -and $first.name -match 'kb(\d+)') { return [int]$matches[1] }
        }
    } catch { }
    return $null
}

# --- Cross-validate: chain vs bootstrap ---
function Cross-Validate($ChainFile, $BootFile) {
    if (-not $ChainFile -and -not $BootFile) { return $null, "SKIP" }
    if ($ChainFile -and $BootFile) {
        if ($ChainFile.KB -eq $BootFile.KB) { return $ChainFile, "verified" }
        # When mismatch: prefer bootstrap (chain may follow wrong track for some builds)
        return $BootFile, "bootstrapped (chain mismatch)"
    }
    if ($ChainFile) { return $ChainFile, "chain" }
    return $BootFile, "bootstrapped"
}

function Get-StatusColor($Tag) {
    if ($Tag -match "verified") { return "Green" }
    if ($Tag -eq "chain") { return "Cyan" }
    return "Yellow"
}

function Update-NetfxSubdir($Label, $Subdir, $S4Term, $PrimaryTerm=$null) {
    $nDir = Join-Path $OutputDir $Subdir
    if (-not (Test-Path $nDir)) { New-Item $nDir -ItemType Directory -Force | Out-Null }
    $nPath = Join-Path $nDir "script_${Subdir}_${bn}_${ar}.meta4"
    $nFiles = Get-ExistingFiles $nPath
    $nNdp = $nFiles | Where-Object { $_.FileName -match 'ndp.*\.msu$' } | Sort-Object KB -Descending | Select-Object -First 1
    if ($nNdp -and $nNdp.KB -gt 0) {
        $cl = Follow-Chain -OldKb $nNdp.KB -ArchPat $ap -OsPref $c.OP
        $newNdp = Pick-File $cl "NET" $c.OP
        if ($newNdp -and $newNdp.KB -eq $nNdp.KB) { $newNdp = $null }
        if (-not $newNdp) {
            $s3term = if ($PrimaryTerm) { $PrimaryTerm } else { $c.S3 }
            $boot = Bootstrap-Search -Term $s3term -ArchPat $ap -OsPref $c.OP -Kind "NET"
            if ($S4Term) {
                $s3N = if ($boot -and $boot.FileName -match 'ndp(\d+)') { $matches[1] }
                $oN = if ($nNdp.FileName -match 'ndp(\d+)') { $matches[1] }
                if (-not $boot -or ($s3N -and $oN -and $s3N -ne $oN)) {
                    $boot = Bootstrap-Search -Term $S4Term -ArchPat $ap -OsPref $c.OP -Kind "NET"
                }
            }
            elseif (-not $boot -and $nNdp.KB -gt 0) { $boot = Bootstrap-Search -Term "kb$($nNdp.KB)" -ArchPat $ap -OsPref $c.OP -Kind "NET" }
            $bootBoot = Bootstrap-Search -Term ".NET Framework 4.8 $($c.L)" -ArchPat $ap -OsPref $c.OP -Kind "NET"
            if ($boot -and $boot.KB -eq $nNdp.KB) { $newNdp = $boot; $tag = "verified" }
            elseif ($boot) { $newNdp = $boot; $tag = "bootstrapped" }
        }
        if ($newNdp -and $newNdp.FileName -notmatch "^$($c.OP)") { $newNdp = $null }
        if ($newNdp) {
            $oN = if ($nNdp.FileName -match 'ndp(\d+)') { $matches[1] }
            $nN = if ($newNdp.FileName -match 'ndp(\d+)') { $matches[1] }
            if ($oN -and $nN -and $oN -ne $nN) { $newNdp = $null }
        }
        if ($newNdp -and $newNdp.KB -ne $nNdp.KB) {
            $baselines = $nFiles | Where-Object { $_.FileName -notmatch 'ndp.*\.msu$' }
            $newNdp = $newNdp | Select-Object *, @{N='Language';E={'neutral'}} -ExcludeProperty Language
            $nAll = @($newNdp) + $baselines
            if (-not $TestMode) {
                $oldSig = if (Test-Path $nPath) {
                    [xml]$x = Get-Content $nPath -Raw; $x.metalink.file | Sort-Object { if ($_.name -match "kb(\d+)") { [int]$matches[1] } else { 0 } } | ForEach-Object { $_.name } | Out-String
                }
                $newSig = $nAll | Sort-Object { if ($_.FileName -match "kb(\d+)") { [int]$matches[1] } else { 0 } } | ForEach-Object { $_.FileName } | Out-String
                if ($oldSig -ne $newSig) { (New-Meta4 $nAll) | Out-File $nPath -Encoding utf8 -NoNewline }
            }
            Write-Host "  [$Label] $($nNdp.KB) -> $($newNdp.KB) ($($newNdp.FileName))" -ForegroundColor Green
        } else {
            Write-Host "  [$Label] $($nNdp.KB) (unchanged)" -ForegroundColor DarkGray
        }
    } else {
        $s3term = if ($PrimaryTerm) { $PrimaryTerm } else { $c.S3 }
        $boot = Bootstrap-Search -Term $s3term -ArchPat $ap -OsPref $c.OP -Kind "NET"
        if (-not $boot -and $S4Term) { $boot = Bootstrap-Search -Term $S4Term -ArchPat $ap -OsPref $c.OP -Kind "NET" }
        if ($boot) {
            $bootArchOk = $false
            if ($boot.FileName -match 'arm64' -and $ar -match 'arm64') { $bootArchOk = $true }
            elseif ($boot.FileName -notmatch 'arm64|x64|x86') { $bootArchOk = $true }
            elseif ($boot.FileName -match 'x64' -and $ar -eq 'x64') { $bootArchOk = $true }
            elseif ($boot.FileName -match 'x86' -and $ar -eq 'x86') { $bootArchOk = $true }
            elseif ($boot.FileName -match $ar) { $bootArchOk = $true }
        }
        if ($boot -and $boot.FileName -match "^$($c.OP)" -and $bootArchOk) {
            $boot = $boot | Select-Object *, @{N='Language';E={'neutral'}} -ExcludeProperty Language
            $nAll = @($boot) + ($nFiles | Where-Object { $_.FileName -notmatch 'ndp.*\.msu$' })
            if (-not $TestMode) {
                $oldSig = if (Test-Path $nPath) {
                    [xml]$x = Get-Content $nPath -Raw; $x.metalink.file | Sort-Object { if ($_.name -match "kb(\d+)") { [int]$matches[1] } else { 0 } } | ForEach-Object { $_.name } | Out-String
                }
                $newSig = $nAll | Sort-Object { if ($_.FileName -match "kb(\d+)") { [int]$matches[1] } else { 0 } } | ForEach-Object { $_.FileName } | Out-String
                if ($oldSig -ne $newSig) { (New-Meta4 $nAll) | Out-File $nPath -Encoding utf8 -NoNewline }
            }
            Write-Host "  [$Label] (new) $($boot.FileName)" -ForegroundColor Yellow
        } else {
            Write-Host "  [$Label] (not found)" -ForegroundColor DarkGray
        }
    }
}

# Re-add entries the old meta4 had but the rebuilt list lost, for runs where the chain lookup
# degraded and a baseline checkpoint could have been mistaken for a superseded LCU. The next
# healthy run re-evaluates them and drops them again.
function Add-UnverifiedEntries($All, $OldPath) {
    if (-not (Test-Path $OldPath)) { return $All }
    $haveNames = @($All | ForEach-Object { $_.FileName })
    $haveUrls = @($All | ForEach-Object { $_.Url })
    # Assign first: Get-ExistingFiles returns ,(...) and feeding that straight into a pipeline hands
    # the whole array to Where-Object as one item, which turns $_.FileName into an array and breaks
    # the comparison below (the same trap applies to any ,(...) helper used as a pipeline source).
    $oldEntries = Get-ExistingFiles $OldPath
    $unverified = @($oldEntries | Where-Object { $_.FileName -notin $haveNames -and $_.Url -notin $haveUrls })
    if ($unverified.Count -eq 0) { return $All }
    Write-Host "  [MSUs] chain degraded: kept $($unverified.Count) entry(ies) that could not be re-verified" -ForegroundColor Yellow
    return ,(@($All) + $unverified)
}

# --- README build version (three-tier lookup) ---
# Tier 1: Update Catalog titles carry "(<base>.<rev>)" for the branches MS labels that way
# Tier 2: support.microsoft.com KB article title, looked up by the KB number we just resolved
# Tier 3: read Package_for_RollupFix version straight out of the LCU msu (slow: full download)
$BUILD_DISP = @{
    "14393"        = @{ Disp = "14393"; Pat = "14393" }
    "17763"        = @{ Disp = "17763"; Pat = "17763" }
    "19041"        = @{ Disp = "1904x"; Pat = "1904\d" }
    "20348"        = @{ Disp = "20348"; Pat = "20348" }
    "22621"        = @{ Disp = "22631"; Pat = "22631" }
    "26100"        = @{ Disp = "26200"; Pat = "26200" }
    "26100-server" = @{ Disp = "26100"; Pat = "26100" }
    "28000"        = @{ Disp = "28000"; Pat = "28000" }
}
$lcuAttempted = @{}      # KB -> the LCU probe already ran (a failed download must not run twice)
# 7-Zip handles every cab compression MS uses; expand.exe is the fallback
$sevenZip = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1

function Fetch-Html($Url, $Tries = 3) {
    $i = 0
    while ($i -lt $Tries) {
        try { return (Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 20).Content }
        catch { $i++; if ($i -lt $Tries) { Start-Sleep -Milliseconds 1500 } }
    }
    return $null
}

function Add-BuildEntries($Map, $Pairs, $Src) {
    foreach ($p in $Pairs) {
        if (-not $Map.ContainsKey($p.Base)) {
            $Map[$p.Base] = [PSCustomObject]@{ Base = $p.Base; Rev = $p.Rev; Src = $Src }
        }
    }
}

function Get-MapBuild($Map, $Pat) {
    $re = [regex]("^(" + $Pat + ")$")
    foreach ($k in $Map.Keys) { if ($re.IsMatch($k)) { return $Map[$k] } }
    return $null
}

function Add-CatalogBuilds($Map, $Kb) {
    try {
        foreach ($h in (Search-Catalog "kb$Kb")) {
            if ($h.Title -notmatch 'Cumulative Update' -or $h.Title -match '\.NET') { continue }
            $pairs = @()
            foreach ($m in $reBuildSuffix.Matches($h.Title)) {
                $pairs += [PSCustomObject]@{ Base = $m.Groups[1].Value; Rev = $m.Groups[2].Value }
            }
            Add-BuildEntries $Map $pairs "catalog"
        }
    } catch { }
}

function Add-SupportBuilds($Map, $Kb) {
    $html = Fetch-Html "https://support.microsoft.com/en-us/help/$Kb"
    if (-not $html) { Write-Host "  [BUILD] KB$Kb : support page unreachable" -ForegroundColor DarkGray; return }
    $t = [regex]::Match($html, '<title>(.*?)</title>', 'Singleline').Groups[1].Value
    $pairs = @()
    foreach ($m in $reOsBuild.Matches($t)) {
        foreach ($b in ($m.Groups[1].Value -split '\s+and\s+')) {
            $v = $b.Trim().Split('.')
            if ($v.Count -eq 2) { $pairs += [PSCustomObject]@{ Base = $v[0]; Rev = $v[1] } }
        }
    }
    if ($pairs.Count -eq 0) { Write-Host "  [BUILD] KB$Kb : support page has no OS Build yet" -ForegroundColor DarkGray }
    Add-BuildEntries $Map $pairs "support"
}

function Expand-Pack($File, $Dir, [string]$Filter = "") {
    if (-not (Test-Path $Dir)) { New-Item $Dir -ItemType Directory -Force | Out-Null }
    if ($sevenZip) {
        if ($Filter) { & $sevenZip e -y "-o$Dir" $File $Filter -r | Out-Null }   # flat, wanted files only
        else { & $sevenZip x -y "-o$Dir" $File | Out-Null }                      # full tree, keeps the inner cab
    } elseif ($Filter) { & "$env:SystemRoot\System32\expand.exe" "-F:$Filter" $File $Dir | Out-Null }
    else { & "$env:SystemRoot\System32\expand.exe" -F:* $File $Dir | Out-Null }
}

function Add-LcuBuild($Map, $Kb, $Url) {
    if ($lcuAttempted.ContainsKey($Kb)) { return }
    $lcuAttempted[$Kb] = 1
    if (-not $Url) { return }
    $sz = ""
    try {
        $h = Invoke-WebRequest $Url -Method Head -UseBasicParsing -TimeoutSec 30
        $sz = " ($([math]::Round([double]$h.Headers['Content-Length'] / 1MB)) MB)"
    } catch { }
    Write-Host "  [BUILD] KB$Kb : no build in catalog/support, reading it out of the LCU msu$sz" -ForegroundColor Yellow
    $root = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
    $tmp = Join-Path $root "lcu_build_$Kb"
    try {
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item $tmp -ItemType Directory -Force | Out-Null
        $msu = Join-Path $tmp "lcu.msu"
        Invoke-WebRequest $Url -OutFile $msu -UseBasicParsing -TimeoutSec 3600
        Expand-Pack $msu (Join-Path $tmp "msu")
        Remove-Item $msu -Force -ErrorAction SilentlyContinue
        $msuDir = Join-Path $tmp "msu"
        $cab = Get-ChildItem $msuDir -Filter *.cab -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cab) { Write-Host "  [BUILD] KB$Kb : no cab inside the msu" -ForegroundColor Yellow; return }
        $out = Join-Path $tmp "mum"
        Expand-Pack $cab.FullName $out "*.mum"
        $pairs = @()
        foreach ($mum in (Get-ChildItem $out -Filter *.mum -Recurse -ErrorAction SilentlyContinue)) {
            $txt = Get-Content $mum.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $txt) { continue }
            foreach ($m in $reAssemblyId.Matches($txt)) {
                if ($m.Value -match 'Package_for_RollupFix' -and $m.Value -match 'version="(\d+)\.(\d+)') {
                    $pairs += [PSCustomObject]@{ Base = $matches[1]; Rev = $matches[2] }
                }
            }
        }
        if ($pairs.Count -eq 0) { Write-Host "  [BUILD] KB$Kb : no Package_for_RollupFix version in the msu" -ForegroundColor Yellow; return }
        Add-BuildEntries $Map $pairs "lcu"
        Write-Host "  [BUILD] KB$Kb : LCU says $($pairs[0].Base).$($pairs[0].Rev)" -ForegroundColor Green
    } catch {
        Write-Host "  [BUILD] KB$Kb : LCU probe failed: $_" -ForegroundColor Yellow
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-BuildVersions($Bn, $Kb, $MsuUrl) {
    $d = $BUILD_DISP[$Bn]
    if (-not $d -or $BUILD_VERSIONS.ContainsKey($d.Disp)) { return }   # first arch wins, the value is arch independent
    $map = @{}
    Add-CatalogBuilds $map $Kb
    $hit = Get-MapBuild $map $d.Pat
    if (-not $hit) { Add-SupportBuilds $map $Kb; $hit = Get-MapBuild $map $d.Pat }
    if (-not $hit) { Add-LcuBuild $map $Kb $MsuUrl; $hit = Get-MapBuild $map $d.Pat }
    if (-not $hit) {
        Write-Host "  [BUILD] $Bn : build version unresolved (catalog + support + LCU all missed)" -ForegroundColor Red
        return
    }
    $BUILD_VERSIONS[$d.Disp] = "Build $($d.Disp).$($hit.Rev)"
    Write-Host "  [BUILD] $Bn -> Build $($d.Disp).$($hit.Rev) [$($hit.Src)]" -ForegroundColor Green
    # 26H2 is an enablement package on the 25H2 servicing branch: the same LCU lists it explicitly,
    # otherwise its revision tracks 26200 (no separate history page).
    if ($Bn -eq "26100") {
        $r26 = Get-MapBuild $map "26300"
        $rev = if ($r26) { $r26.Rev } else { $hit.Rev }
        $BUILD_VERSIONS["26300"] = "Build 26300.$rev"
        Write-Host "  [BUILD] 26300 -> Build 26300.$rev [$(if ($r26) { $r26.Src } else { 'tracks 26200' })]" -ForegroundColor Green
    }
}

function Get-OldMsus($Path) {
    if (-not (Test-Path $Path)) { return @() }
    try {
        $x = [xml](Get-Content $Path -Raw)
        return ,($x.metalink.file | Where-Object { $_.name -match '\.msu$' -and $_.name -notmatch 'ndp' } | ForEach-Object {
            $kb = 0; if ($_.name -match 'kb(\d+)') { $kb = [int]$matches[1] }
            [PSCustomObject]@{FileName = $_.name; Url = $_.url; Sha1 = $_.hash.'#text'; KB = $kb}
        })
    } catch { return @() }
}

# Get all entries from an existing meta4 file (full content preservation)
function Get-ExistingFiles($Path) {
    if (-not (Test-Path $Path)) { return @() }
    try {
        $x = [xml](Get-Content $Path -Raw)
        return ,($x.metalink.file | ForEach-Object {
            $kb = 0; if ($_.name -match 'kb(\d+)') { $kb = [int]$matches[1] }
            $sha = if ($_.hash) { $_.hash.'#text' } else { "" }
            $lang = if ($_.language) { $_.language } else { "" }
            [PSCustomObject]@{FileName = $_.name; Url = $_.url; Sha1 = $sha; KB = $kb; Language = $lang}
        })
    } catch { return @() }
}

function Get-CabLabel($File, $ArchPat) {
    switch (Get-CabType $File $ArchPat) { 1 { "CAB_SETUP" } 2 { "CAB_SAFEOS" } default { "CAB" } }
}

$cabTypeCache = @{}
function Get-CabType($File, $ArchPat) {
    $kb = $File.KB
    if (-not $kb) { return 3 }
    if ($cabTypeCache.ContainsKey($kb)) { return $cabTypeCache[$kb] }
    try {
        $sr = Search-Catalog "kb$kb"
        $sb = $sr | Where-Object { $_.Title -match $ArchPat } | Select-Object -First 1
        if ($sb) {
            $title = $sb.Title
            if ($title -match "Setup Dynamic Update") { $cabTypeCache[$kb] = 1; return 1 }
            if ($title -match "Safe OS") { $cabTypeCache[$kb] = 2; return 2 }
            $ssv = Retry-WebRequest -Url "https://www.catalog.update.microsoft.com/v7/site/ScopedViewInline.aspx?updateid=$($sb.Guid)"
            $ssh = $ssv.Content
            if ($ssh -match "SetupUpdate:|setup binaries") { $cabTypeCache[$kb] = 1; return 1 }
            if ($ssh -match "Safe OS") { $cabTypeCache[$kb] = 2; return 2 }
            $cabTypeCache[$kb] = 3; return 3
        }
    } catch { }
    $cabTypeCache[$kb] = 3; return 3
}
Write-Host "=== Win_ISO_Patching_Scripts - meta4 Auto-Gen ===" -ForegroundColor Cyan

trap {
    Write-Host "  === Catalog request failed after retries; run incomplete ===" -ForegroundColor Yellow
    Write-Host "  Restore previous meta4 files with: git -C `"$ScriptRoot`" checkout -- Scripts/" -ForegroundColor Yellow
    exit 127
}

if ($Build.Count -eq 1 -and $Build[0] -match ',') { $Build = $Build[0] -split ',' | ForEach-Object { $_.Trim() } }
if ($Arch.Count -eq 1 -and $Arch[0] -match ',') { $Arch = $Arch[0] -split ',' | ForEach-Object { $_.Trim() } }
if ($Build.Count -eq 0) { $Build = $CFG.Keys | Sort-Object }
if ($Arch.Count -eq 0) { $Arch = @("x64", "x86", "arm64") }
$gen = 0; $skip = 0; $BUILD_VERSIONS = @{}

foreach ($bn in $Build) {
    $c = $CFG[$bn]; if (-not $c) { continue }
    $isServer = [bool]$c.SRV
    $baseBn = $bn -replace '-server$'
    foreach ($ar in $Arch) {
        $al = $ARCH_LABEL[$ar]
        $ap = "for $ar" + $(if ($ar -eq "arm64") { "" } else { "[^a-z]" })
        if (-not $al) { continue }
        if ($bn -eq "28000" -and $ar -eq "x86") { continue }
        $old = Join-Path $OutputDir "script_$(if ($isServer) {'server_'})$baseBn`_$ar.meta4"
        $newFiles = @()
        Write-Host "--- [$bn/$ar] $($c.L) ---" -ForegroundColor Yellow
        # old MSUs preserved by MSU retention below

        # 1. LCU
        try {
            # Always run chain + bootstrap from Catalog (history may be stale)
            $chain = $null; $boot = $null
            # Assume the chain is unusable until Follow-Chain resolves one: a missing or failed
            # lookup leaves the sweep without the baseline info it needs.
            $chainDegraded = $true
            $okb = Get-OldKB $old "LCU" $ap
            if ($okb) {
                $cl = Follow-Chain -OldKb $okb -ArchPat $ap -OsPref $c.OP -Server:$isServer
                $chain = Pick-File $cl "LCU" $c.OP
                $newFiles += $cl | Where-Object { $_.FileName -match '\.msu$' }
            }
            $boot = Bootstrap-Search -Term $c.S1 -ArchPat $ap -OsPref $c.OP -Kind "LCU"
            $f, $tag = Cross-Validate $chain $boot
            $lcuFile = $f
            if ($f) {
                $newFiles += $f
                if ($okb -and $okb -ne $f.KB) { Write-Host "  [LCU] $okb -> $($f.KB) ($($f.FileName))" -ForegroundColor Green }
                elseif ($okb) { Write-Host "  [LCU] $okb (unchanged)" -ForegroundColor DarkGray }
                else { Write-Host "  $($f.FileName) ($tag)" -ForegroundColor $(Get-StatusColor $tag) }
            }
            else { Write-Host "  [LCU] SKIP"; $skip++; continue }

            # README build version - resolved from the LCU we just picked
            Resolve-BuildVersions $bn $f.KB $f.Url
        } catch { Write-Host "  [LCU] ERROR: $_"; $skip++; continue }
        $lcuChainDegraded = $chainDegraded

        # SSU (14393 only) - Find newest SSU, replace old one after MSU preservation
        if ($bn -eq "14393") {
            Start-Sleep -Milliseconds 600
            $ssuOldKb = $null; $ssuNewFile = $null
            # Find old SSU KB from old meta4 (exclude LCU, match via catalog search)
            if (Test-Path $old) {
                $ssuR = Search-Catalog "Servicing Stack Update for Windows 10 Version 1607 for $ar-based Systems"
                $ssuFiltered = $ssuR | Where-Object { $_.Title -match "Servicing Stack" -and $_.Title -match "for $ar[^a-z]" -and $_.Title -match "Version 1607" }
                $ssuOldMsus = Get-OldMsus $old
                $ssuOldLcuKb = Get-OldKB $old "LCU" $ap
                foreach ($ssuOldResult in $ssuFiltered) {
                    if ($ssuOldResult.Title -match 'KB(\d+)') {
                        $ssuOldKbCandidate = [int]$matches[1]
                        if ($ssuOldKbCandidate -ne $ssuOldLcuKb -and ($ssuOldMsus.KB -contains $ssuOldKbCandidate)) {
                            $ssuOldKb = $ssuOldKbCandidate; break
                        }
                    }
                }
                # Fallback: search each old MSU individually to find SSU
                if (-not $ssuOldKb) {
                    foreach ($om in $ssuOldMsus | Sort-Object KB -Descending) {
                        if ($om.KB -eq $ssuOldLcuKb -or $om.KB -eq 0) { continue }
                        try {
                            $ssuR = Search-Catalog "kb$($om.KB)"
                            $title = ($ssuR | Where-Object { $_.Title -match "Servicing Stack" -and $_.Title -match "for $ar[^a-z]" -and $_.Title -match "Version 1607" } | Select-Object -First 1).Title
                            if ($title) { $ssuOldKb = $om.KB; break }
                        } catch { continue }
                    }
                }
            }
            if ($ssuOldKb) {
                $ssuChain = Follow-Chain -OldKb $ssuOldKb -ArchPat $ap -OsPref $c.OP
                $ssuNewFile = Pick-File $ssuChain "SSU" $c.OP
            }
            if ($ssuNewFile) {
                $ssuFile = $ssuNewFile
            }
        } else { Write-Host "  SSU: bundled" -ForegroundColor DarkGray }

        Start-Sleep -Milliseconds 600

        if ($newFiles -isnot [array]) { $newFiles = @($newFiles) }
        # 2. .NET
        Write-Host "  .NET..." -NoNewline
        try {
            $chain = $null; $boot = $null
            $okb = Get-OldKB $old "NET"
            if ($okb) { $cl = Follow-Chain -OldKb $okb -ArchPat $ap -OsPref $c.OP; $chain = Pick-File $cl "NET" $c.OP }
            $s3term = $c.S3
            if (-not $s3term -and $c.S4) { $s3term = $c.S4 }
            $boot = Bootstrap-Search -Term $s3term -ArchPat $ap -OsPref $c.OP -Kind "NET"
            $f, $tag = Cross-Validate $chain $boot
            # For builds with netfx subdirs (14393/17763/19041/20348), .NET goes to subdir, not main meta4
            if ($f -and $bn -in @("14393","17763","19041","20348")) { $f = $null; $tag = "in netfx subdir" }
            # Verify OS prefix (windows10.0 rejects windows11.0) — only for non-subdir builds
            if ($f -and $f.FileName -notmatch "^$($c.OP)") { $f = $null; $tag = "SKIP (OS mismatch)" }
            if ($f) { $newFiles += $f; Write-Host " $($f.FileName) ($tag)" -ForegroundColor $(Get-StatusColor $tag) }
            elseif ($okb) {
                # Assign first: Get-ExistingFiles returns ,(...) and a pipeline would hand the whole
                # array to Where-Object as one item, so the filter below would never isolate a file.
                $oldMetaEntries = Get-ExistingFiles $old
                $oldNetMsu = $oldMetaEntries | Where-Object { $_.FileName -match 'ndp.*\.msu$' } | Select-Object -First 1
                if ($oldNetMsu) { $newFiles += $oldNetMsu; Write-Host " $($oldNetMsu.FileName) (kept)" -ForegroundColor Yellow }
                else { Write-Host " not found" -ForegroundColor DarkGray }
            }
            else { Write-Host " $tag" -ForegroundColor DarkGray }
        } catch { Write-Host " ERROR: $_" -ForegroundColor Red }

        $fnet = $f  # Save .NET result for sorting
        if ($newFiles -isnot [array]) { $newFiles = @($newFiles) }

        # 3. Preserve old MSUs (keep previous LCU/component MSUs)
        # Upstream keeps multiple MSUs across releases (old LCU + new LCU + extras)
        if (Test-Path $old) {
            $oldMsus = Get-OldMsus $old
            $newKbs = @($newFiles | Where-Object { $_.KB -gt 0 } | ForEach-Object { $_.KB })
            # Collect MSU names from the new LCU's chain for baseline detection
            $chainMsuNames = if ($cl) {
                @($cl | Where-Object { $_.FileName -match '\.msu$' -and $_.FileName -notmatch 'ndp' } | ForEach-Object { $_.FileName })
            } else { @() }

            # Exclude old LCUs when superseded, but preserve baseline/checkpoint CUs
            # (e.g. KB5043080 for 26100, which the catalog bundles with the latest).
            # Also sweep for stale LCUs left behind by previous transient failures —
            # Get-OldKB only returns the highest-KB match, so a lower-KB LCU that
            # was missed once becomes invisible and gets preserved as a regular MSU.
            $oldLcuKb = Get-OldKB $old "LCU" $ap
            $lcuKbsToExclude = @()
            if ($oldLcuKb -and $lcuFile -and $oldLcuKb -ne $lcuFile.KB) {
                $isBaseline = $false
                if ($cl -and $chainMsuNames.Count -gt 1) {
                    $oldLcuName = ($oldMsus | Where-Object { $_.KB -eq $oldLcuKb } | Select-Object -First 1).FileName
                    if ($oldLcuName -and ($oldLcuName -in $chainMsuNames)) { $isBaseline = $true }
                }
                if (-not $isBaseline) { $lcuKbsToExclude += $oldLcuKb }
            }
            # Sweep: classify old MSUs by catalog title and exclude any superseded by a
            # newer update of the same type already in $newFiles. Covers LCU, Safe OS DU,
            # Setup DU, and .NET. Enablement KBs (no catalog results) are preserved.
            # Also catches stale entries left behind by previous transient failures —
            # Get-OldKB only returns the highest-KB per kind, so lower-KB duplicates
            # become invisible and would otherwise be preserved as regular MSUs.
            if ($lcuFile) {
                # Classify new MSUs by type for replacement comparison (cached per KB)
                $newMsuTypes = @{}
                foreach ($nf in $newFiles | Where-Object { $_.FileName -match '\.msu$' -and $_.KB -gt 0 }) {
                    if ($newMsuTypes.ContainsKey($nf.KB)) { continue }
                    try {
                        $r = Search-Catalog "kb$($nf.KB)"
                        $t = ($r | Where-Object { $_.Title -match $ap } | Select-Object -First 1).Title
                        if (-not $t) { continue }
                        $ntype = if ($t -match 'Cumulative Update' -and $t -notmatch '\.NET') { 'LCU' }
                                 elseif ($t -match 'Safe OS') { 'SafeOS' }
                                 elseif ($t -match 'Setup Dynamic Update') { 'SetupDU' }
                                 elseif ($t -match '\.NET Framework') { 'NET' }
                                 else { 'Other' }
                        if ($ntype -ne 'Other') { $newMsuTypes[$nf.KB] = $ntype }
                    } catch { }
                }
                # Scan remaining old MSUs against new-type map
                foreach ($om in $oldMsus) {
                    $ckb = $om.KB
                    if ($ckb -le 0 -or $ckb -in $newKbs -or $ckb -eq $lcuFile.KB -or $ckb -in $lcuKbsToExclude) { continue }
                    try {
                        $r = Search-Catalog "kb$ckb"
                        $t = ($r | Where-Object { $_.Title -match $ap } | Select-Object -First 1).Title
                        if (-not $t) { continue }  # expired KB — preserve
                        $otype = if ($t -match 'Cumulative Update' -and $t -notmatch '\.NET') { 'LCU' }
                                 elseif ($t -match 'Safe OS') { 'SafeOS' }
                                 elseif ($t -match 'Setup Dynamic Update') { 'SetupDU' }
                                 elseif ($t -match '\.NET') { 'NET' }
                                 else { 'Other' }
                        if ($otype -eq 'Other') { continue }
                        # Check if a new MSU of the same type exists with a different KB
                        $hasReplacement = ($newMsuTypes.GetEnumerator() | Where-Object { $_.Value -eq $otype -and $_.Key -ne $ckb }).Count -gt 0
                        if ($hasReplacement) {
                            $isBaseline = ($chainMsuNames.Count -gt 1 -and ($om.FileName -in $chainMsuNames))
                            if (-not $isBaseline) { $lcuKbsToExclude += $ckb }
                        }
                    } catch { }
                }
            }
            foreach ($exKb in $lcuKbsToExclude) {
                if ($exKb -notin $newKbs) { $newKbs += $exKb }
            }
            $preserved = @()
            foreach ($om in $oldMsus) {
                if ($om.KB -gt 0 -and $om.KB -in $newKbs) { continue }  # skip if we already have this KB
                if ($om.Url -in $newFiles.Url) { continue }
                $preserved += $om
            }
            if ($preserved.Count -gt 0) {
                $newFiles += $preserved
                Write-Host "  [MSUs] kept $($preserved.Count) old MSU(s)" -ForegroundColor DarkGray
            }
        }

        # Replace old SSU with new one if found (14393)
        # NOTE: $ssuFile MUST be set even when $ssuNewFile already exists in $newFiles,
        # otherwise sorting cannot place SSU at position 1 (ssuUrl will be empty).
        if ($bn -eq "14393" -and $ssuNewFile) {
            if ($ssuNewFile.Url -notin $newFiles.Url) {
                # If hash matches old SSU, keep old URL (avoids CDN switch causing churn)
                $oldSsu = $newFiles | Where-Object { $null -eq $ssuOldKb -or $_.KB -eq $ssuOldKb } | Select-Object -First 1
                if ($oldSsu -and $oldSsu.Sha1 -eq $ssuNewFile.Sha1) {
                    $ssuNewFile.Url = $oldSsu.Url
                    Write-Host "  [SSU] $($ssuNewFile.KB) (hash match, kept old URL)" -ForegroundColor DarkGray
                } else {
                    $newFiles = @($newFiles | Where-Object { $null -eq $ssuOldKb -or $_.KB -ne $ssuOldKb })
                    $newFiles += $ssuNewFile
                    Write-Host "  [SSU] $ssuOldKb -> $($ssuNewFile.KB) ($($ssuNewFile.FileName))" -ForegroundColor Green
                }
            } else {
                Write-Host "  [SSU] $($ssuNewFile.KB) (unchanged)" -ForegroundColor DarkGray
            }
            $ssuFile = $ssuNewFile
        }

        # Fallback: if chain didn't find new SSU, identify old SSU from preserved MSUs
        if (-not $ssuFile -and $ssuOldKb) {
            $ssuFile = $newFiles | Where-Object { $_.KB -eq $ssuOldKb } | Select-Object -First 1
        }

        # Last resort: catalog unreachable, infer SSU from old meta4 (first MSU is always SSU)
        if (-not $ssuFile -and $bn -eq "14393" -and (Test-Path $old)) {
            $oldMeta4Ssus = Get-OldMsus $old
            if ($oldMeta4Ssus.Count -gt 0) {
                $ssuFile = $newFiles | Where-Object { $_.Url -eq $oldMeta4Ssus[0].Url } | Select-Object -First 1
            }
        }

        # 4. Netfx subdir meta4 files
        if ($bn -in @("14393","17763","19041","20348")) {
            Update-NetfxSubdir -Label "netfx4.8" -Subdir "netfx4.8" -S4Term $c.S4
        }

        # netfx4.8.1 subdir: only 19041/20348 x64/x86 (arm64 has 4.8 only, no 4.8.1)
        if ($bn -in @("19041","20348") -and $ar -ne "arm64") {
            Update-NetfxSubdir -Label "netfx4.8.1" -Subdir "netfx4.8.1" -S4Term $null -PrimaryTerm $c.S4
        }

        # 5. CABs via chain
        $oldCabs = Get-Cabs $old
        foreach ($oc in $oldCabs) {
            $oldKb = Get-KB $oc
            if ($oldKb) {
                $links = Follow-Chain -OldKb $oldKb -ArchPat $ap -OsPref $c.OP -Server:$isServer
                $cab = $links | Where-Object { $_.FileName -match '\.cab$' } | Select-Object -First 1
                if ($cab -and $cab.FileName -ne $oc.FileName -and ($cab.Url -notin $newFiles.Url)) {
                    $cabType = Get-CabLabel $cab $ap
                    $newFiles += $cab; Write-Host "  [$cabType] $oldKb -> $($cab.KB) ($($cab.FileName))" -ForegroundColor Green
                } elseif ($oc.Url -notin ($newFiles | ForEach-Object { $_.Url })) {
                    $cabType = Get-CabLabel $oc $ap
                    $oc2 = [PSCustomObject]@{FileName=$oc.FileName; Url=$oc.url; Sha1=$oc.Sha1; KB=$oc.KB}
                    $newFiles += $oc2; Write-Host "  [$cabType] $oldKb (unchanged)" -ForegroundColor DarkGray
                }
            } elseif ($oc.Url -notin ($newFiles | ForEach-Object { $_.Url })) {
                $oc2 = [PSCustomObject]@{FileName=$oc.FileName; Url=$oc.url; Sha1=$oc.Sha1; KB=$oc.KB}
                $newFiles += $oc2
            }
            Start-Sleep -Milliseconds 400
        }

        $all = @($newFiles) | Sort-Object Url -Unique

        # A degraded chain (Follow-Chain fell back to the update's own file list) cannot tell a
        # baseline checkpoint from a superseded LCU, so the sweep may have dropped one.
        if ($lcuChainDegraded) { $all = Add-UnverifiedEntries $all $old }
        if ($TestMode) { Write-Host "  [TEST] $($all.Count) entries"; $gen++; continue }

        # Sort: all files by KB ascending
        $sortedAll = $all | Sort-Object @{Expression={if ($_.KB -gt 0) { [int]$_.KB } else { 0 }}}

        # Only write if file name list changed (avoids false date bumps)
        $oldSig = if (Test-Path $old) {
            $x = [xml](Get-Content $old -Raw)
            $x.metalink.file | Sort-Object { if ($_.name -match 'kb(\d+)') { [int]$matches[1] } else { 0 } } | ForEach-Object { $_.name } | Out-String
        }
        $newSig = $sortedAll | Sort-Object { if ($_.FileName -match 'kb(\d+)') { [int]$matches[1] } else { 0 } } | ForEach-Object { $_.FileName } | Out-String
        if ($oldSig -and $oldSig -eq $newSig) {
            Write-Host "  [OK] $($c.L) $ar (unchanged)" -ForegroundColor DarkGray; $gen++
            continue
        }

        $newMeta = New-Meta4 $sortedAll
        $newMetaStr = $newMeta.ToString()
        [System.IO.File]::WriteAllText($old, $newMetaStr, [System.Text.Encoding]::UTF8)
        Write-Host "  [OK] $($c.L) $ar ($($all.Count) files)" -ForegroundColor Green; $gen++
    }
}
# Update README date and build versions
# Build numbers are re-checked on every run (a release-day run can miss them when MS lags), so a
# value missed once is repaired on the next run. The date only moves when the README content changes.
# Check whether any Scripts/ meta4 file differs from committed state
$metaChanged = $false
try {
    $gitDiff = git diff --name-only -- Scripts/
    if ($LASTEXITCODE -eq 0 -and $gitDiff) { $metaChanged = $true }
} catch {
    # If git fails (e.g. not a repo, running outside CI), default to updating
    $metaChanged = $true
}
$culture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
$d = Get-Date
$today = $culture.DateTimeFormat.GetMonthName($d.Month) + ' ' + $d.ToString('d, yyyy')
$todayCn = "$($d.Year)$([char]0x5E74)$($d.Month)$([char]0x6708)$($d.Day)$([char]0x65E5)"
$cnLabel = "$([char]0x6700)$([char]0x540E)$([char]0x66F4)$([char]0x65B0)$([char]0xFF1A)"
$cnY = [char]0x5E74; $cnM = [char]0x6708; $cnD = [char]0x65E5
$buildsStale = $false
foreach ($readme in @("README.md", "README_cn.md")) {
    $path = Join-Path $ScriptRoot $readme
    if (-not (Test-Path $path)) { continue }
    $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $orig = $content
    # Update build versions from the resolved values
    foreach ($key in $BUILD_VERSIONS.Keys) {
        $content = $content -replace "Build $key.\d+", $BUILD_VERSIONS[$key]
    }
    if ($content -ne $orig) { $buildsStale = $true }
    # Update date with regex (don't hardcode old date)
    $content = $content -replace 'Last Updated: \w+ \d+, \d{4}', "Last Updated: $today"
    $content = $content -replace "$cnLabel\d+$cnY\d+$cnM\d+$cnD", "$cnLabel$todayCn"
    if ($content -eq $orig) { continue }
    if (-not $TestMode) { [System.IO.File]::WriteAllText($path, $content, [System.Text.Encoding]::UTF8) }
    Write-Host "  [README] $(if ($TestMode) { 'would update' } else { 'updated' }): $readme" -ForegroundColor Green
}
if ($buildsStale) { Write-Host "  [README] build versions refreshed from a stale value" -ForegroundColor Yellow }
elseif ($metaChanged) { Write-Host "  [README] date updated to $today" -ForegroundColor Green }
else { Write-Host "  [README] no meta4 changes, build versions already current" -ForegroundColor DarkGray }

Write-Host "=== Done: $gen generated, $skip skipped ===" -ForegroundColor Cyan

# Update-Meta4.ps1
# Generates .meta4 files via MS Update History pages (primary) + KB supersedence chain + version name cross-validation.
[CmdletBinding()]
param([string[]]$Build = @(), [string[]]$Arch = @(), [string]$OutputDir = "", [switch]$TestMode)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutputDir) { $OutputDir = Join-Path $ScriptRoot "Scripts" }
if (-not (Test-Path $OutputDir)) { New-Item $OutputDir -ItemType Directory -Force | Out-Null }

$CFG = @{
    "14393" = @{OP="windows10.0";L="LTSB 2016";        S1="Cumulative Update for Windows 10 Version 1607";          S3=".NET Framework 4.8 Windows 10 1607"}
    "17763" = @{OP="windows10.0";L="LTSC 2019";        S1="Cumulative Update for Windows 10 Version 1809";          S3=".NET Framework 4.8 Windows 10 1809"}
    "19041" = @{OP="windows10.0";L="22H2 / LTSC 2021"; S1="Cumulative Update for Windows 10 Version 22H2";         S3=".NET Framework 4.8.1 Windows 10 22H2";S4=".NET Framework 4.8 Windows 10 22H2"}
    "20348" = @{OP="windows10.0";L="Server 2022";      S1="Cumulative Update for Microsoft server operating system version 21H2";S3="Cumulative Update for .NET Framework 3.5 and 4.8.1 Microsoft server operating system version 21H2";S4=".NET Framework 4.8 Microsoft server operating system version 21H2"}
    "22621" = @{OP="windows11.0";L="Win 11 23H2";      S1="Cumulative Update for Windows 11 Version 23H2";         S3=".NET Framework 4.8.1 Windows 11 23H2"}
    "26100" = @{OP="windows11.0";L="24H2 / Server 2025";S1="Cumulative Update for Windows 11 Version 24H2";        S3=".NET Framework 3.5 and 4.8.1 Microsoft server operating system version 24H2"}
    "28000" = @{OP="windows11.0";L="26H1";             S1="Cumulative Update for Windows 11 Version 26H1";        S3=".NET Framework 4.8.1 Windows 11 26H1"}
}
$ARCH_LABEL = @{x64="for x64-based Systems"; x86="for x86-based Systems"; arm64="for Arm64-based Systems"}

# MS Update History pages — canonical source for latest LCU KB + OS Build number
$UPDATE_HISTORY = @{
    "14393" = "windows-10-and-windows-server-2016-update-history-4acfbc84-a290-1b54-536a-1c0430e9f3fd"
    "17763" = "windows-10-and-windows-server-2019-update-history-725fc2e1-4443-6831-a5ca-51ff5cbcb059"
    "19041" = "windows-10-update-history-8127c2c6-6edf-4fdf-8b9f-0f7be1ef3562"
    "20348" = "windows-server-2022-update-history-e1caa597-00c5-4ab9-9f3e-8212fe80b2ee"
    "22621" = "windows-11-version-23h2-update-history-59875222-b990-4bd9-932f-91a5954de434"
    "26100" = "windows-11-version-24h2-update-history-0929c747-1815-4543-8461-0160d16f15e5"
    "28000" = "windows-11-version-26h1-update-history-253c73cd-cab1-4bfd-94dc-76c452273fc9"
}
$UPDATE_HISTORY_SERVER = @{
    "26100" = "windows-server-2025-update-history-10f58da7-e57b-4a9d-9c16-9f1dcd72d7d7"
}

function Search-Catalog { param($Q)
    try { $r = Invoke-WebRequest ("https://www.catalog.update.microsoft.com/v7/site/Search.aspx?q=" + [uri]::EscapeDataString($Q)) -UseBasicParsing -TimeoutSec 30
    } catch { return @() }
    $h = $r.Content; $ret = @(); $re = [regex]"id='([a-f0-9\-]{36})_link'"
    foreach ($m in $re.Matches($h)) {
        $g = $m.Groups[1].Value; $e = $h.IndexOf("</a>", $m.Index + $m.Length)
        if ($e -le 0) { continue }
        $r2 = $h.Substring($m.Index + $m.Length, $e - $m.Index - $m.Length)
        $gt = $r2.IndexOf('>'); if ($gt -ge 0) { $r2 = $r2.Substring($gt + 1) }
        $t = ($r2 -replace '<[^>]+>', '').Trim()
        if ($t) { $ret += [PSCustomObject]@{Guid = $g; Title = $t} }
    }
    return $ret
}
function Get-Links { param($Guid)
    try { $r = Invoke-WebRequest "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" -Method Post -Body @{UpdateIDs = "[{size:0,UpdateID:'$Guid',UpdateIDInfo:'$Guid'}]"} -ContentType "application/x-www-form-urlencoded" -UseBasicParsing -TimeoutSec 30
    } catch { return @() }
    $c = $r.Content -replace "www.download.windowsupdate", "download.windowsupdate"
    $out = @(); $re = [regex]"downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']*)'"
    foreach ($m in $re.Matches($c)) {
        $url = $m.Groups[1].Value; $fn = $url.Split('/')[-1]
        $sha1 = ""; if ($fn -match '_([a-f0-9]{40})\.(msu|cab)$') { $sha1 = $matches[1] }
        $kb = 0; if ($url -match 'kb(\d+)') { $kb = [int]$matches[1] }
        $out += [PSCustomObject]@{FileName = $fn; Url = $url; Sha1 = $sha1; KB = $kb}
    }
    return ($out | Sort-Object Url -Unique)
}

$chainCache = @{}
function Follow-Chain { param($OldKb, $ArchPat, $OsPref)
    $key = "$OldKb|$ArchPat"; if ($chainCache.ContainsKey($key)) { return $chainCache[$key] }
    $r = Search-Catalog "$OldKb"
    $first = $r | Where-Object { $_.Title -match $ArchPat } | Select-Object -First 1
    if (-not $first) { $chainCache[$key] = $null; return $null }
    try { $sv = Invoke-WebRequest ("https://www.catalog.update.microsoft.com/v7/site/ScopedViewInline.aspx?updateid=" + $first.Guid) -UseBasicParsing -TimeoutSec 15
    } catch { $chainCache[$key] = $null; return $null }
    $html = $sv.Content
    $match = [regex]::Match($html, '(?s)<div id="supersededbyInfo">(.*?)<span')
    if (-not $match.Success) { $ll = Get-Links $first.Guid; $chainCache[$key] = $ll; return $ll }
    $links = [regex]::Matches($match.Groups[1].Value, "<a[^>]*href='([^']*)'[^>]*>([^<]+)</a>")
    if ($links.Count -eq 0) { $ll = Get-Links $first.Guid; $chainCache[$key] = $ll; return $ll }
    $sorted = $links | Sort-Object { $_.Groups[2].Value } -Descending
    $guid = if ($sorted[0].Groups[1].Value -match 'updateid=([a-f0-9\-]{36})') { $matches[1] }
    if (-not $guid) { $chainCache[$key] = $null; return $null }
    $result = Get-Links $guid
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
        $best = $best | Sort-Object Title -Descending | Select-Object -First 1
        if (-not $best) { $best = $candidates | Sort-Object Title -Descending | Select-Object -First 1 }
    }
    # If arch-specific search fails (some x86 .NET updates lack "for x86" in title), 
    # try finding an entry without any architecture tag
    if (-not $best -and $Kind -ne "LCU") {
        $candidates = $r | Where-Object { $_.Title -match '\.NET' -and $_.Title -notmatch 'for (x64|arm64)' }
        $best = $candidates | Where-Object { $_.Title -notmatch '4\.7\.2' }
        if ($Term -notmatch '4\.8\.1') { $best = $best | Where-Object { $_.Title -notmatch '4\.8\.1' } }
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
        return $x.metalink.file | Where-Object { $_.name -match '\.cab$' } | ForEach-Object {
            [PSCustomObject]@{FileName = $_.name; Url = $_.url; Sha1 = $_.hash.'#text'; KB = 0} }
    } catch { return @() }
}
function Get-KB($F) { if ($F.FileName -match 'kb(\d+)') { $matches[1] } else { "" } }
function Get-OldKB($Path, $Kind) {
    if (-not (Test-Path $Path)) { return $null }
    try { $x = [xml](Get-Content $Path -Raw)
        $all = $x.metalink.file
        if ($Kind -eq "LCU") {
            $matches = $all | Where-Object { $_.name -match '\.msu$' -and $_.name -notmatch 'ndp' } | Sort-Object { if ($_.name -match 'kb(\d+)') { [int]$matches[1] } else { 0 } } -Descending
            $first = $matches | Select-Object -First 1
            if ($first -and $first.name -match 'kb(\d+)') { return $matches[1] }
        }
        if ($Kind -eq "NET") {
            $first = $all | Where-Object { $_.name -match 'ndp.*\.msu$' } | Select-Object -First 1
            if ($first -and $first.name -match 'kb(\d+)') { return $matches[1] }
        }
    } catch { }
    return $null
}

# --- Cross-validate: chain vs bootstrap ---
function Cross-Validate($ChainFile, $BootFile, $Label) {
    if (-not $ChainFile -and -not $BootFile) { return $null, "SKIP" }
    if ($ChainFile -and $BootFile) {
        if ($ChainFile.KB -eq $BootFile.KB) { return $ChainFile, "verified" }
        # When mismatch: if chain result exists and boot exists, compare KB age
        # Use the HIGHER KB number (newer), but only if the title looks right
        # For 20348 (Server 2022), chain can give wrong result — prefer bootstrap
        return $BootFile, "bootstrapped (chain mismatch)"
    }
    if ($ChainFile) { return $ChainFile, "chain" }
    return $BootFile, "bootstrapped"
}

# Get all MSU (non-ndp) entries from an existing meta4 file


# Extract build version (e.g. 14393.9062) from the ScopedViewInline page of an LCU
function Get-BuildVersion($Kb, $OsPref, $ArchPat) {
    if (-not $Kb) { return "" }
    try {
        $r = Search-Catalog "kb$Kb"
        $first = $r | Where-Object { $_.Title -match $ArchPat -and $_.Title -match 'Cumulative Update' -and $_.Title -notmatch '\.NET' -and $_.Title -notmatch 'Preview|Safety|Secure Boot' } | Sort-Object Title -Descending | Select-Object -First 1
        if (-not $first) { return "" }
        $sv = Invoke-WebRequest ("https://www.catalog.update.microsoft.com/v7/site/ScopedViewInline.aspx?updateid=" + $first.Guid) -UseBasicParsing -TimeoutSec 15
        $html = $sv.Content
        $m = [regex]::Match($html, '10\.0\.(\d+)\.(\d+)')
        if ($m.Success) { return "$($m.Groups[1].Value).$($m.Groups[2].Value)" }
    } catch { }
    return ""
}

# --- MS Update History page scraping ---
# Parse MS Update History page to find the latest Patch Tuesday KB + OS Build for a given build prefix
function Get-HistoryBuild($TopicId, $BuildPat) {
    $url = "https://support.microsoft.com/en-us/topic/$TopicId"
    $r = $null
    # Retry once on failure (rate limiting)
    $retry = 0; while ($retry -lt 3) {
        try { $r = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 15; break }
        catch { $retry++; if ($retry -ge 3) { return $null }; Start-Sleep -Milliseconds 2000 }
    }
    $h = $r.Content
    $re = [regex]'<a class="supLeftNavLink"[^>]*>([^<]+)</a>'
    $entries = @()
    foreach ($m in $re.Matches($h)) {
        $text = $m.Groups[1].Value -replace '&#x2014;', ''
        # Skip previews, out-of-band, and non-update entries
        if ($text -match 'Out-of-band|Preview|program') { continue }
        $kbMatch = [regex]::Match($text, 'KB(\d+)')
        # BuildPat can be a prefix (e.g. "14393") or a pattern (e.g. "1904[45]")
        $reBuild = [regex]"((?:$BuildPat)\.\d+)"
        $buildMatch = $reBuild.Match($text)
        if ($kbMatch.Success -and $buildMatch.Success) {
            $entries += [PSCustomObject]@{
                KB = [int]$kbMatch.Groups[1].Value
                Build = $buildMatch.Groups[1].Value
            }
        }
    }
    if ($entries.Count -eq 0) { return $null }
    # Latest = highest revision number (non-OOB, non-Preview already filtered)
    return $entries | Sort-Object { $_.Build.Split('.')[-1] -as [int] } -Descending | Select-Object -First 1
}

# Search catalog for a specific KB and return the LCU MSU file matching arch+OS prefix
function Get-FileForKB($Kb, $ArchPat, $OsPref) {
    $r = Search-Catalog "kb$Kb"
    # Prefer non-Dynamic CU, also filter out preview/.NET/safety updates
    $best = $r | Where-Object { $_.Title -match $ArchPat -and $_.Title -match 'Cumulative Update' -and $_.Title -notmatch 'Dynamic|\.NET|Preview|Safe' } | Sort-Object Title -Descending | Select-Object -First 1
    if (-not $best) { $best = $r | Where-Object { $_.Title -match $ArchPat -and $_.Title -notmatch 'Dynamic|\.NET|Preview|Safe' } | Sort-Object Title -Descending | Select-Object -First 1 }
    if (-not $best) { return $null }
    $links = Get-Links $best.Guid
    $m = $links | Where-Object { $_.FileName -match [regex]::Escape($OsPref) }
    if (-not $m) { $m = $links }
    return ($m | Where-Object { $_.FileName -match '\.msu$' -and $_ -notmatch 'ndp' } | Sort-Object KB -Descending | Select-Object -First 1)
}

# Choose build prefix to match on history page (some builds use different revision numbers)
function Get-HistoryBuildPat($bn) {
    $pat = $bn
    if    ($bn -eq "19041") { $pat = "1904\d" }   # 1904x builds share the same LCU
    elseif ($bn -eq "22621") { $pat = "22631" }    # 23H2 history shows 22631.xxxx
    return $pat
}



function Get-OldMsus($Path) {
    if (-not (Test-Path $Path)) { return @() }
    try {
        $x = [xml](Get-Content $Path -Raw)
        return $x.metalink.file | Where-Object { $_.name -match '\.msu$' -and $_.name -notmatch 'ndp' } | ForEach-Object {
            $kb = 0; if ($_.name -match 'kb(\d+)') { $kb = [int]$matches[1] }
            [PSCustomObject]@{FileName = $_.name; Url = $_.url; Sha1 = $_.hash.'#text'; KB = $kb}
        }
    } catch { return @() }
}

# Get all entries from an existing meta4 file (full content preservation)
function Get-ExistingFiles($Path) {
    if (-not (Test-Path $Path)) { return @() }
    try {
        $x = [xml](Get-Content $Path -Raw)
        return $x.metalink.file | ForEach-Object {
            $kb = 0; if ($_.name -match 'kb(\d+)') { $kb = [int]$matches[1] }
            $sha = if ($_.hash) { $_.hash.'#text' } else { "" }
            $lang = if ($_.language) { $_.language } else { "" }
            [PSCustomObject]@{FileName = $_.name; Url = $_.url; Sha1 = $sha; KB = $kb; Language = $lang}
        }
    } catch { return @() }
}

# ---- Main ----
Write-Host "=== Win_ISO_Patching_Scripts - meta4 Auto-Gen ===" -ForegroundColor Cyan
if ($Build.Count -eq 1 -and $Build[0] -match ',') { $Build = $Build[0] -split ',' | ForEach-Object { $_.Trim() } }
if ($Arch.Count -eq 1 -and $Arch[0] -match ',') { $Arch = $Arch[0] -split ',' | ForEach-Object { $_.Trim() } }
if ($Build.Count -eq 0) { $Build = $CFG.Keys | Sort-Object }
if ($Arch.Count -eq 0) { $Arch = @("x64", "x86", "arm64") }
$gen = 0; $skip = 0

foreach ($bn in $Build) {
    $c = $CFG[$bn]; if (-not $c) { continue }
    foreach ($ar in $Arch) {
        $al = $ARCH_LABEL[$ar]
        $ap = "for $ar" + $(if ($ar -eq "arm64") { "" } else { "[^a-z]" })
        if (-not $al) { continue }
        if ($bn -eq "28000" -and $ar -eq "x86") { continue }
        $old = Join-Path $OutputDir "script_${bn}_${ar}.meta4"
        $newFiles = @()
        Write-Host "--- [$bn/$ar] $($c.L) ---" -ForegroundColor Yellow

        # 1. LCU
        Write-Host "  LCU..." -NoNewline
        try {
            # Primary source: MS Update History page (most reliable)
            $f = $null; $tag = ""
            $histTopic = $UPDATE_HISTORY[$bn]
            if ($histTopic) {
                $bp = Get-HistoryBuildPat $bn
                $hb = Get-HistoryBuild -TopicId $histTopic -BuildPat $bp
                if ($hb) {
                    $hf = Get-FileForKB -Kb $hb.KB -ArchPat $ap -OsPref $c.OP
                    if ($hf) { $f = $hf; $tag = "history (build $($hb.Build))" }
                }
            }
            # Fallback: chain follow from old KB + bootstrap search
            if (-not $f) {
                $chain = $null; $boot = $null
                $okb = Get-OldKB $old "LCU"
                if ($okb) { $cl = Follow-Chain -OldKb $okb -ArchPat $ap -OsPref $c.OP; $chain = Pick-File $cl "LCU" $c.OP }
                $boot = Bootstrap-Search -Term $c.S1 -ArchPat $ap -OsPref $c.OP -Kind "LCU"
                $f, $tag = Cross-Validate $chain $boot "LCU"
            }
            if ($f) { $newFiles += $f; Write-Host " $($f.FileName) ($tag)" -ForegroundColor $(if($tag-match"^history"){"Green"}elseif($tag-eq"verified"){"Green"}elseif($tag-eq"chain"){"Cyan"}else{"Yellow"}) }
            else { Write-Host " SKIP"; $skip++; continue }
        } catch { Write-Host " ERROR: $_"; $skip++; continue }

        # SSU (14393 only) - Find newest SSU, replace old one after MSU preservation
        $ssuNewFile = $null
        if ($bn -eq "14393") {
            Start-Sleep -Milliseconds 600
            $ssuR = Search-Catalog "Servicing Stack Update for Windows 10 Version 1607 for x64-based Systems"
            $ssuBest = $ssuR | Where-Object { $_.Title -match "Servicing Stack" -and $_.Title -match "for x64[^a-z]" -and $_.Title -match "Version 1607" -and $_.Title -notmatch "Preview" } | Sort-Object Title -Descending | Select-Object -First 1
            if ($ssuBest) {
                $ssuLinks = Get-Links $ssuBest.Guid
                $ssuNewFile = Pick-File $ssuLinks "SSU" $c.OP
            }
            # Use old SSU URL for sorting position (will be replaced after preservation)
            $oldMsusAll = Get-OldMsus $old
            if ($oldMsusAll.Count -gt 0 -and $f) {
                $oldSsu = $oldMsusAll | Where-Object { $_.KB -ne $f.KB } | Select-Object -First 1
                if ($oldSsu -and $oldSsu.Url) { $ssuFile = $oldSsu }
            }
        } else { Write-Host "  SSU: bundled" -ForegroundColor DarkGray }

        Start-Sleep -Milliseconds 600

        # 2. .NET
        Write-Host "  .NET..." -NoNewline
        try {
            $chain = $null; $boot = $null
            $okb = Get-OldKB $old "NET"
            if ($okb) { $cl = Follow-Chain -OldKb $okb -ArchPat $ap -OsPref $c.OP; $chain = Pick-File $cl "NET" $c.OP }
            $boot = Bootstrap-Search -Term $c.S3 -ArchPat $ap -OsPref $c.OP -Kind "NET"
            $f, $tag = Cross-Validate $chain $boot "NET"
            # Verify OS prefix (windows10.0 rejects windows11.0)
            if ($f -and $f.FileName -notmatch "^$($c.OP)") { $f = $null; $tag = "SKIP (OS mismatch)" }
            # For builds with netfx subdirs (14393/17763/19041/20348), .NET goes to subdir, not main meta4
            if ($f -and $bn -in @("14393","17763","19041","20348")) { $f = $null; $tag = "in netfx subdir" }
            if ($f) { $newFiles += $f; Write-Host " $($f.FileName) ($tag)" -ForegroundColor $(if($tag-eq"verified"){"Green"}elseif($tag-eq"chain"){"Cyan"}else{"Yellow"}) }
            else { Write-Host " $tag" -ForegroundColor DarkGray }
        } catch { Write-Host " ERROR: $_" -ForegroundColor Red }

        $fnet = $f  # Save .NET result for sorting

        # 3. Preserve old MSUs (keep previous LCU/component MSUs)
        # Upstream keeps multiple MSUs across releases (old LCU + new LCU + extras)
        if (Test-Path $old) {
            $oldMsus = Get-OldMsus $old
            $newKbs = @($newFiles | Where-Object { $_.KB -gt 0 } | ForEach-Object { $_.KB })
            # Also exclude the old LCU that was replaced by the new one
            $oldLcuKb = Get-OldKB $old "LCU"
            if ($oldLcuKb -and $oldLcuKb -notin $newKbs) { $newKbs += $oldLcuKb }
            # Exclude old .NET if .NET is in main meta4 (no netfx subdir)
            if ($bn -notin @("14393","17763","19041","20348")) {
                $oldNetKb = Get-OldKB $old "NET"
                if ($oldNetKb -and $oldNetKb -notin $newKbs) { $newKbs += $oldNetKb }
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
        if ($bn -eq "14393" -and $ssuNewFile -and ($ssuNewFile.Url -notin $newFiles.Url)) {
            # Remove the old SSU (lowest KB non-LCU MSU that's not .NET) and add new one
            $newFiles = @($newFiles | Where-Object { $_.Url -ne $ssuFile.Url })
            $newFiles += $ssuNewFile
            $ssuFile = $ssuNewFile  # Update sort URL
            Write-Host "  [SSU] replaced: $($ssuNewFile.FileName)" -ForegroundColor Green
        }

        # 4. Netfx subdir meta4 files
        # NB: These contain static baseline language MSUs + one .NET ndp MSU
        # Preserve existing baseline MSUs; chain-update the ndp entry
        if ($bn -in @("14393","17763","19041","20348")) {
            $nf48Dir = Join-Path $OutputDir "netfx4.8"
            if (-not (Test-Path $nf48Dir)) { New-Item $nf48Dir -ItemType Directory -Force | Out-Null }
            $nf48Path = Join-Path $nf48Dir "script_netfx4.8_${bn}_${ar}.meta4"
            $nf48Files = Get-ExistingFiles $nf48Path
            $nf48Ndp = $nf48Files | Where-Object { $_.FileName -match 'ndp.*\.msu$' } | Sort-Object KB -Descending | Select-Object -First 1
            if ($nf48Ndp -and $nf48Ndp.KB -gt 0) {
                $cl = Follow-Chain -OldKb $nf48Ndp.KB -ArchPat $ap -OsPref $c.OP
                $newNdp = Pick-File $cl "NET" $c.OP
                # If chain returned the same KB (no supersedence), force bootstrap
                if ($newNdp -and $newNdp.KB -eq $nf48Ndp.KB) { $newNdp = $null }
                if (-not $newNdp) {
                    # Bootstrap fallback using S3 term, with S4 for pure 4.8
                    $boot = Bootstrap-Search -Term $c.S3 -ArchPat $ap -OsPref $c.OP -Kind "NET"
                    if ($c.S4) { $s3Ndp = if($boot -and $boot.FileName -match 'ndp(\d+)'){$matches[1]}; $oldNdp = if($nf48Ndp.FileName -match 'ndp(\d+)'){$matches[1]}; if (-not $boot -or ($s3Ndp -and $oldNdp -and $s3Ndp -ne $oldNdp)) { $boot = Bootstrap-Search -Term $c.S4 -ArchPat $ap -OsPref $c.OP -Kind "NET" } }

                    $bootBoot = Bootstrap-Search -Term ".NET Framework 4.8 $($c.L)" -ArchPat $ap -OsPref $c.OP -Kind "NET"
                    if ($boot -and $boot.KB -eq $nf48Ndp.KB) { $newNdp = $boot; $tag = "verified" }
                    elseif ($boot) { $newNdp = $boot; $tag = "bootstrapped" }
                }
                # Verify OS prefix matches + ndp version is consistent (ndp48 != ndp481)
                if ($newNdp -and $newNdp.FileName -notmatch "^$($c.OP)") { $newNdp = $null }
                if ($newNdp) { $oldN = if($nf48Ndp.FileName -match 'ndp(\d+)'){$matches[1]}; $newN = if($newNdp.FileName -match 'ndp(\d+)'){$matches[1]}; if($oldN -and $newN -and $oldN -ne $newN){$newNdp=$null} }
                #
                if ($newNdp -and $newNdp.KB -ne $nf48Ndp.KB) {
                    # Keep all baselines, replace the ndp entry
                    $baselines = $nf48Files | Where-Object { $_.FileName -notmatch 'ndp.*\.msu$' }
                    $newNdp = $newNdp | Select-Object *, @{N='Language';E={'neutral'}} -ExcludeProperty Language
                    $nf48All = @($newNdp) + $baselines
                    if (-not $TestMode) { (New-Meta4 $nf48All) | Out-File $nf48Path -Encoding utf8 -NoNewline }
                    Write-Host "  [netfx4.8] $($nf48Ndp.KB) -> $($newNdp.FileName)" -ForegroundColor Green
                } else {
                    Write-Host "  [netfx4.8] KB$($nf48Ndp.KB) (unchanged)" -ForegroundColor DarkGray
                }
            } else {
                # No existing ndp entry — try fresh bootstrap
                $boot = Bootstrap-Search -Term $c.S3 -ArchPat $ap -OsPref $c.OP -Kind "NET"
                if (-not $boot -and $c.S4) { $boot = Bootstrap-Search -Term $c.S4 -ArchPat $ap -OsPref $c.OP -Kind "NET" }
                if ($boot) {
                    # For netfx4.8 new entries, re-check: old OS prefix filter may have already handled this
                    # but also verify arch matches (don't put x86 .NET in arm64 file)
                    $bootArchOk = $false
                    if ($boot.FileName -match 'arm64' -and $ar -match 'arm64') { $bootArchOk = $true }
                    elseif ($boot.FileName -notmatch 'arm64|x64|x86') { $bootArchOk = $true }
                    elseif ($boot.FileName -match 'x64' -and $ar -eq 'x64') { $bootArchOk = $true }
                    elseif ($boot.FileName -match 'x86' -and $ar -eq 'x86') { $bootArchOk = $true }
                    elseif ($boot.FileName -match $ar) { $bootArchOk = $true }
                }
                if ($boot -and $boot.FileName -match "^$($c.OP)" -and $bootArchOk) {
                    $boot = $boot | Select-Object *, @{N='Language';E={'neutral'}} -ExcludeProperty Language
                    $nf48All = @($boot) + ($nf48Files | Where-Object { $_.FileName -notmatch 'ndp.*\.msu$' })
                    if (-not $TestMode) { (New-Meta4 $nf48All) | Out-File $nf48Path -Encoding utf8 -NoNewline }
                    Write-Host "  [netfx4.8] (new) $($boot.FileName)" -ForegroundColor Yellow
                } else {
                    Write-Host "  [netfx4.8] (not found)" -ForegroundColor DarkGray
                }
            }
        }

        # netfx4.8.1 subdir: only 19041/20348 x64/x86 (arm64 has 4.8 only, no 4.8.1)
        if ($bn -in @("19041","20348") -and $ar -ne "arm64") {
            $nf481Dir = Join-Path $OutputDir "netfx4.8.1"
            if (-not (Test-Path $nf481Dir)) { New-Item $nf481Dir -ItemType Directory -Force | Out-Null }
            $nf481Path = Join-Path $nf481Dir "script_netfx4.8.1_${bn}_${ar}.meta4"
            $nf481Files = Get-ExistingFiles $nf481Path
            $nf481Ndp = $nf481Files | Where-Object { $_.FileName -match 'ndp.*\.msu$' } | Sort-Object KB -Descending | Select-Object -First 1
            if ($nf481Ndp -and $nf481Ndp.KB -gt 0) {
                $cl = Follow-Chain -OldKb $nf481Ndp.KB -ArchPat $ap -OsPref $c.OP
                $newNdp = Pick-File $cl "NET" $c.OP
                if ($newNdp -and $newNdp.KB -eq $nf481Ndp.KB) { $newNdp = $null }
                if (-not $newNdp) {
                    $boot = Bootstrap-Search -Term $c.S3 -ArchPat $ap -OsPref $c.OP -Kind "NET"
                    if (-not $boot) {
                        $boot = Bootstrap-Search -Term "kb$($nf481Ndp.KB)" -ArchPat $ap -OsPref $c.OP -Kind "NET"
                    }
                    if ($boot -and $boot.KB -eq $nf481Ndp.KB) { $newNdp = $boot; $tag = "verified" }
                    elseif ($boot) { $newNdp = $boot; $tag = "bootstrapped" }
                }
                if ($newNdp -and $newNdp.FileName -notmatch "^$($c.OP)") { $newNdp = $null }
                if ($newNdp) { $oldN = if($nf481Ndp.FileName -match 'ndp(\d+)'){$matches[1]}; $newN = if($newNdp.FileName -match 'ndp(\d+)'){$matches[1]}; if($oldN -and $newN -and $oldN -ne $newN){$newNdp=$null} }
                if ($newNdp -and $newNdp.KB -ne $nf481Ndp.KB) {
                    $baselines = $nf481Files | Where-Object { $_.FileName -notmatch 'ndp.*\.msu$' }
                    $newNdp = $newNdp | Select-Object *, @{N='Language';E={'neutral'}} -ExcludeProperty Language
                    $nf481All = @($newNdp) + $baselines
                    if (-not $TestMode) { (New-Meta4 $nf481All) | Out-File $nf481Path -Encoding utf8 -NoNewline }
                    Write-Host "  [netfx4.8.1] $($nf481Ndp.KB) -> $($newNdp.FileName)" -ForegroundColor Green
                } else {
                    Write-Host "  [netfx4.8.1] KB$($nf481Ndp.KB) (unchanged)" -ForegroundColor DarkGray
                }
            } else {
                $boot = Bootstrap-Search -Term $c.S3 -ArchPat $ap -OsPref $c.OP -Kind "NET"
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
                    $nf481All = @($boot) + ($nf481Files | Where-Object { $_.FileName -notmatch 'ndp.*\.msu$' })
                    if (-not $TestMode) { (New-Meta4 $nf481All) | Out-File $nf481Path -Encoding utf8 -NoNewline }
                    Write-Host "  [netfx4.8.1] (new) $($boot.FileName)" -ForegroundColor Yellow
                } else {
                    Write-Host "  [netfx4.8.1] (not found)" -ForegroundColor DarkGray
                }
            }
        }

        # 5. CABs via chain
        $oldCabs = Get-Cabs $old
        foreach ($oc in $oldCabs) {
            $oldKb = Get-KB $oc
            if ($oldKb) {
                $links = Follow-Chain -OldKb $oldKb -ArchPat $ap -OsPref $c.OP
                $cab = $links | Where-Object { $_.FileName -match '\.cab$' } | Select-Object -First 1
                if ($cab -and $cab.FileName -ne $oc.FileName -and ($cab.Url -notin $newFiles.Url)) {
                    $newFiles += $cab; Write-Host "  [CAB] $oldKb -> $($cab.FileName)" -ForegroundColor Green
                } elseif ($oc.Url -notin ($newFiles | ForEach-Object { $_.Url })) {
                    $oc2 = [PSCustomObject]@{FileName=$oc.FileName; Url=$oc.url; Sha1=$oc.Sha1; KB=0}
                    $newFiles += $oc2; Write-Host "  [CAB] $oldKb (unchanged)" -ForegroundColor DarkGray
                }
            } elseif ($oc.Url -notin ($newFiles | ForEach-Object { $_.Url })) {
                $oc2 = [PSCustomObject]@{FileName=$oc.FileName; Url=$oc.url; Sha1=$oc.Sha1; KB=0}
                $newFiles += $oc2
            }
            Start-Sleep -Milliseconds 400
        }

        $all = @($newFiles) | Sort-Object Url -Unique
        # Reorder CABs: setup DU → safe OS DU → other CABs
        # Old meta4 has safe OS before setup DU (reversed); swap by position
        # CAB ordering: setup DU before safe OS DU
        $cabs = @($all | Where-Object { $_.FileName -match '\.cab$' })
        if ($cabs.Count -ge 2) {
            $nonCabs = @($all | Where-Object { $_.FileName -notmatch '\.cab$' })
            $rest = if ($cabs.Count -gt 2) { $cabs[2..($cabs.Count-1)] } else { @() }
            $reorderedCabs = @($cabs[1], $cabs[0]) + $rest
            $all = $nonCabs + $reorderedCabs
        }
        if ($TestMode) { Write-Host "  [TEST] $($all.Count) entries"; $gen++; continue }

        # Get key URL markers for sorting
        $latestLCU = $newFiles | Where-Object { $_.FileName -match '\.msu$' -and $_.FileName -notmatch 'ndp' -and $_.Url -notin @() } | Sort-Object KB -Descending | Select-Object -First 1
        $latestLCUUrl = if ($latestLCU) { $latestLCU.Url } else { "" }
        $ssuUrl = if ($ssuFile) { $ssuFile.Url } else { "" }
        $netMsuUrl = if ($fnet) { $fnet.Url } else { "" }
        # ---- Sort: SSU → checkpoint CU → LCU → old MSU(EKB/setup DU/safe OS DU) → .NET ndp/msu → CAB ----
        $sortedAll = $all | Sort-Object @{Expression={
            $n = $_.FileName
            if ($n -match '\.cab$') { return 50 }               # CAB last
            if ($n -match 'ndp.*\.msu') { return 40 }           # .NET ndp
            if ($_.Url -eq $ssuUrl) { return 5 }                # SSU first
            if ($bn -eq "26100" -and $_.KB -eq 5043080) { return 10 }  # checkpoint CU
            if ($_.Url -eq $latestLCUUrl) { return 15 }         # latest LCU
            if ($_.Url -eq $netMsuUrl) { return 35 }            # .NET MSU (non-ndp filename)
            return 20                                           # other old MSU (EKB/setup DU/safe OS DU)
        }}
        $xml = New-Meta4 $sortedAll
        $xml | Out-File (Join-Path $OutputDir "script_${bn}_${ar}.meta4") -Encoding utf8 -NoNewline
        Write-Host "  [OK] $($all.Count) files" -ForegroundColor Green; $gen++

        # Server 2025 is x64 only, no arm64 version
        if ($bn -eq "26100" -and $ar -eq "x64") {
            # Server variant: separate from main — only its OWN LCU + .NET + its OWN CABs
            # 26100 checkpoint CU (e.g. 5043080) is shared; preserved from old server meta4
            # Server has its own LCU (e.g. 5091157), not inherited from client
            $serverOld = Join-Path $OutputDir "script_server_${bn}_${ar}.meta4"
            $serverFiles = @()
            # Server independent .NET search (currently shares KB5082417 with client, may diverge)
            Write-Host "  [SERVER .NET]..." -NoNewline
            try {
                $sNetBoot = Bootstrap-Search -Term ".NET Framework 3.5 and 4.8.1 Microsoft server operating system version 24H2" -ArchPat $ap -OsPref $c.OP -Kind "NET"
                if (-not $sNetBoot) {
                    # Fall back to main meta4 .NET if no server-specific .NET found
                    foreach ($nf in $newFiles) {
                        if ($nf.FileName -match 'ndp.*\.msu$') { $serverFiles += $nf }
                    }
                    Write-Host " from main" -ForegroundColor DarkGray
                } else {
                    $serverFiles += $sNetBoot
                    Write-Host " $($sNetBoot.FileName)" -ForegroundColor Yellow
                }
            } catch {
                foreach ($nf in $newFiles) {
                    if ($nf.FileName -match 'ndp.*\.msu$') { $serverFiles += $nf }
                }
                Write-Host " from main (fallback)" -ForegroundColor DarkGray
            }
            # Server independent LCU search
            Write-Host "  [SERVER LCU]..." -NoNewline
            try {
                # Primary: MS Update History page for Server 2025
                $sf = $null; $stag = ""
                $sHistTopic = $UPDATE_HISTORY_SERVER[$bn]
                if ($sHistTopic) {
                    $shb = Get-HistoryBuild -TopicId $sHistTopic -BuildPat $bn
                    if ($shb) {
                        $shf = Get-FileForKB -Kb $shb.KB -ArchPat $ap -OsPref $c.OP
                        if ($shf) { $sf = $shf; $stag = "history (build $($shb.Build))" }
                    }
                }
                # Fallback: chain + bootstrap
                if (-not $sf) {
                    $sChain = $null; $sBoot = $null
                    $serverOldMsus = Get-OldMsus $serverOld
                    if ($serverOldMsus.Count -eq 0) {
                        # If no old server meta4 (e.g. arm64), borrow checkpoint CU (5043080) from main meta4
                        $mainMsus = Get-OldMsus $old
                        $checkpointCU = $mainMsus | Where-Object { $_.KB -eq 5043080 }
                        if ($checkpointCU) {
                            foreach ($cp in $checkpointCU) {
                                if ($cp.Url -notin $serverFiles.Url) { $serverFiles += $cp }
                            }
                            Write-Host "  [SERVER CHECKPOINT] borrowed from main" -ForegroundColor DarkGray
                        }
                        # Get latest non-checkpoint LCU from main meta4 as chain starting point
                        $latestMainMsu = $mainMsus | Where-Object { $_.KB -ne 5043080 } | Sort-Object KB -Descending | Select-Object -First 1
                        if ($latestMainMsu) { $serverOldMsus = @($latestMainMsu) }
                    }
                    if ($serverOldMsus.Count -gt 0) {
                        # Preserve old LCUs (checkpoint CU etc.), only replace the latest one
                        $sorted = $serverOldMsus | Sort-Object KB -Descending
                        $sOkb = $sorted[0].KB  # Latest KB to use for chain
                        $checkpoints = $sorted | Select-Object -Skip 1  # Remaining are checkpoints
                        foreach ($cp in $checkpoints) {
                            if ($cp.Url -notin $serverFiles.Url) { $serverFiles += $cp }
                        }
                        $sChainResult = Follow-Chain -OldKb $sOkb -ArchPat $ap -OsPref $c.OP
                        $sChain = Pick-File $sChainResult "LCU" $c.OP
                    }
                    # Server bootstrap: search for "Cumulative Update for Microsoft server operating system version 24H2"
                    $sBootTerm = "Cumulative Update for Microsoft server operating system version 24H2"
                    $sBoot = Bootstrap-Search -Term $sBootTerm -ArchPat $ap -OsPref $c.OP -Kind "LCU"
                    # Fall back to standard search if bootstrap fails
                    if (-not $sBoot) { $sBoot = Bootstrap-Search -Term $c.S1 -ArchPat $ap -OsPref $c.OP -Kind "LCU" }
                    $sf, $stag = Cross-Validate $sChain $sBoot "LCU_SERVER"
                }
                if ($sf) {
                    $serverFiles += $sf
                    Write-Host " $($sf.FileName) ($stag)" -ForegroundColor $(if($stag-match"^history"){"Green"}elseif($stag-eq"verified"){"Green"}elseif($stag-eq"chain"){"Cyan"}else{"Yellow"})
                } else {
                    Write-Host " SKIP (no server LCU found)" -ForegroundColor DarkGray
                }
            } catch { Write-Host " ERROR: $_" -ForegroundColor DarkGray }
            # Server CABs (chain-updated); borrow from main meta4 if no old server meta4 exists
            $sc = Get-Cabs $serverOld
            if ($sc.Count -eq 0 -and (Test-Path $old)) {
                $sc = Get-Cabs $old
                Write-Host "  [CAB] (借用主 meta4 的 CAB)" -ForegroundColor DarkGray
            }
            foreach ($oc in $sc) {
                $oldKb = Get-KB $oc
                if ($oldKb) {
                    $links = Follow-Chain -OldKb $oldKb -ArchPat $ap -OsPref $c.OP
                    $cab = $links | Where-Object { $_.FileName -match '\.cab$' } | Select-Object -First 1
                    if ($cab -and $cab.Url -notin $serverFiles.Url) { $serverFiles += $cab }
                    elseif ($oc.Url -notin $serverFiles.Url) { $serverFiles += [PSCustomObject]@{FileName=$oc.FileName; Url=$oc.url; Sha1=$oc.Sha1; KB=0} }
                } elseif ($oc.Url -notin $serverFiles.Url) { $serverFiles += [PSCustomObject]@{FileName=$oc.FileName; Url=$oc.url; Sha1=$oc.Sha1; KB=0} }
            }
            $sa = $serverFiles | Sort-Object Url -Unique
            if (-not $TestMode) {
                # Find server latest LCU URL for sorting
                $sLatestLCU = $serverFiles | Where-Object { $_.FileName -match '\.msu$' -and $_.FileName -notmatch 'ndp' -and $_.Url -notin @() } | Sort-Object KB -Descending | Select-Object -First 1
                $sLatestLCUUrl = if ($sLatestLCU) { $sLatestLCU.Url } else { '' }
                $sortedSa = $sa | Sort-Object @{Expression={
                    $n = $_.FileName
                    if ($n -match '\.cab$') { return 50 }
                    if ($n -match 'ndp.*\.msu') { return 40 }
                    if ($_.KB -eq 5043080) { return 10 }
                    if ($_.Url -eq $sLatestLCUUrl) { return 15 }
                    return 20
                }}
                $sx = New-Meta4 $sortedSa
                $sx | Out-File $serverOld -Encoding utf8 -NoNewline
            }
            Write-Host "  [OK] server variant ($($sa.Count) files)" -ForegroundColor Green
        }
    }
}
# Update README date
if (-not $TestMode) {
    $culture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
    $today = $culture.DateTimeFormat.GetMonthName((Get-Date).Month) + ' ' + (Get-Date -Format 'dd, yyyy')
    $todayCn = Get-Date -Format 'yyyy年M月d日'
    foreach ($readme in @("README.md", "README_cn.md")) {
        $path = Join-Path $ScriptRoot $readme
        if (Test-Path $path) {
            $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            $content = $content -replace 'April 30, 2026', $today
            $content = $content -replace '2026年4月30日', $todayCn
            [System.IO.File]::WriteAllText($path, $content, [System.Text.Encoding]::UTF8)
        }
    }
}Write-Host "=== Done: $gen generated, $skip skipped ===" -ForegroundColor Cyan

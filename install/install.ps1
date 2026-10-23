<#
Install Ranked Race for Hades II on Windows (Steam).

  powershell -ExecutionPolicy Bypass -File install\install.ps1              install or update
  powershell -ExecutionPolicy Bypass -File install\install.ps1 -Uninstall   remove it again
  options: -GameDir "C:\...\Hades II"   (default: found in your Steam libraries)
           -Name "Your Name"            the name your rival sees (default: "Melinoe 123")
           -DryRun                      show what would happen, change nothing

What it does (and nothing else):
  1. finds the Hades II install in your Steam libraries;
  2. downloads the exact Hell2Modding + ModUtil set the mod is tested with from
     Thunderstore (install\packages.txt) and checks each SHA-256;
  3. puts Hell2Modding's d3d12.dll next to Hades2.exe (an existing one is backed
     up) and the mods into "Hades II\Ship\ReturnOfModding\plugins".
It never touches your saves. Afterwards set the Steam launch options it prints
(Steam keeps those itself; no script can set them reliably).
Works with Windows PowerShell 5.1 and PowerShell 7.
#>
param(
    [string]$GameDir = "",
    [string]$Name = "",
    [switch]$Uninstall,
    [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest is very slow with the progress bar on 5.1

$Root = Split-Path -Parent $PSScriptRoot
$Guid = "schmidtwmark-RankedRace"
$Marker = ".ranked-race-install"
$LaunchOptions = "%command% --rom_enabled true"

function Say([string]$text) { Write-Host $text }
function Die([string]$text) { Write-Host "error: $text" -ForegroundColor Red; exit 1 }
function Act([string]$what, [scriptblock]$do) {
    if ($DryRun) { Say "  (dry run) $what" } else { & $do }
}

function Find-SteamRoots {
    $roots = @()
    foreach ($key in @("HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "HKLM:\SOFTWARE\Valve\Steam")) {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            if ($p.SteamPath) { $roots += $p.SteamPath }
            if ($p.InstallPath) { $roots += $p.InstallPath }
        } catch { }
    }
    $roots += "C:\Program Files (x86)\Steam"
    return $roots | Select-Object -Unique
}

function Find-Game {
    $libs = @()
    foreach ($r in Find-SteamRoots) {
        $r = $r -replace "/", "\"
        if (Test-Path (Join-Path $r "steamapps")) { $libs += $r }
        $vdf = Join-Path $r "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($line in Get-Content $vdf) {
                if ($line -match '^\s*"path"\s*"(.*)"') { $libs += ($Matches[1] -replace '\\\\', '\') }
            }
        }
    }
    foreach ($l in ($libs | Select-Object -Unique)) {
        $g = Join-Path $l "steamapps\common\Hades II"
        if (Test-Path (Join-Path $g "Ship\Hades2.exe")) { return $g }
    }
    return $null
}

if (-not $GameDir) {
    $GameDir = Find-Game
    if (-not $GameDir) { Die 'could not find Hades II in your Steam libraries; pass -GameDir "C:\path\to\Hades II"' }
}
$Ship = Join-Path $GameDir "Ship"
if (-not (Test-Path (Join-Path $Ship "Hades2.exe"))) { Die "$Ship\Hades2.exe not found (is -GameDir the 'Hades II' folder?)" }
$Rom = Join-Path $Ship "ReturnOfModding"
$Plugins = Join-Path $Rom "plugins"
$Dll = Join-Path $Ship "d3d12.dll"
$DllBackup = Join-Path $Ship "d3d12.dll.before-ranked-race"
Say "Hades II: $GameDir"

# --- uninstall ---------------------------------------------------------------------
if ($Uninstall) {
    $ours = Test-Path (Join-Path $Rom $Marker)   # this installer created the ReturnOfModding folder
    if ($ours) {
        Act "remove $Rom" { Remove-Item -Recurse -Force $Rom }
        Say "removed $Rom"
    } else {
        $mine = Join-Path $Plugins $Guid
        Act "remove $mine" { if (Test-Path $mine) { Remove-Item -Recurse -Force $mine } }
        Say "removed $mine (ReturnOfModding was there before this installer, so the rest stays)"
    }
    if (Test-Path $DllBackup) {
        Act "restore $DllBackup" { Move-Item -Force $DllBackup $Dll }
        Say "restored the d3d12.dll that was there before"
    } elseif ($ours -and (Test-Path $Dll)) {
        Act "remove $Dll" { Remove-Item -Force $Dll }
        Say "removed Hell2Modding (Ship\d3d12.dll)"
    }
    Say "Done. Remove the Hades II launch options in Steam if you added them."
    exit 0
}

# --- download + verify ----------------------------------------------------------------
if (-not (Test-Path (Join-Path $Root "mod\src\main.lua"))) { Die "run this from a full copy of the repository (mod\src is missing)" }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$Work = Join-Path ([IO.Path]::GetTempPath()) ("ranked-race-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $Work | Out-Null
try {
    foreach ($line in Get-Content (Join-Path $Root "install\packages.txt")) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        $parts = $line -split "\s+"
        $pkg = $parts[0]; $version = $parts[1]; $hash = $parts[2]
        # (PowerShell names are case-insensitive: don't reuse $Name here)
        $ns = $pkg.Substring(0, $pkg.IndexOf("-")); $pkgName = $pkg.Substring($pkg.IndexOf("-") + 1)
        $zip = Join-Path $Work "$pkg.zip"
        Say "downloading $pkg $version"
        Invoke-WebRequest -UseBasicParsing -Uri "https://thunderstore.io/package/download/$ns/$pkgName/$version/" -OutFile $zip
        $got = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLower()
        if ($got -ne $hash.ToLower()) { Die "$pkg $version`: SHA-256 mismatch (got $got, want $hash); not installing" }
        Expand-Archive -Path $zip -DestinationPath (Join-Path $Work "x\$pkg") -Force
    }

    # --- install ----------------------------------------------------------------------
    $h2m = Join-Path $Work "x\Hell2Modding-Hell2Modding\ReturnOfModdingPack\d3d12.dll"
    if (-not (Test-Path $h2m)) { Die "Hell2Modding package has no ReturnOfModdingPack\d3d12.dll" }
    $fresh = -not (Test-Path $Rom)
    if ((Test-Path $Dll) -and ((Get-FileHash $Dll).Hash -ne (Get-FileHash $h2m).Hash)) {
        Act "back up $Dll" { Copy-Item -Force $Dll $DllBackup }
        Say "backed up the existing Ship\d3d12.dll to d3d12.dll.before-ranked-race"
    }
    Act "copy d3d12.dll to $Ship" { Copy-Item -Force $h2m $Dll }
    Act "create $Plugins" { New-Item -ItemType Directory -Force -Path $Plugins | Out-Null }
    if ($fresh) { Act "mark $Rom as ours" { New-Item -ItemType File -Force -Path (Join-Path $Rom $Marker) | Out-Null } }
    foreach ($dir in Get-ChildItem -Directory (Join-Path $Work "x")) {
        if ($dir.Name -eq "Hell2Modding-Hell2Modding") { continue }
        $dest = Join-Path $Plugins $dir.Name
        Act "install $($dir.Name)" {
            if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
            Copy-Item -Recurse -Force $dir.FullName $dest
        }
    }
    $mine = Join-Path $Plugins $Guid
    Act "install $Guid" {
        if (Test-Path $mine) { Remove-Item -Recurse -Force $mine }
        New-Item -ItemType Directory -Force -Path $mine | Out-Null
        Copy-Item -Recurse -Force (Join-Path $Root "mod\src\*") $mine
    }
    Say "installed Hell2Modding + ModUtil + Ranked Race into $Rom"

    # Skip Hell2Modding's first-launch welcome window: it holds the controller
    # until it's dismissed, before the player ever reaches the race menu.
    $guiCfg = Join-Path $Rom "config\Hell2Modding-Hell2Modding-GUI.cfg"
    Act "mark Hell2Modding as onboarded in $guiCfg" {
        New-Item -ItemType Directory -Force -Path (Split-Path $guiCfg) | Out-Null
        $lines = @()
        if (Test-Path $guiCfg) { $lines = @(Get-Content $guiCfg | Where-Object { $_ -notmatch '^onboarded[ =]' }) }
        if (-not ($lines | Where-Object { $_ -match '^is_open_at_startup' })) { $lines += 'is_open_at_startup = false' }
        $lines += 'onboarded = true'
        [IO.File]::WriteAllText($guiCfg, (($lines -join "`n") + "`n"))
    }

    # No log console window at startup (it opens over the game; LogOutput.log keeps
    # the same lines). Hell2Modding fills in the rest of this file on first launch.
    $h2mCfg = Join-Path $Rom "config\Hell2Modding-Hell2Modding-General.cfg"
    Act "turn off Hell2Modding's log console in $h2mCfg" {
        New-Item -ItemType Directory -Force -Path (Split-Path $h2mCfg) | Out-Null
        $lines = @()
        if (Test-Path $h2mCfg) { $lines = @(Get-Content $h2mCfg) }
        if ($lines | Where-Object { $_ -match '^Console Enabled' }) {
            $lines = @($lines | ForEach-Object { if ($_ -match '^Console Enabled') { 'Console Enabled = false' } else { $_ } })
        } else {
            $lines += '[Logging]'
            $lines += 'Console Enabled = false'
        }
        [IO.File]::WriteAllText($h2mCfg, (($lines -join "`n") + "`n"))
    }

    # The name other racers see (controller players can't type one in game).
    if ($Name) {
        if ($Name -notmatch "^[A-Za-z0-9 _.'-]{1,24}$") { Die "-Name: 1-24 letters, digits, spaces or _ . ' -" }
        $cfgDir = Join-Path $Rom "config\$Guid"
        $cfgPath = Join-Path $cfgDir "config.json"
        Act "set player_name in $cfgPath" {
            New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
            $cfg = @{}
            if (Test-Path $cfgPath) {
                try {
                    $old = Get-Content -Raw $cfgPath | ConvertFrom-Json
                    foreach ($p in $old.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
                } catch { }
            }
            $cfg["player_name"] = $Name
            [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Compress))
        }
        Say "racer name: $Name"
    }
} finally {
    Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}

Say ""
Say "One step left: Steam launch options (Steam stores these itself)."
Say "  Steam -> Library -> Hades II -> Properties -> General -> Launch Options, set:"
Say ""
Say "    $LaunchOptions"
Say ""
Say "  If there is already something there, keep it and add --rom_enabled true after %command%."
Say ""
Say "Then start Hades II and pick ""Play Competitive Speedrun"" on the title screen."
Say "Check it loaded: $Rom\LogOutput.log mentions ""$Guid""."

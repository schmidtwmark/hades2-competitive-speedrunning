<#
Update Ranked Race (Windows) in one command, with the game closed. In PowerShell:

  irm https://raw.githubusercontent.com/schmidtwmark/hades2-ranked-race/main/install/update.ps1 | iex

Downloads this repository's latest release (the main branch) to a temporary
folder and runs its installer, which keeps your racer name and settings.
#>
& {
    $ErrorActionPreference = "Stop"
    $ProgressPreference = "SilentlyContinue"
    $repo = "schmidtwmark/hades2-ranked-race"
    if (Get-Process -Name Hades2 -ErrorAction SilentlyContinue) {
        Write-Host "Hades II is running: quit the game, then run this again." -ForegroundColor Red
        return
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ranked-race-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Write-Host "Downloading the latest Ranked Race..."
        $zip = Join-Path $tmp "main.zip"
        Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/$repo/zip/refs/heads/main" -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $tmp
        $installer = Get-ChildItem -Path $tmp -Directory | ForEach-Object { Join-Path $_.FullName "install\install.ps1" } |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        # Its own process: the installer's errors exit it, not this window.
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installer
    } finally {
        Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue
    }
}

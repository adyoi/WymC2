# ios-builder setup for the WYM C2 server (Windows).
#
# Installs the MobAI ios-builder CLI (https://github.com/MobAI-App/ios-builder),
# authenticates it with GitHub and initializes the Actions workflow this repo
# needs so `POST /api/build/start` can produce iOS (.ipa) agents on a non-macOS
# server: ios-builder snapshots the working tree, builds on a GitHub macOS
# runner (free on public repos) and downloads the IPA to ./dist/.
$ErrorActionPreference = "Stop"

$installDir = Join-Path $env:LOCALAPPDATA "ios-builder"
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
$exe = Join-Path $installDir "builder.exe"

if (-not (Test-Path $exe)) {
    $url = "https://github.com/MobAI-App/ios-builder/releases/latest/download/builder-windows-amd64.exe"
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $exe
} else {
    Write-Host "builder already installed at $exe"
}

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$installDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$installDir", "User")
    Write-Host "Added $installDir to the user PATH (new shells only)"
}

# Token is stored in your OS credential store, never in the repo. Needs a GitHub
# token with `repo` + `workflow` scopes.
& $exe auth github

Write-Host "Initializing the ios-builder workflow (.github/workflows/ios-build.yml) ..."
& $exe init --ios-path clients/mobile/ios --scheme WymC2 --project WymC2

Write-Host "Done. The server auto-detects 'builder' on PATH; try an iOS build from the Generate Agent page."
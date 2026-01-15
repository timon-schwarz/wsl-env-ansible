param(
    [Parameter(Mandatory = $true)]
    [string]$ImagePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest  # optional but recommended

# Ensure script is run from repo root
$expectedPaths = @(
    "ansible.cfg",
    "playbooks",
    "roles",
    "windows\bootstrap.ps1"
)

foreach ($path in $expectedPaths) {
    if (-not (Test-Path $path)) {
        Write-Error "bootstrap.ps1 must be run from the repository root.`nHint: cd into the repo root and run:`n  powershell -ExecutionPolicy Bypass -File .\windows\bootstrap.ps1 -ImagePath <path-to-fedora.wsl>"
        exit 1
    }
}

Write-Host "Repo root check passed."
Write-Host "Proceeding with WSL distro setup..."

# -----------------------------
# Helpers
# -----------------------------
function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Get-ExistingDistros {
    # Returns distro names as strings (quiet list)
    & wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
}

function Assert-ImagePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "ImagePath is required."
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Fedora WSL image file not found: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) {
        throw "ImagePath points to a directory, not a file: $Path"
    }

    if ($item.Extension -ne ".wsl") {
        throw "ImagePath must point to a .wsl file: $Path"
    }

    if ($item.Length -le 0) {
        throw "Image file is empty: $Path"
    }
}

function Ensure-DistroImported([string]$DistroName, [string]$InstallDir, [string]$ImagePath) {
    $DistroName = $DistroName.Trim()
    if ([string]::IsNullOrWhiteSpace($DistroName)) { throw "DistroName is required." }
    if ([string]::IsNullOrWhiteSpace($InstallDir)) { throw "InstallDir is required." }

    $existing = Get-ExistingDistros
    if ($existing -contains $DistroName) {
        Write-Host "WSL distro already exists: $DistroName (skipping import)"
        return
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

    Write-Host "Importing distro: $DistroName"
    Write-Host "  InstallDir: $InstallDir"
    Write-Host "  Image:      $ImagePath"

    # Capture stderr/stdout to show helpful failure details without adding much complexity
    $out = & wsl.exe --import $DistroName $InstallDir $ImagePath --version 2 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = ($out | Out-String).Trim()
        if ($detail) {
            throw "wsl --import failed for $DistroName (exit code $LASTEXITCODE):`n$detail"
        }
        throw "wsl --import failed for $DistroName (exit code $LASTEXITCODE)."
    }
}

function Run-FedoraOobe([string]$DistroName) {
    Write-Host ""
    Write-Host "Running Fedora OOBE for $DistroName (this may prompt you to create a user)."
    Write-Host "If you have already completed OOBE for this distro, you can cancel safely."

    & wsl.exe -d $DistroName -u root -- /usr/libexec/wsl/oobe.sh

    # Don't hard-fail if user cancels; Fedora may already be configured.
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "OOBE returned non-zero exit code for $DistroName (exit code $LASTEXITCODE). If this distro already has a user, you can ignore this."
    }
}

function Start-Distro([string]$DistroName) {
    Write-Host "Starting $DistroName once..."
    & wsl.exe -d $DistroName -- bash -lc "true" 2>$null
}

function Convert-WindowsPathToWsl([string]$WindowsPath) {
    if ([string]::IsNullOrWhiteSpace($WindowsPath)) {
        throw "WindowsPath is required."
    }

    # wslpath expects a Windows path; use -a for absolute, -u for Unix output
    $wslPath = & wsl.exe wslpath -a -u -- "$WindowsPath" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wslPath)) {
        throw "Failed to convert Windows path to WSL path: $WindowsPath"
    }

    return $wslPath.Trim()
}

# -----------------------------
# Configuration
# -----------------------------
$DistroNames = @("fedora-work", "fedora-uni", "fedora-private")

$InstallBase = Join-Path $env:LOCALAPPDATA "WSL"
New-Item -ItemType Directory -Force -Path $InstallBase | Out-Null

# Where this repo lives on Windows (repo root)
$RepoRoot = (Get-Location).Path
$RepoRootWsl = Convert-WindowsPathToWsl -WindowsPath $RepoRoot

# -----------------------------
# Main
# -----------------------------
Assert-Command "wsl.exe"
Assert-ImagePath -Path $ImagePath

Write-Host "Using Fedora WSL image:"
Write-Host "  $ImagePath"

foreach ($distro in $DistroNames) {
    $installDir = Join-Path $InstallBase $distro
    Ensure-DistroImported -DistroName $distro -InstallDir $installDir -ImagePath $ImagePath

    Run-FedoraOobe -DistroName $distro
    Start-Distro -DistroName $distro
}

Write-Host ""
Write-Host "WSL distros ready."
Write-Host ""
Write-Host "Next steps: run the Linux-side setup inside each distro from this repo."
Write-Host "Run these commands (one per distro):"
foreach ($distro in $DistroNames) {
    $distroProfile = $distro.Replace("fedora-", "")
    Write-Host ""
    Write-Host ("wsl -d {0}" -f $distro)
    Write-Host ("cd `"{0}`"" -f $RepoRootWsl)
    Write-Host ("bash -lc `"./scripts/setup.sh {0}`"" -f $distroProfile)
}

Write-Host ""
Write-Host "Optional verification after setup:"
foreach ($distro in $DistroNames) {
    $distroProfile = $distro.Replace("fedora-", "")
    Write-Host ("wsl -d {0} -- bash -lc `"cd `"{1}`" && ./scripts/healthcheck.sh {2}`"" -f $distro, $RepoRootWsl, $distroProfile)
}

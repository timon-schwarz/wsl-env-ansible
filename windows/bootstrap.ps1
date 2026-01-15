param(
    [Parameter(Mandatory = $true)]
    [string]$ImagePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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
    & wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
}

function Assert-ImagePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "ImagePath is required." }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Fedora WSL image file not found: $Path" }

    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) { throw "ImagePath points to a directory, not a file: $Path" }
    if ($item.Extension -ne ".wsl") { throw "ImagePath must point to a .wsl file: $Path" }
    if ($item.Length -le 0) { throw "Image file is empty: $Path" }
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

    $out = & wsl.exe --import $DistroName $InstallDir $ImagePath --version 2 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = ($out | Out-String).Trim()
        if ($detail) { throw "wsl --import failed for $DistroName (exit code $LASTEXITCODE):`n$detail" }
        throw "wsl --import failed for $DistroName (exit code $LASTEXITCODE)."
    }
}

function Invoke-WslRoot([string]$DistroName, [string]$Command) {
    # Transport the command via base64 to avoid PowerShell/WSL quoting issues.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Command)
    $b64 = [Convert]::ToBase64String($bytes)

    $wrapped = "echo '$b64' | base64 -d | bash"
    $out = & wsl.exe -d $DistroName -u root -- bash -lc $wrapped 2>&1
    return ,$out
}

function Test-UserExists([string]$DistroName, [string]$Username) {
    $Username = $Username.Trim()
    if ([string]::IsNullOrWhiteSpace($Username)) { return $false }

    $out = Invoke-WslRoot -DistroName $DistroName -Command ("id -u {0} >/dev/null 2>&1; echo $?" -f $Username)
    $rc = ($out | Select-Object -Last 1).Trim()
    return ($rc -eq "0")
}

function Get-NonRootUsers([string]$DistroName) {
    # Returns usernames with UID >= 1000 using only shell built-ins
    $cmd = @'
while IFS=: read -r name _ uid _; do
  if [ "$uid" -ge 1000 ] && [ "$name" != "nobody" ]; then
    printf "%s\n" "$name"
  fi
done < /etc/passwd
'@
    $out = Invoke-WslRoot -DistroName $DistroName -Command $cmd

    # Force array output even when there is only one user
    return @(
        $out | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne "" }
    )
}

function Set-DefaultUserViaWslConf([string]$DistroName, [string]$Username) {
    Write-Host "Setting default user for $DistroName to '$Username' via /etc/wsl.conf ..."

    # Single-quoted here-string prevents PowerShell from expanding $f, $tmp, etc.
    $scriptBody = @'
set -euo pipefail
u="${WSL_DEFAULT_USER}"
f="/etc/wsl.conf"
tmp="/tmp/wsl.conf.$$"

# Create tmp fresh
: > "$tmp"

if [ -f "$f" ]; then
  in_user=0
  done=0

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "[user]")
        printf "%s\n" "$line" >> "$tmp"
        in_user=1
        continue
        ;;
      "["*"]")
        if [ "$in_user" -eq 1 ] && [ "$done" -eq 0 ]; then
          printf "default=%s\n" "$u" >> "$tmp"
          done=1
        fi
        in_user=0
        printf "%s\n" "$line" >> "$tmp"
        continue
        ;;
      default=*)
        if [ "$in_user" -eq 1 ]; then
          if [ "$done" -eq 0 ]; then
            printf "default=%s\n" "$u" >> "$tmp"
            done=1
          fi
          continue
        fi
        ;;
    esac
    printf "%s\n" "$line" >> "$tmp"
  done < "$f"

  if [ "$in_user" -eq 1 ] && [ "$done" -eq 0 ]; then
    printf "default=%s\n" "$u" >> "$tmp"
    done=1
  fi

  if [ "$done" -eq 0 ]; then
    printf "\n[user]\ndefault=%s\n" "$u" >> "$tmp"
  fi
else
  printf "[user]\ndefault=%s\n" "$u" > "$tmp"
fi

install -m 0644 "$tmp" "$f"
rm -f "$tmp"
'@

    # Prepend env var assignment as a literal line.
    # Use printf %q-style escaping? We keep it simple and reject unsafe usernames.
    if ($Username -notmatch '^[a-z_][a-z0-9_-]*$') {
        throw "Refusing to set default user: invalid username '$Username' (unexpected characters)."
    }

    $fullScript = "WSL_DEFAULT_USER=$Username`n" + $scriptBody

    $out = Invoke-WslRoot -DistroName $DistroName -Command $fullScript
    if ($LASTEXITCODE -ne 0) {
        $detail = ($out | Out-String).Trim()
        throw "Failed to set /etc/wsl.conf for ${DistroName}:`n$detail"
    }
}



function Run-FedoraOobe-Mandatory([string]$DistroName) {
    Write-Host ""
    Write-Host "Running Fedora OOBE for $DistroName (mandatory)."
    Write-Host "You must complete user creation when prompted."

    & wsl.exe -d $DistroName -u root -- /usr/libexec/wsl/oobe.sh
    $rc = $LASTEXITCODE

    # Determine whether OOBE produced at least one non-root user
    $users = Get-NonRootUsers -DistroName $DistroName
    $users = @($users)


    if ($rc -ne 0 -and ($users.Count -eq 0)) {
        throw "OOBE did not complete successfully for $DistroName and no non-root user was detected. Re-run and complete user creation."
    }

    if ($users.Count -eq 0) {
        throw "No non-root users detected after OOBE for $DistroName. OOBE must be completed."
    }

    Write-Host "OOBE completed for $DistroName. Detected non-root user(s): $($users -join ', ')"
}

function Start-Distro([string]$DistroName) {
    Write-Host "Starting $DistroName once..."
    & wsl.exe -d $DistroName -- bash -lc "true" 2>$null
}

function Convert-WindowsPathToWsl([string]$WindowsPath) {
    if ([string]::IsNullOrWhiteSpace($WindowsPath)) { throw "WindowsPath is required." }

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

    # 1) Mandatory OOBE
    Run-FedoraOobe-Mandatory -DistroName $distro

    # 2) Determine which non-root user to set as default
    $nonRootUsers = Get-NonRootUsers -DistroName $distro
    $nonRootUsers = @($nonRootUsers)  # normalize to array under StrictMode
    $defaultSuggestion = $nonRootUsers | Select-Object -First 1

    if ($nonRootUsers.Count -eq 1) {
        $username = $nonRootUsers[0]
        Write-Host "Exactly one non-root user detected for ${distro}: '$username' (auto-selected)"
    } else {
        Write-Host "Detected non-root user(s) for ${distro}: $($nonRootUsers -join ', ')"
        $username = Read-Host "Enter the username you want as default for ${distro} (suggested: $defaultSuggestion)"

        if (-not (Test-UserExists -DistroName $distro -Username $username)) {
            Write-Host "Username '$username' not found in ${distro}."
            $username = Read-Host "Re-enter a valid username for ${distro}"
            if (-not (Test-UserExists -DistroName $distro -Username $username)) {
                throw "Username '$username' still not found in ${distro}. Aborting."
            }
        }
    }


    # 3) Set default user via /etc/wsl.conf
    Set-DefaultUserViaWslConf -DistroName $distro -Username $username

    # 4) Restart the distro so WSL applies the new default user
    Write-Host "Terminating $distro to apply default user setting..."
    & wsl.exe -t $distro 2>$null | Out-Null

    # 5) Verify default user is no longer root
    $out = & wsl.exe -d $distro -- bash -lc "id -un" 2>&1
    $actualUser = ($out | Select-Object -Last 1).Trim()
    if ($actualUser -eq "root") {
        throw "Default user is still root for ${distro}. /etc/wsl.conf may not have been applied."
    }
    Write-Host "Default user verified for ${distro}: $actualUser"

    Start-Distro -DistroName $distro
}

Write-Host ""
Write-Host "WSL distros ready (OOBE completed and default user set)."
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

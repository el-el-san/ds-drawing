# requires -version 5.1
# install-msix.ps1
# - Auto-detect newest *.msix in the same folder
# - Extract signer certificate and add to TrustedPeople/Root (fallback to user stores)
# - Install/Update via Add-AppxPackage
# - Self-elevates to Administrator via UAC

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Admin {
  $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevating to administrator..." -ForegroundColor Yellow
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "powershell.exe"
    $psi.Arguments = "-ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`""
    $psi.Verb      = "runas"
    try {
      [Diagnostics.Process]::Start($psi) | Out-Null
    } catch {
      Write-Error "Elevation was cancelled."
    }
    exit
  }
}

Ensure-Admin

# Work in script folder
Set-Location -LiteralPath $PSScriptRoot

# Find newest MSIX (force array to avoid .Count issue)
$msixList = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.msix -File | Sort-Object LastWriteTime -Descending)
if (-not $msixList -or $msixList.Count -eq 0) { throw "No .msix found in this folder." }

$msix = $msixList[0]
Write-Host ("Target package: " + $msix.Name) -ForegroundColor Cyan

if ($msixList.Count -gt 1) {
  Write-Host "Multiple MSIX detected; using the newest one. Candidates:" -ForegroundColor DarkGray
  ($msixList | Select-Object LastWriteTime, Name | Format-Table | Out-String) | Write-Host
}

# Signature & certificate
$sig = Get-AuthenticodeSignature -FilePath $msix.FullName
if ($null -eq $sig.SignerCertificate) {
  throw "This MSIX is not signed. MSIX requires signing."
}
Write-Host ("Signature status: " + $sig.Status) -ForegroundColor DarkGray

$certOut = Join-Path $env:TEMP "publisher_from_msix.cer"
$sig.SignerCertificate | Export-Certificate -FilePath $certOut -Force | Out-Null
Write-Host ("Exported certificate to: " + $certOut) -ForegroundColor DarkGray

function Add-Cert([string]$store, [string]$path, [switch]$UserScope) {
  $args = @('certutil')
  if ($UserScope) { $args += '-user' }
  $args += @('-addstore','-f', $store, $path)
  $p = Start-Process -FilePath $args[0] -ArgumentList $args[1..($args.Length-1)] -NoNewWindow -PassThru -Wait
  if ($p.ExitCode -ne 0) { throw "Failed to add cert to store '$store'. ExitCode=$($p.ExitCode)" }
}

# Add to local computer stores; if blocked, fallback to user stores
try {
  Add-Cert -store "TrustedPeople" -path $certOut
  try {
    Add-Cert -store "Root" -path $certOut
  } catch {
    Write-Warning "Adding to 'Root' failed (policy). Continue with TrustedPeople only."
  }
} catch {
  Write-Warning ("Adding to local computer stores failed. Fallback to user stores... " + $_.Exception.Message)
  Add-Cert -store "TrustedPeople" -path $certOut -UserScope
  try {
    Add-Cert -store "Root" -path $certOut -UserScope
  } catch {
    Write-Warning ("Adding to user 'Root' also failed: " + $_.Exception.Message)
  }
}

# Install / Update
try {
  Write-Host "Installing / Updating..." -ForegroundColor Cyan
  Add-AppxPackage -Path $msix.FullName -ForceApplicationShutdown
  Write-Host "Done." -ForegroundColor Green
} catch {
  Write-Error ("Add-AppxPackage failed: " + $_.Exception.Message)
  Write-Host "Hints:" -ForegroundColor Yellow
  Write-Host "- If existing app Identity (Name/Publisher) differs, update won't work."
  Write-Host "- S mode or enterprise policy may block sideloaded MSIX."
  Write-Host "- If there are dependencies, use: Add-AppxPackage -DependencyPath <paths>"
  exit 1
}

<#
.SYNOPSIS
  Installiert die Agentendefinitionen unter Windows und weist nach, dass sie
  angekommen sind.

.DESCRIPTION
  Gleiches Verhalten wie scripts/install.sh: Der Installer blockiert nur, wenn
  das Paket selbst defekt ist -- nie wegen Dateien, die der Kunde angelegt hat.
  Gleiche Inhalte werden uebersprungen, geaenderte aktualisiert, fremde Dateien
  vorher gesichert. Am Ende wird jede Datei einzeln verifiziert.

  Exit-Codes
    0  alle erwarteten Agenten verifiziert
    1  Paketpruefung fehlgeschlagen (Paket defekt, nichts installiert)
    3  Installation unvollstaendig

.EXAMPLE
  .\scripts\install.ps1 -Project
#>

[CmdletBinding()]
param(
  [string]$Target,
  [switch]$Project,
  [switch]$User,
  # Bewusst nicht "-Profile": das ist in PowerShell eine automatische Variable.
  [string]$ProfilePath,
  [string]$Report,
  [switch]$DryRun,
  [switch]$Force,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir   = Split-Path -Parent $ScriptDir
$SourceDir = Join-Path $RepoDir 'agents'
$Expected  = 73
$Stamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

if (-not $Target) {
  if ($Project)  { $Target = Join-Path $RepoDir '.claude\agents' }
  elseif ($User) { $Target = Join-Path $HOME '.claude\agents' }
  else           { $Target = Join-Path $HOME '.claude\agents' }
}
if (-not $Report) { $Report = Join-Path $RepoDir '.claude\agent-install-report.json' }

function Write-Log  { param($Message) if (-not $Quiet) { Write-Host $Message } }
function Write-Warn { param($Message) Write-Warning $Message }

function Stop-BrokenPackage {
  Write-Error 'ABBRUCH: Das Paket selbst ist unvollstaendig oder inkonsistent. Es wurde nichts installiert.' -ErrorAction Continue
  exit 1
}

# --- Paketpruefung -----------------------------------------------------------

function Test-PackageFallback {
  $problems = 0
  $files = @(Get-ChildItem -Path $SourceDir -Filter '*.md' -File)
  if ($files.Count -ne $Expected) {
    Write-Host "- erwartet: $Expected Agentendateien, gefunden: $($files.Count)"
    $problems = 1
  }
  foreach ($file in $files) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    if (-not (Select-String -Path $file.FullName -Pattern "^name:\s*$stem\s*$" -Quiet)) {
      Write-Host "- Frontmatter passt nicht zum Dateinamen: $($file.Name)"
      $problems = 1
    }
  }
  if (-not (Test-Path (Join-Path $RepoDir 'config\agent-catalog.json'))) {
    Write-Host '- config/agent-catalog.json fehlt'
    $problems = 1
  }
  return $problems
}

$PreflightMode = 'python'
$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }

if ($python) {
  & $python.Source (Join-Path $ScriptDir 'validate_package.py') --mode preflight
  $rc = $LASTEXITCODE
  if ($rc -eq 1) { Stop-BrokenPackage }
  if ($rc -ne 0) {
    Write-Warn "Python ist vorhanden, konnte die Pruefung aber nicht ausfuehren (Exit $rc)."
    $PreflightMode = 'powershell-fallback'
    if ((Test-PackageFallback) -ne 0) { Stop-BrokenPackage }
  }
} else {
  Write-Warn 'Python wurde nicht gefunden. Es laeuft die eingebaute Basispruefung.'
  $PreflightMode = 'powershell-fallback'
  if ((Test-PackageFallback) -ne 0) { Stop-BrokenPackage }
  Write-Log "PREFLIGHT PASSED (Basispruefung): $Expected Agentendateien vorhanden"
}

# --- Installation ------------------------------------------------------------

Write-Log "Zielordner: $Target"
if ($DryRun) { Write-Log '(Probelauf - es wird nichts geschrieben)' }
if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $Target | Out-Null }

$new = 0; $updated = 0; $unchanged = 0; $backedUp = 0

foreach ($source in Get-ChildItem -Path $SourceDir -Filter '*.md' -File) {
  $targetFile = Join-Path $Target $source.Name
  $action = 'neu'

  if (Test-Path -LiteralPath $targetFile -PathType Leaf) {
    $same = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash
    if ($same) {
      $unchanged++
      if (-not $Quiet) { '  {0,-46} unveraendert' -f $source.Name | Write-Host }
      continue
    }
    $updated++
    $action = 'aktualisiert'
    if (-not $Force -and -not $DryRun) {
      try {
        Copy-Item -LiteralPath $targetFile -Destination "$targetFile.bak-$($Stamp -replace ':','')" -Force
        $backedUp++
        $action = 'aktualisiert (Backup angelegt)'
      } catch { }
    }
  } elseif (Test-Path -LiteralPath $targetFile) {
    $action = 'blockiert'
  } else {
    $new++
  }

  # Ein einzelner Fehlschlag darf den Lauf nicht beenden.
  if (-not $DryRun) {
    try {
      Copy-Item -LiteralPath $source.FullName -Destination $targetFile -Force
    } catch {
      $action = 'FEHLGESCHLAGEN'
      Write-Warn "konnte $($source.Name) nicht schreiben (Rechte oder Pfad pruefen)"
    }
  }
  if (-not $Quiet) { '  {0,-46} {1}' -f $source.Name, $action | Write-Host }
}

# --- Verifikation ------------------------------------------------------------

$verified = 0
$missing = @()
foreach ($source in Get-ChildItem -Path $SourceDir -Filter '*.md' -File) {
  if ($DryRun) { $verified++; continue }
  $targetFile = Join-Path $Target $source.Name
  $ok = $false
  if (Test-Path -LiteralPath $targetFile -PathType Leaf) {
    $ok = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash -eq
          (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash
  }
  if ($ok) { $verified++ } else { $missing += [IO.Path]::GetFileNameWithoutExtension($source.Name) }
}

# --- Profil ------------------------------------------------------------------

$profileStatus = 'nicht_angefordert'
if ($ProfilePath) {
  if ($DryRun) {
    $profileStatus = 'uebersprungen_probelauf'
  } elseif (-not $python) {
    $profileStatus = 'uebersprungen_kein_python'
    Write-Warn 'Profil konnte ohne Python nicht angewendet werden. Agenten sind trotzdem installiert.'
  } elseif (-not (Test-Path -LiteralPath $ProfilePath)) {
    $profileStatus = 'uebersprungen_profil_fehlt'
    Write-Warn "Profildatei nicht gefunden: $ProfilePath. Agenten sind trotzdem installiert."
  } else {
    & $python.Source (Join-Path $ScriptDir 'select_agents.py') --profile $ProfilePath `
      --output (Join-Path (Split-Path -Parent $Report) 'agent-activation.json')
    $profileStatus = if ($LASTEXITCODE -eq 0) { 'angewendet' } else { 'fehlgeschlagen' }
    if ($LASTEXITCODE -ne 0) { Write-Warn 'Profil konnte nicht angewendet werden. Agenten sind trotzdem installiert.' }
  }
}

# --- Bericht -----------------------------------------------------------------

if (-not $DryRun) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Report) | Out-Null
  [ordered]@{
    generated_at    = $Stamp
    target_dir      = $Target
    expected        = $Expected
    verified        = $verified
    complete        = ($verified -eq $Expected)
    missing         = $missing
    new             = $new
    updated         = $updated
    unchanged       = $unchanged
    backups_created = $backedUp
    preflight_mode  = $PreflightMode
    profile         = $ProfilePath
    profile_status  = $profileStatus
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Report -Encoding UTF8
}

# --- Ergebnis ----------------------------------------------------------------

Write-Log ''
Write-Log "neu: $new   aktualisiert: $updated   unveraendert: $unchanged   gesichert: $backedUp"

if ($DryRun) {
  Write-Host "Probelauf abgeschlossen: $Expected Agentendefinitionen wuerden nach $Target installiert."
  exit 0
}

Write-Log "Bericht: $Report"

if ($verified -eq $Expected) {
  Write-Host "OK: $verified/$Expected Agentendefinitionen installiert und verifiziert in $Target"
  exit 0
}

Write-Error "UNVOLLSTAENDIG: nur $verified/$Expected Agentendefinitionen verifiziert. Es fehlen: $($missing -join ', ')" -ErrorAction Continue
Write-Host "Bitte Schreibrechte auf $Target pruefen und install.ps1 erneut ausfuehren."
exit 3

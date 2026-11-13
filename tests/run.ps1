<#
  Lance tous les tests de FLOW (Pester 5).
    pwsh -File tests\run.ps1             # tous les tests
    pwsh -File tests\run.ps1 -Detail     # affiche le détail de chaque test
  Pester 5 est cherché dans les modules installés ; sinon il est téléchargé dans tests\.modules (rien n'est installé sur la machine).
#>
param([switch]$Detail)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$p5 = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $p5) {
    $mods = Join-Path $here '.modules'
    $local = Get-ChildItem (Join-Path $mods 'Pester') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $local) {
        Write-Host 'Pester 5 introuvable : téléchargement dans tests\.modules …'
        New-Item -ItemType Directory -Force $mods | Out-Null
        Save-Module -Name Pester -MinimumVersion 5.0 -Path $mods -Repository PSGallery -Force
        $local = Get-ChildItem (Join-Path $mods 'Pester') -Directory | Sort-Object Name -Descending | Select-Object -First 1
    }
    Import-Module (Join-Path $local.FullName 'Pester.psd1') -Force
} else { Import-Module $p5.Path -Force }

$cfg = New-PesterConfiguration
$cfg.Run.Path = $here
$cfg.Run.Exit = $true
$cfg.Output.Verbosity = if ($Detail) { 'Detailed' } else { 'Normal' }
Invoke-Pester -Configuration $cfg

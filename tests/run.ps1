<#
  Lance tous les tests de FLOW (Pester 5).
    pwsh -File tests\run.ps1             # tous les tests
    pwsh -File tests\run.ps1 -Detail     # affiche le détail de chaque test
  Pester : SÉRIE 5 uniquement (minimum et maximum déclarés dans dependances.json). Une installation de la série 5 est cherchée parmi
  les modules installés, puis dans tests\.modules ; sinon la dernière version 5 est téléchargée dans tests\.modules (rien n'est installé
  sur la machine). Les versions sont comparées comme des VERSIONS (5.10 après 5.9). Même règle en local et dans la CI.
#>
param([switch]$Detail)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path (Split-Path $here -Parent) 'tools\flow-deps.ps1')
$dep = Get-FlowDep -Id 'pester'

$found = $null
$global = @(Get-Module -ListAvailable -Name Pester | Where-Object { Select-DepVersion @("$($_.Version)") $dep })
if ($global.Count) {
    $best = Select-DepVersion @($global | ForEach-Object { "$($_.Version)" }) $dep
    $found = ($global | Where-Object { "$($_.Version)" -eq $best } | Select-Object -First 1).Path
}
$mods = Join-Path $here '.modules'
if (-not $found) {
    $dirs = @(Get-ChildItem (Join-Path $mods 'Pester') -Directory -ErrorAction SilentlyContinue)
    $best = Select-DepVersion @($dirs | ForEach-Object { $_.Name }) $dep
    if ($best) { $found = Join-Path (Join-Path (Join-Path $mods 'Pester') $best) 'Pester.psd1' }
}
if (-not $found) {
    Write-Host "Pester $($dep.min) à $($dep.max) introuvable : téléchargement dans tests\.modules …"
    New-Item -ItemType Directory -Force $mods | Out-Null
    Save-Module -Name Pester -MinimumVersion $dep.min -MaximumVersion $dep.max -Path $mods -Repository PSGallery -Force
    $dirs = @(Get-ChildItem (Join-Path $mods 'Pester') -Directory)
    $best = Select-DepVersion @($dirs | ForEach-Object { $_.Name }) $dep
    if (-not $best) { throw "aucun Pester de la série $($dep.min) – $($dep.max) après téléchargement" }
    $found = Join-Path (Join-Path (Join-Path $mods 'Pester') $best) 'Pester.psd1'
}
Import-Module $found -Force
$loaded = Get-Module Pester
if (-not (Select-DepVersion @("$($loaded.Version)") $dep)) { throw "Pester $($loaded.Version) chargé, mais FLOW demande la série $($dep.min) à $($dep.max) (dependances.json)" }
Write-Host "Pester $($loaded.Version)" -ForegroundColor DarkGray

$pesterCfg = New-PesterConfiguration
$pesterCfg.Run.Path = $here
$pesterCfg.Run.Exit = $true
$pesterCfg.Output.Verbosity = if ($Detail) { 'Detailed' } else { 'Normal' }
Invoke-Pester -Configuration $pesterCfg
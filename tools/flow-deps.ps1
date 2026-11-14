# flow-deps.ps1 - lecture de dependances.json : la liste UNIQUE des dependances de FLOW.
# Charge avec « . » par install.ps1 (Windows PowerShell 5.1 ET PowerShell 7), FLOW.ps1, le diagnostic, les outils et les tests.
# Ce fichier est enregistre en UTF-8 AVEC BOM : Windows PowerShell 5.1 le lit sinon comme de l'ANSI (accents abimes).
# Syntaxe volontairement compatible 5.1 : ni ?? ni ?. ni ternaire ni && ni ||.
#
#   pwsh -File tools\flow-deps.ps1 -UpdateReadme     regenere le tableau des dependances du README
#   pwsh -File tools\flow-deps.ps1 -Markdown         affiche ce tableau
param([switch]$UpdateReadme, [switch]$Markdown)

function Get-DepsFilePath {
    if ($env:FLOW_DEPS_FILE) { return $env:FLOW_DEPS_FILE }
    Join-Path (Split-Path -Parent $PSScriptRoot) 'dependances.json'
}

function Get-FlowDeps {
    param([string]$File)
    if (-not $File) { $File = Get-DepsFilePath }
    $j = Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json
    @($j.dependances)
}

function Get-FlowDep {
    param([Parameter(Mandatory)][string]$Id, [string]$File)
    Get-FlowDeps -File $File | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}

# ---------- versions ----------
function ConvertTo-DepVersion([string]$text) {
    # « 2.56.0.windows.4 » -> 2.56.0 ; « 2.17 » -> 2.17.0 ; $null si aucun numero
    if (-not $text) { return $null }
    $m = [regex]::Match($text, '(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $m.Success) { return $null }
    $patch = '0'
    if ($m.Groups[3].Success) { $patch = $m.Groups[3].Value }
    [version]("$($m.Groups[1].Value).$($m.Groups[2].Value).$patch")
}

function Compare-DepVersion($a, $b) {
    # compare comme des VERSIONS (5.10 apres 5.9), pas comme du texte : -1, 0 ou 1
    $x = ConvertTo-DepVersion "$a"; $y = ConvertTo-DepVersion "$b"
    if ($null -eq $x -or $null -eq $y) { throw "version illisible : '$a' ou '$b'" }
    $x.CompareTo($y)
}

# ---------- recherche reelle ----------
function Resolve-DepPath($d) {
    $c = Get-Command $d.commande -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { if ($c.Source) { return [string]$c.Source } else { return [string]$c.Name } }
    foreach ($p in @($d.chemins)) {
        if (-not $p) { continue }
        $x = [Environment]::ExpandEnvironmentVariables([string]$p)
        if (Test-Path -LiteralPath $x) { return $x }
    }
    $null
}

function Read-DepVersion($d, [string]$path) {
    if (-not $d.version -or -not $d.version.args) { return $null }
    try {
        $out = (& $path @($d.version.args) 2>&1 | Out-String)
        $m = [regex]::Match($out, [string]$d.version.motif)
        if ($m.Success) { $v = ConvertTo-DepVersion $m.Groups[1].Value; if ($v) { return $v.ToString() } }
    } catch {}
    $null
}

function Invoke-DepProbe($d) {
    # ce que la machine a vraiment : @{ Path ; Versions }
    if ($d.type -eq 'module') {
        $vs = @(); $where = $null
        foreach ($m in @(Get-Module -ListAvailable -Name $d.commande -ErrorAction SilentlyContinue)) { $vs += "$($m.Version)"; $where = $m.Path }
        $local = Join-Path (Join-Path (Split-Path -Parent (Get-DepsFilePath)) 'tests\.modules') $d.commande
        foreach ($dir in @(Get-ChildItem -LiteralPath $local -Directory -ErrorAction SilentlyContinue)) {
            if (ConvertTo-DepVersion $dir.Name) { $vs += $dir.Name; $where = $dir.FullName }
        }
        return @{ Path = $where; Versions = @($vs) }
    }
    $p = Resolve-DepPath $d
    if (-not $p) { return @{ Path = $null; Versions = @() } }
    $v = Read-DepVersion $d $p
    $list = @()
    if ($v) { $list = @($v) }
    @{ Path = $p; Versions = $list }
}

function Select-DepVersion {
    # la version la plus haute qui respecte min et max (comparaison de VERSIONS : 5.10 apres 5.9) ; $null s'il n'y en a pas
    param($Versions, $Dep)
    $fit = @(@($Versions) | Where-Object {
            $_ -and (ConvertTo-DepVersion "$_") -and
            ((-not $Dep.min) -or (Compare-DepVersion $_ $Dep.min) -ge 0) -and ((-not $Dep.max) -or (Compare-DepVersion $_ $Dep.max) -le 0)
        } | Sort-Object { ConvertTo-DepVersion "$_" } -Descending)
    if ($fit.Count) { return "$($fit[0])" }
    $null
}

function Get-DepState {
    # Statut : absent | ancienne | trop-recente | inconnue (presente, version illisible) | ok
    param([Parameter(Mandatory)]$Dep, [scriptblock]$Probe)
    if (-not $Probe) { $Probe = { param($x) Invoke-DepProbe $x } }
    $pr = & $Probe $Dep
    $versions = @(@($pr.Versions) | Where-Object { $_ -and (ConvertTo-DepVersion "$_") })
    $present = [bool]$pr.Path -or ($versions.Count -gt 0)
    $found = $null; $status = 'ok'
    if (-not $present) { $status = 'absent' }
    elseif ($versions.Count) {
        $found = Select-DepVersion $versions $Dep
        if (-not $found) {
            $found = "$(@($versions | Sort-Object { ConvertTo-DepVersion "$_" } -Descending)[0])"
            if ($Dep.max -and (Compare-DepVersion $found $Dep.max) -gt 0) { $status = 'trop-recente' } else { $status = 'ancienne' }
        }
    }
    elseif ($Dep.min -or $Dep.max) { $status = 'inconnue' }
    [pscustomobject]@{
        Id = $Dep.id; Nom = $Dep.nom; Obligatoire = [bool]$Dep.obligatoire; Quand = "$($Dep.quand)"
        Present = $present; Chemin = $pr.Path; Version = $found; Statut = $status
        Min = $Dep.min; Max = $Dep.max; Testee = $Dep.testee
    }
}

# ---------- messages ----------
function Get-DepInstallCommand($d) {
    if ($d.winget) { return "winget install --id $($d.winget) -e" }
    if ($d.installation) { return [string]$d.installation }
    ''
}
function Get-DepUpgradeCommand($d) {
    if ($d.winget) { return "winget upgrade --id $($d.winget) -e" }
    if ($d.installation) { return [string]$d.installation }
    ''
}

function Get-DepMessage {
    # une phrase : ce qui se passe, la version trouvee et attendue, la commande qui regle le probleme
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Dep)
    $n = $Dep.nom
    switch ($State.Statut) {
        'absent' {
            $how = Get-DepInstallCommand $Dep
            if ($Dep.winget) { return "$n est introuvable ($($Dep.role)). Pour l'installer : $how (ou double-clique sur install.cmd)." }
            return "$n est introuvable ($($Dep.role)). $how."
        }
        'ancienne' {
            $t = ''
            if ($Dep.testee) { $t = " (essayé avec $($Dep.testee))" }
            return "$n $($State.Version) est trop ancien : FLOW demande $($Dep.min) ou plus$t. Mise à jour : $(Get-DepUpgradeCommand $Dep)."
        }
        'trop-recente' { return "$n $($State.Version) est plus récent que la série prise en charge (jusqu'à $($Dep.max)). $(Get-DepInstallCommand $Dep)." }
        'inconnue' { return "$n est présent mais sa version n'a pas pu être lue (FLOW demande $($Dep.min) ou plus) : vérifie-la à la main." }
        default {
            $v = ''
            if ($State.Version) { $v = " $($State.Version)" }
            return "$n$v"
        }
    }
}

function Get-DepMissingText {
    # pour les messages « X est introuvable » des autres scripts : jamais d'identifiant recopie
    param([Parameter(Mandatory)][string]$Id)
    try {
        $d = Get-FlowDep -Id $Id
        if (-not $d) { return "$Id est introuvable." }
        $st = [pscustomobject]@{ Statut = 'absent' }
        return (Get-DepMessage -State $st -Dep $d)
    } catch { return "$Id est introuvable : double-clique sur install.cmd." }
}

# ---------- verdict de l'installation ----------
function Get-DepsVerdict {
    # Ready : vrai SEULEMENT si toutes les dependances obligatoires sont la, a la bonne version
    param([Parameter(Mandatory)]$States)
    $req = @($States | Where-Object { $_.Obligatoire })
    $bad = @($req | Where-Object { $_.Statut -in 'absent', 'ancienne', 'trop-recente' })
    [pscustomobject]@{
        Ready = ($bad.Count -eq 0)
        Missing = @($req | Where-Object { $_.Statut -eq 'absent' })
        Old = @($req | Where-Object { $_.Statut -in 'ancienne', 'trop-recente' })
        Unknown = @($req | Where-Object { $_.Statut -eq 'inconnue' })
        Optional = @($States | Where-Object { -not $_.Obligatoire -and $_.Statut -ne 'ok' })
    }
}

function Update-SessionPath {
    # apres une installation : COMPLETE le PATH de la fenetre avec celui de Windows (sans retirer ce qu'elle avait deja)
    $seen = @{}; $parts = @()
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine'); $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    foreach ($p in @(($env:Path -split ';') + ($m -split ';') + ($u -split ';'))) {
        $k = "$p".Trim().TrimEnd('\').ToLower()
        if ($k -and -not $seen.ContainsKey($k)) { $seen[$k] = 1; $parts += "$p".Trim() }
    }
    $env:Path = $parts -join ';'
}

# ---------- tableau du README ----------
function Get-DepsMarkdown {
    param([string]$File)
    $rows = @('| Outil | Nécessaire | À quoi il sert | Version minimale |', '|---|---|---|---|')
    foreach ($d in @(Get-FlowDeps -File $File)) {
        $need = 'facultatif'
        if ($d.obligatoire) { $need = 'oui' } elseif ($d.quand) { $need = "non : $($d.quand)" }
        $min = '-'
        if ($d.min -and $d.max) { $min = "série $($d.min -replace '\.\d+$', '') uniquement" }
        elseif ($d.min) { $min = "$($d.min) (essayé avec $($d.testee))" }
        elseif ($d.testee) { $min = "aucune (essayé avec $($d.testee))" }
        $rows += "| $($d.nom) | $need | $($d.role -replace '\|', '/') | $min |"
    }
    $rows -join "`n"
}

function Update-ReadmeDeps {
    param([string]$Readme, [string]$File)
    $text = [IO.File]::ReadAllText($Readme).Replace("`r`n", "`n")
    $a = '<!-- DEPENDANCES:DEBUT -->'; $z = '<!-- DEPENDANCES:FIN -->'
    $i = $text.IndexOf($a); $j = $text.IndexOf($z)
    if ($i -lt 0 -or $j -lt $i) { throw "marqueurs $a / $z introuvables dans $Readme" }
    $new = $text.Substring(0, $i + $a.Length) + "`n" + (Get-DepsMarkdown -File $File) + "`n" + $text.Substring($j)
    [IO.File]::WriteAllText($Readme, $new, (New-Object System.Text.UTF8Encoding($false)))
}

if ($UpdateReadme) { Update-ReadmeDeps -Readme (Join-Path (Split-Path -Parent $PSScriptRoot) 'README.md'); Write-Host 'README.md : tableau des dépendances mis à jour' }
elseif ($Markdown) { Get-DepsMarkdown }

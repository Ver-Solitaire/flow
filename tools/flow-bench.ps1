#Requires -Version 7
<#
  flow-bench.ps1 - banc de mesure de la qualité : de petites tâches fixes (bench\taches.json), chacune avec des vérifications
  automatiques ; un vrai Claude travaille dans une copie jetable, FLOW compte les vérifications réussies, le coût et la durée,
  et ajoute une ligne à bench\resultats.jsonl pour comparer une version de FLOW à l'autre.

    pwsh -File tools\flow-bench.ps1 -Live                    toutes les tâches (appelle Claude : coûte de l'argent)
    pwsh -File tools\flow-bench.ps1 -Live -Taches renommer   une seule
    pwsh -File tools\flow-bench.ps1 -Resume                  compare les derniers résultats, sans appeler Claude
#>
param([switch]$Live, [string[]]$Taches, [string]$Modele = 'sonnet', [switch]$Resume, [string]$Fichier, [string]$Sortie, [switch]$LoadOnly)
$BenchRoot = Split-Path $PSScriptRoot -Parent
if (-not $Fichier) { $Fichier = Join-Path $BenchRoot 'bench\taches.json' }
if (-not $Sortie) { $Sortie = Join-Path $BenchRoot 'bench\resultats.jsonl' }

function Bench-Load([string]$f) { @((Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json).taches) }

function Bench-Version { $v = Join-Path $BenchRoot 'VERSION'; if (Test-Path $v) { (Get-Content $v -Raw).Trim() } else { '?' } }

function New-BenchDir($tache) {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('flowbench-' + $tache.id + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Force $d | Out-Null
    foreach ($p in $tache.fichiers.PSObject.Properties) { [IO.File]::WriteAllText((Join-Path $d $p.Name), ([string]$p.Value).Replace('\n', "`n"), [Text.UTF8Encoding]::new($false)) }
    $d
}

function Run-BenchChecks($tache, [string]$dir) {
    # chaque vérification : un script PowerShell lancé dans le dossier, code de sortie 0 = réussie
    $out = @()
    foreach ($v in @($tache.verifications)) {
        $ok = $false
        Push-Location $dir
        try { [void](& pwsh -NoProfile -Command $v.script 2>&1); $ok = ($LASTEXITCODE -eq 0) } catch {} finally { Pop-Location }
        $out += [pscustomobject]@{ nom = $v.nom; ok = $ok }
    }
    $out
}

function Invoke-BenchClaude([string]$dir, [string]$demande, [string]$modele) {
    # le vrai Claude ; renvoie @{ Cout; DureeMs; Erreur }
    $raw = & claude -p $demande --model $modele --output-format json --permission-mode bypassPermissions --add-dir $dir 2>&1 | Out-String
    $r = @{ Cout = 0.0; DureeMs = 0; Erreur = '' }
    try {
        $j = $raw | ConvertFrom-Json
        $r.Cout = [double]$j.total_cost_usd; $r.DureeMs = [int]$j.duration_ms
        if ($j.is_error) { $r.Erreur = "$($j.result)" }
    } catch { $r.Erreur = 'réponse illisible : ' + $raw.Substring(0, [Math]::Min(200, $raw.Length)) }
    $r
}

function Run-BenchTask($tache, [string]$modele, [scriptblock]$Runner) {
    $dir = New-BenchDir $tache
    try {
        $t0 = Get-Date
        $res = if ($Runner) { & $Runner $dir $tache.demande $modele } else { Push-Location $dir; try { Invoke-BenchClaude $dir $tache.demande $modele } finally { Pop-Location } }
        $chk = @(Run-BenchChecks $tache $dir)
        [pscustomobject]@{
            tache = $tache.id; reussies = @($chk | Where-Object ok).Count; total = $chk.Count; details = $chk
            cout = [Math]::Round([double]$res.Cout, 4); duree_s = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1); erreur = "$($res.Erreur)"
        }
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Run-Bench {
    param([string[]]$Ids, [string]$Modele = 'sonnet', [scriptblock]$Runner)
    $all = Bench-Load $Fichier
    if ($Ids) { $all = @($all | Where-Object { $_.id -in $Ids }) }
    $rows = @(); foreach ($t in $all) { $rows += Run-BenchTask $t $Modele $Runner }
    $run = [pscustomobject]@{
        date = (Get-Date).ToString('o'); version = (Bench-Version); modele = $Modele
        reussies = (@($rows | ForEach-Object { $_.reussies }) | Measure-Object -Sum).Sum; total = (@($rows | ForEach-Object { $_.total }) | Measure-Object -Sum).Sum
        cout = [Math]::Round((@($rows | ForEach-Object { $_.cout }) | Measure-Object -Sum).Sum, 4); taches = $rows
    }
    New-Item -ItemType Directory -Force (Split-Path $Sortie) | Out-Null
    Add-Content -LiteralPath $Sortie -Value ($run | ConvertTo-Json -Depth 6 -Compress) -Encoding utf8
    $run
}

function Show-BenchResume {
    if (-not (Test-Path -LiteralPath $Sortie)) { Write-Host '  Aucun résultat pour l''instant : lance le banc avec -Live.'; return }
    $runs = @(Get-Content -LiteralPath $Sortie -Encoding utf8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) | Select-Object -Last 8
    Write-Host ''; Write-Host '  date             version  modèle   réussi      coût'
    $prev = $null
    foreach ($r in $runs) {
        $d = ([datetime]$r.date).ToString('dd/MM HH:mm')
        $trend = if ($prev -and $r.total -eq $prev.total) { if ($r.reussies -gt $prev.reussies) { '▲' } elseif ($r.reussies -lt $prev.reussies) { '▼ régression' } else { '=' } } else { '' }
        '  {0,-16} {1,-8} {2,-8} {3,3}/{4,-3} {5,8}$  {6}' -f $d, $r.version, $r.modele, $r.reussies, $r.total, $r.cout, $trend | Write-Host
        $prev = $r
    }
}

if ($LoadOnly) { return }
if ($Resume -or -not $Live) { Show-BenchResume; if (-not $Live) { if (-not $Resume) { Write-Host ''; Write-Host '  (pour mesurer : -Live ; cela appelle Claude et coûte quelques centimes par tâche)' } }; if (-not $Live) { return } }
$r = Run-Bench -Ids $Taches -Modele $Modele
Write-Host ''; Write-Host "  FLOW $($r.version) · $($r.modele) : $($r.reussies)/$($r.total) vérifications réussies · $($r.cout)$"
foreach ($t in $r.taches) { Write-Host ("   {0,-18} {1}/{2}  {3}s  {4}$ {5}" -f $t.tache, $t.reussies, $t.total, $t.duree_s, $t.cout, $(if ($t.erreur) { '⚠ ' + $t.erreur })) }
Show-BenchResume
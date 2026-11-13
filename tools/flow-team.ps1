<#
  flow-team.ps1 — fenêtre « Équipe » de FLOW.

  Un prompt → un plan (un Claude planificateur) → plusieurs Claude « ouvriers » en parallèle,
  répartis sur les comptes Claude, chacun dans sa propre copie du dépôt (git worktree, branche dédiée).
  Quand tout est fini : fusion dans une branche d'intégration, tests, puis fusion dans ta branche
  UNIQUEMENT après ta validation.

  Tableau partagé de l'équipe : <dépôt>\.flow\runs\<id>\  (BRIEF.md, taches\, resultats\, state.json)
  Copies de travail          : <dossier parent>\<dépôt>-flow\<id>\<tâche>\

  Lancé par FLOW (rôle de panneau « team ») :
    pwsh -File flow-team.ps1 -Repo C:\projet -Sock flow -Session flow-equipe -Accounts 'principal|Compte 1|ff8a5c||C1;second|Compte 2|54baff|C:\Users\moi\.claude-compte2|C2'
#>
param(
    [string]$Repo = (Get-Location).Path,
    [string]$Sock,
    [string]$Session,
    [string]$Accounts,            # id|libellé|couleur|CLAUDE_CONFIG_DIR (vide = ~\.claude)|nom court ; …
    [int]$MaxTasks = 4,
    [string]$TestCommand,         # commande de test lancée sur la branche d'intégration (sinon détectée)
    [string]$WorkerArgs = '--permission-mode acceptEdits',  # chaque ouvrier est isolé dans son worktree
    [switch]$NoReview,            # sans relecture croisée (par défaut : chaque tâche finie est relue par un autre compte)
    [int]$MaxReviews = 2,         # nombre maximal de relectures par tâche
    [switch]$LoadOnly             # charge les fonctions sans lancer l'écran (tests)
)

[Console]::OutputEncoding = [Text.Encoding]::UTF8
foreach ($v in 'NO_COLOR') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
if ($PSStyle) { $PSStyle.OutputRendering = 'Ansi' }

# ───────────────────────── affichage ─────────────────────────
$e = [char]27
$R = "$e[0m"; $B = "$e[1m"; $Dm = "$e[2m"
$ansiRx = "$e\[[0-9;]*m"
$Pal = @(@(255,138,92), @(255,94,158), @(168,112,255), @(84,186,255), @(96,232,196))
function Rgb([int]$rr, [int]$gg, [int]$bb) { "$e[38;2;$rr;$gg;$($bb)m" }
function RgbA($c) { Rgb $c[0] $c[1] $c[2] }
function PalC([double]$t) {
    $t -= [Math]::Floor($t); $x = $t * $Pal.Count; $i = [int][Math]::Floor($x) % $Pal.Count
    $a = $Pal[$i]; $z = $Pal[($i + 1) % $Pal.Count]; $f = $x - [Math]::Floor($x)
    Rgb ([int]($a[0] + ($z[0] - $a[0]) * $f)) ([int]($a[1] + ($z[1] - $a[1]) * $f)) ([int]($a[2] + ($z[2] - $a[2]) * $f))
}
function Grad([string]$s, [double]$ph) {
    $sb = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt $s.Length; $i++) { if ($s[$i] -eq ' ') { [void]$sb.Append(' ') } else { [void]$sb.Append((PalC ($ph + $i * 0.03))).Append($s[$i]) } }
    [void]$sb.Append($R); $sb.ToString()
}
function VisLen([string]$s) { ($s -replace $ansiRx, '').Length }
function Fit([string]$s, [int]$w) {
    $vl = VisLen $s
    if ($vl -le $w) { return $s + (' ' * ($w - $vl)) }
    $sb = [Text.StringBuilder]::new(); $vis = 0; $i = 0
    while ($i -lt $s.Length -and $vis -lt $w - 1) {
        if ($s[$i] -eq $e) { $j = $s.IndexOf('m', $i); [void]$sb.Append($s.Substring($i, $j - $i + 1)); $i = $j + 1; continue }
        [void]$sb.Append($s[$i]); $vis++; $i++
    }
    [void]$sb.Append("…$R"); $sb.ToString()
}
function ConW { try { $w = [Console]::WindowWidth; if ($w -gt 0) { return $w } } catch {}; 100 }
function ConH { try { $h = [Console]::WindowHeight; if ($h -gt 0) { return $h } } catch {}; 40 }
function Chunks([string]$s, [int]$w) {
    # coupe un texte brut en lignes de largeur w (sur les espaces si possible)
    $out = @()
    foreach ($para in ("$s" -split "`r?`n")) {
        $p = $para
        if (-not $p) { $out += ''; continue }
        while ($p.Length -gt $w) {
            $cut = $p.LastIndexOf(' ', [Math]::Min($w, $p.Length - 1))
            if ($cut -lt $w / 3) { $cut = $w }
            $out += $p.Substring(0, $cut).TrimEnd(); $p = $p.Substring($cut).TrimStart()
        }
        $out += $p
    }
    $out
}
$Ok = Rgb 120 230 140; $Err = Rgb 255 110 90; $Info = Rgb 120 200 255; $Warn = Rgb 255 210 110; $Teal = Rgb 96 232 196
$KeyPairs = [Collections.Generic.List[string]]::new()   # aides affichées dans l'image en cours (rendues cliquables)
function Key([string]$k, [string]$t) { $KeyPairs.Add("$k|$t"); "$B$Warn$k$R $Dm$t$R" }
function Keys([string[]]$pairs) { $o = @(); for ($i = 0; $i -lt $pairs.Count; $i += 2) { $o += Key $pairs[$i] $pairs[$i + 1] }; '  ' + ($o -join '   ') }
$LastFrameSize = ''
function Show-Frame($lines) {
    $W = [Math]::Max(40, (ConW) - 1); $H = [Math]::Max(6, (ConH))
    # fenêtre redimensionnée : tout effacer, sinon des morceaux de l'ancienne image restent à l'écran
    $sz = "$(ConW)x$(ConH)"
    if ($sz -ne $script:LastFrameSize) { [Console]::Write("$e[2J"); $script:LastFrameSize = $sz }
    $sb = [Text.StringBuilder]::new(); [void]$sb.Append("$e[H")
    for ($i = 0; $i -lt $H - 1; $i++) {
        $line = if ($i -lt $lines.Count) { $lines[$i] } else { '' }
        [void]$sb.Append((Fit $line $W)).Append($R).Append("$e[K`n")
    }
    [Console]::Write($sb.ToString())
    # zones cliquables : les aides du bas (« Entrée lancer », « M modèle »…) ; les écrans ajoutent les leurs ensuite
    Clear-Zones
    $map = @{}
    foreach ($kp in $KeyPairs) { $kk, $tt = $kp -split '\|', 2; $hn = Hint-FromLabel $kk; if ($hn) { $map["$kk $tt"] = $hn } }
    Add-HintZones $lines $map
    $KeyPairs.Clear()
}
function Cls { [Console]::Write("$e[?25l$e[2J") }
$Spin = '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'
$Tick = 0


function Notify([string]$title, [string]$text) {
    $ico = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\assets\flow.ico'))
    $cmd = "Add-Type -AssemblyName System.Windows.Forms, System.Drawing; " +
        "`$n = [System.Windows.Forms.NotifyIcon]::new(); " +
        "`$n.Icon = if (Test-Path -LiteralPath $(Q $ico)) { [System.Drawing.Icon]::new($(Q $ico)) } else { [System.Drawing.SystemIcons]::Information }; " +
        "`$n.Text = 'FLOW'; `$n.Visible = `$true; " +
        "`$n.ShowBalloonTip(6000, $(Q $title), $(Q $text), [System.Windows.Forms.ToolTipIcon]::Info); Start-Sleep -Seconds 8; `$n.Dispose()"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    try { Start-Process pwsh -WindowStyle Hidden -ArgumentList @('-NoProfile', '-EncodedCommand', $enc) } catch {}
}

# ───────────────────────── git ─────────────────────────
function Find-Git {
    $g = (Get-Command git -ErrorAction SilentlyContinue).Source
    if ($g) { return $g }
    foreach ($c in @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $null
}
$GitExe = Find-Git
. (Join-Path $PSScriptRoot 'flow-input.ps1')   # clavier + souris (clics)
. (Join-Path $PSScriptRoot 'flow-common.ps1')  # écritures atomiques, Q, journal
. (Join-Path $PSScriptRoot 'flow-claudemd.ps1')  # création d'un CLAUDE.md de départ
$global:FlowLogFile = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\config\flow.log'))
$GitId = @()
$GitCode = 0
function Git-In([string]$dir, [string[]]$a) {
    $o = & $GitExe @GitId -C $dir @a 2>&1 | ForEach-Object { "$_" }
    $script:GitCode = $LASTEXITCODE
    @($o)
}
function Init-GitId {
    # identité de commit : celle de l'utilisateur, sinon « FLOW » (sans toucher à sa configuration)
    if (-not $GitExe) { return }
    $mail = & $GitExe config user.email 2>$null
    $script:GitId = if ($mail) { @() } else { @('-c', 'user.name=FLOW', '-c', 'user.email=flow@localhost') }
}
Init-GitId

# ───────────────────────── comptes ─────────────────────────
function HexRgb([string]$h) {
    $h = "$h".TrimStart('#')
    if ($h -notmatch '^[0-9a-fA-F]{6}$') { return @(255, 138, 92) }
    @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}
function Parse-Accounts {
    $list = [Collections.Generic.List[object]]::new()
    foreach ($ent in ("$Accounts" -split ';')) {
        if (-not $ent.Trim()) { continue }
        $f = $ent -split '\|', 5
        $dir = if ($f.Count -gt 3) { $f[3].Trim() } else { '' }
        $list.Add([pscustomobject]@{
                Id = $f[0].Trim()
                Label = $(if ($f.Count -gt 1 -and $f[1].Trim()) { $f[1].Trim() } else { $f[0].Trim() })
                Rgb = (HexRgb $(if ($f.Count -gt 2) { $f[2] } else { '' }))
                Dir = $dir
                Home = $(if ($dir) { $dir } else { Join-Path $HOME '.claude' })
                Short = $(if ($f.Count -gt 4 -and $f[4].Trim()) { $f[4].Trim() } else { $f[0].Trim() })
            })
    }
    if (-not $list.Count) {
        $list.Add([pscustomobject]@{ Id = 'principal'; Label = 'Claude'; Rgb = @(255, 138, 92); Dir = ''; Home = (Join-Path $HOME '.claude'); Short = 'C1' })
    }
    , $list
}
$Accs = Parse-Accounts
function Acct-ById([string]$id) { $Accs | Where-Object { $_.Id -eq $id } | Select-Object -First 1 }
function Acct-Logged($a) { Test-Path -LiteralPath (Join-Path $a.Home '.credentials.json') }
function Acct-Load($a) {
    # % de la limite la plus remplie (semaine ou session), d'après la barre de statut
    try { $d = Get-Content -LiteralPath (Join-Path $a.Home 'monitor-status.json') -Raw | ConvertFrom-Json } catch { return 0 }
    $v = 0.0
    foreach ($w in @($d.rate_limits.seven_day, $d.rate_limits.five_hour)) { if ($w -and [double]$w.used_percentage -gt $v) { $v = [double]$w.used_percentage } }
    $v
}
function Acct-Env($a) {
    (Auth-Strip) + $(if ($a -and $a.Dir) { "`$env:CLAUDE_CONFIG_DIR = $(Q $a.Dir); " } else { "Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue; " })
}
function Usable-Accounts {
    $u = @($Accs | Where-Object { Acct-Logged $_ })
    if (-not $u.Count) { $u = @($Accs) }
    $u
}
function Least-Loaded {
    Usable-Accounts | Sort-Object { Acct-Load $_ } | Select-Object -First 1
}
function Assign-Accounts($tasks) {
    # répartition : chaque tâche va au compte connecté le moins chargé (limites actuelles + tâches déjà données).
    # Le poids d'une tâche dépend de leur nombre : avec des comptes de charge proche, le travail est réparti
    # entre eux ; un compte presque à sa limite reste épargné.
    $u = @(Usable-Accounts)
    $tasks = @($tasks)
    $step = [Math]::Max(15, [int](100 / [Math]::Max(1, $tasks.Count)))
    $load = @{}; foreach ($a in $u) { $load[$a.Id] = Acct-Load $a }
    foreach ($t in $tasks) {
        $best = $u | Sort-Object { $load[$_.Id] } | Select-Object -First 1
        $t.account = $best.Id
        $load[$best.Id] += $step
    }
}
function Missing-Accounts { @($Accs | Where-Object { -not (Acct-Logged $_) }) }
function Acct-Chip([string]$id) {
    $a = Acct-ById $id
    if ($a) { "$(RgbA $a.Rgb)◆ $($a.Short)$R" } else { "$Dm◆ ?$R" }
}
function Accounts-Line {
    (@($Accs | ForEach-Object {
                $ln = Acct-Load $_
                $st = if (Acct-Logged $_) { "$([int]$ln)%" } else { 'non connecté' }
                "$(RgbA $_.Rgb)●$R $Dm$($_.Short) $st$R"
            })) -join '  '
}

# ───────────────────────── dépôt & équipe ─────────────────────────
$RepoRoot = $null; $RunDir = $null; $WtRoot = $null; $State = $null
$Psmux = $Sock -and $Session -and (Get-Command psmux -ErrorAction SilentlyContinue)
$WinT = "${Session}:equipe"

function Resolve-Repo {
    if (-not $GitExe) { return $null }
    $top = Git-In $Repo @('rev-parse', '--show-toplevel')
    if ($GitCode -ne 0 -or -not $top) { return $null }
    [IO.Path]::GetFullPath(($top | Select-Object -First 1).Trim())
}
function Has-Commit { [void](Git-In $RepoRoot @('rev-parse', '--verify', '-q', 'HEAD')); $GitCode -eq 0 }
function Dirty-Files([switch]$TrackedOnly) {
    # modifications non commitées du projet (hors .flow\ : profil et tableau de l'outil) ; -TrackedOnly : sans les fichiers non suivis
    @(Git-In $RepoRoot @('status', '--porcelain') | Where-Object { $_ -and $_ -notmatch '^\S*\s+"?\.flow/' -and (-not $TrackedOnly -or $_ -notmatch '^\?\?') })
}
function Exclude-Flow {
    # .flow\runs\ (tableau des équipes) n'est jamais commité ; .flow\config.json (profil du projet) peut l'être
    $common = (Git-In $RepoRoot @('rev-parse', '--git-common-dir') | Select-Object -First 1).Trim()
    if (-not [IO.Path]::IsPathRooted($common)) { $common = Join-Path $RepoRoot $common }
    $ex = Join-Path $common 'info\exclude'
    New-Item -ItemType Directory -Force (Split-Path $ex) | Out-Null
    $cur = if (Test-Path -LiteralPath $ex) { Get-Content -LiteralPath $ex -Raw } else { '' }
    if ($cur -match '(?m)^\.flow/\s*$') { $cur = $cur -replace '(?m)^\.flow/\s*$', '.flow/runs/'; Set-Content -LiteralPath $ex $cur -NoNewline }
    elseif ($cur -notmatch '(?m)^\.flow/runs/') { Add-Content -LiteralPath $ex "`n.flow/runs/" }
}

# ───────────────────────── profil du projet (.flow\config.json) ─────────────────────────
# Décrit le workflow du projet : préparation d'une copie, vérifications, conventions, livraison.
$Cfg = $null
function Cfg-Path { Join-Path $RepoRoot '.flow\config.json' }

function Has-Cmd([string]$n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }

function Detect-Project {
    # détection sans IA, rapide : outils, commandes, fichiers locaux, conventions Git
    $root = $RepoRoot
    $has = { param($p) Test-Path -LiteralPath (Join-Path $root $p) }
    $src = [Collections.Generic.List[string]]::new()       # d'où vient chaque déduction (affiché à l'utilisateur)
    $setup = $null; $checks = [Collections.Generic.List[object]]::new()
    $addCheck = { param($n, $c) if ($c -and -not ($checks | Where-Object { $_.name -eq $n })) { $checks.Add([pscustomobject]@{ name = $n; cmd = $c }) } }

    if (& $has 'package.json') {
        $pm = if (& $has 'pnpm-lock.yaml') { 'pnpm' } elseif (& $has 'yarn.lock') { 'yarn' } elseif ((& $has 'bun.lockb') -or (& $has 'bun.lock')) { 'bun' } else { 'npm' }
        $setup = switch ($pm) {
            'pnpm' { 'pnpm install --frozen-lockfile' }
            'yarn' { 'yarn install --frozen-lockfile' }
            'bun'  { 'bun install' }
            default { if (& $has 'package-lock.json') { 'npm ci' } else { 'npm install' } }
        }
        $src.Add("Node ($pm) : package.json")
        try { $pj = Get-Content -LiteralPath (Join-Path $root 'package.json') -Raw | ConvertFrom-Json } catch { $pj = $null }
        $sc = $pj.scripts
        foreach ($pair in @(@('lint', @('lint')), @('types', @('typecheck', 'type-check', 'tsc', 'check-types')), @('tests', @('test')), @('build', @('build')))) {
            foreach ($nm in $pair[1]) {
                $v = $sc.$nm
                if ($v -and $v -notmatch 'no test specified') { & $addCheck $pair[0] "$pm run $nm"; break }
            }
        }
    }
    if ((& $has 'pyproject.toml') -or (& $has 'requirements.txt') -or (& $has 'setup.py')) {
        $run = ''
        if (& $has 'uv.lock') { $setup = 'uv sync'; $run = 'uv run '; $src.Add('Python (uv)') }
        elseif (& $has 'poetry.lock') { $setup = 'poetry install'; $run = 'poetry run '; $src.Add('Python (poetry)') }
        else { $src.Add('Python') }
        $pyp = if (& $has 'pyproject.toml') { Get-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Raw } else { '' }
        if ($pyp -match '\[tool\.ruff' -or (& $has 'ruff.toml')) { & $addCheck 'lint' "${run}ruff check ." }
        if ($pyp -match '\[tool\.mypy' -or (& $has 'mypy.ini')) { & $addCheck 'types' "${run}mypy ." }
        if ($pyp -match 'pytest' -or (& $has 'pytest.ini') -or (& $has 'tests')) { & $addCheck 'tests' "${run}python -m pytest -q" }
    }
    if (& $has 'Cargo.toml') { $src.Add('Rust'); & $addCheck 'build' 'cargo build'; & $addCheck 'tests' 'cargo test' }
    if (& $has 'go.mod') { $src.Add('Go'); & $addCheck 'lint' 'go vet ./...'; & $addCheck 'tests' 'go test ./...' }
    if (Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.sln', '.csproj', '.fsproj' } | Select-Object -First 1) {
        $src.Add('.NET'); & $addCheck 'build' 'dotnet build'; & $addCheck 'tests' 'dotnet test'
    }
    if (& $has 'pom.xml') { $src.Add('Java (Maven)'); & $addCheck 'tests' 'mvn -q test' }
    if ((& $has 'gradlew.bat') -or (& $has 'build.gradle') -or (& $has 'build.gradle.kts')) { $src.Add('Java/Kotlin (Gradle)'); & $addCheck 'tests' '.\gradlew.bat test' }
    if (& $has 'composer.json') { $src.Add('PHP'); if (-not $setup) { $setup = 'composer install' }; if (& $has 'phpunit.xml') { & $addCheck 'tests' 'vendor/bin/phpunit' } }
    if (& $has 'Gemfile') { $src.Add('Ruby'); if (-not $setup) { $setup = 'bundle install' }; if (& $has 'spec') { & $addCheck 'tests' 'bundle exec rspec' } }
    if (-not $checks.Count -and (& $has 'Makefile') -and (Has-Cmd 'make')) {
        $mk = Get-Content -LiteralPath (Join-Path $root 'Makefile') -Raw
        foreach ($tg in 'lint', 'test', 'build') { if ($mk -match "(?m)^$($tg):") { & $addCheck $(if ($tg -eq 'test') { 'tests' } else { $tg }) "make $tg" } }
        if ($checks.Count) { $src.Add('Makefile') }
    }

    # fichiers locaux non versionnés à recopier dans chaque copie de travail (.env, *.local…)
    $copy = @(Git-In $root @('ls-files', '--others', '--ignored', '--exclude-standard', '--directory') |
        Where-Object { $_ -and $_ -notmatch '/$' -and $_ -match '(^|/)\.env(\.[\w-]+)?$|\.local(\.\w+)?$|(^|/)secrets?\.\w+$' -and $_ -notmatch '\.example$|\.sample$|\.template$' } |
        Select-Object -First 15)

    # conventions Git
    $subjects = @(Git-In $root @('log', '-n', '60', '--no-merges', '--format=%s') | Where-Object { $_ })
    $conv = @($subjects | Where-Object { $_ -match '^(feat|fix|chore|docs|refactor|test|perf|build|ci|style|revert)(\([^)]*\))?!?: ' }).Count
    $style = if ($subjects.Count -ge 4 -and $conv -ge $subjects.Count * 0.5) { 'conventional' } else { 'libre' }
    $merges = @(Git-In $root @('log', '-n', '200', '--merges', '--format=%s') | Where-Object { $_ })
    $prFlow = @($merges | Where-Object { $_ -match 'Merge pull request #|Merge branch .* into|\(#\d+\)$' }).Count -gt 0 -or
              @($subjects | Where-Object { $_ -match '\(#\d+\)$' }).Count -ge 3
    $remote = (Git-In $root @('remote', 'get-url', 'origin') | Select-Object -First 1)
    if ($GitCode -ne 0) { $remote = '' }
    $deliver = if ($prFlow -and $remote -match 'github\.com' -and (Has-Cmd 'gh')) { 'pr' }
               elseif ($prFlow -and $remote) { 'branch' }
               elseif ($merges.Count) { 'merge' } else { 'squash' }
    $brs = @(Git-In $root @('branch', '-a', '--format=%(refname:short)') | ForEach-Object { $_ -replace '^origin/', '' })
    $prefix = 'flow/'
    foreach ($pfx in 'feature/', 'feat/', 'features/', 'fix/', 'dev/') {
        if (@($brs | Where-Object { $_.StartsWith($pfx) }).Count -ge 2) { $prefix = "${pfx}flow-"; break }
    }

    [pscustomobject][ordered]@{
        version = 1
        setup = $setup
        copyFiles = @($copy)
        checks = @($checks)
        branchPrefix = $prefix
        commitStyle = $style
        commitExamples = @($subjects | Select-Object -First 5)
        deliver = $deliver
        targetBranch = $null
        instructions = ''
        detected = @($src)
    }
}

function Load-ProjectConfig {
    $p = Cfg-Path
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { $c = Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    $d = Detect-Project
    foreach ($pr in $d.PSObject.Properties) { if ($null -eq $c.($pr.Name)) { $c | Add-Member -NotePropertyName $pr.Name -NotePropertyValue $pr.Value -Force } }
    $c
}

function Save-ProjectConfig {
    New-Item -ItemType Directory -Force (Split-Path (Cfg-Path)) | Out-Null
    Write-JsonAtomic $Cfg (Cfg-Path) -Depth 8 -Backup
}

function Deliver-Label([string]$d) {
    switch ($d) {
        'merge'  { 'fusion locale (merge --no-ff) dans la branche cible' }
        'squash' { 'un seul commit (squash) dans la branche cible' }
        'pr'     { 'pull request GitHub (push + gh pr create)' }
        'branch' { 'branche prête, poussée sur origin, fusion par toi' }
        default  { $d }
    }
}

function Refine-WithClaude {
    # Claude lit README, CONTRIBUTING, CLAUDE.md, la CI… et complète le profil (lecture seule)
    $acct = Least-Loaded
    $tmp = Join-Path $RepoRoot '.flow\runs\_profil'
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $pf = Join-Path $tmp 'profil-prompt.md'
    $cur = $Cfg | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $pf -Encoding utf8 @"
Tu configures un outil qui fait travailler plusieurs instances de Claude en parallèle sur CE projet ($RepoRoot),
chacune dans une copie neuve du dépôt (git worktree). L'outil doit respecter le workflow EXISTANT du projet.

Lis (lecture seule) ce qui décrit ce workflow : README, CONTRIBUTING, CLAUDE.md, .github/workflows (ou autre CI),
fichiers de config des outils (package.json, pyproject.toml, Makefile…), et regarde l'historique Git (git log).

Profil détecté automatiquement (à corriger / compléter) :
$cur

Réponds UNIQUEMENT avec un objet JSON valide, de la même forme, où :
- "setup" : commande(s) PowerShell pour préparer une copie neuve (installer les dépendances), ou null ;
- "copyFiles" : fichiers locaux non versionnés indispensables à recopier (ex. .env), chemins relatifs ;
- "checks" : liste ordonnée { "name", "cmd" } des vérifications du projet (lint, types, tests, build…),
  telles que la CI ou les contributeurs les lancent, en commandes PowerShell utilisables sous Windows ;
- "branchPrefix", "commitStyle" ("conventional" ou "libre"), "deliver" ("merge" | "squash" | "pr" | "branch") ;
- "instructions" : règles du projet que chaque Claude doit suivre (style, architecture, interdits, langue des
  commits…), en quelques puces Markdown concises ; garde celles déjà présentes.
"@
    $msg = "Lis le fichier $pf et suis exactement ses instructions. Ta réponse finale doit être uniquement l'objet JSON demandé."
    $job = Start-Job -ScriptBlock {
        param($cwd, $dir, $msg, $add)
        Set-Location -LiteralPath $cwd
        [Console]::OutputEncoding = [Text.Encoding]::UTF8   # la sortie de claude est en UTF-8
        if ($dir) { $env:CLAUDE_CONFIG_DIR = $dir } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
        $out = & claude -p $msg --output-format json --allowedTools 'Read,Grep,Glob' --add-dir $add 2>&1 | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    } -ArgumentList $RepoRoot, $acct.Dir, $msg, $tmp
    $res = Wait-Job-Spinner $job "Claude ($($acct.Label)) lit la documentation et la CI du projet…"
    if ($null -eq $res) { return "$Dm analyse annulée$R" }
    try {
        $j = $res.Out | ConvertFrom-Json -ErrorAction Stop
        $txt = [string]$j.result
        $a = $txt.IndexOf('{'); $z = $txt.LastIndexOf('}')
        $new = $txt.Substring($a, $z - $a + 1) | ConvertFrom-Json -ErrorAction Stop
    } catch { return "$Err✗ réponse illisible ($($_.Exception.Message))$R" }
    foreach ($k in 'setup', 'copyFiles', 'checks', 'branchPrefix', 'commitStyle', 'deliver', 'instructions') {
        if ($null -ne $new.$k) { $Cfg.$k = $new.$k }
    }
    if ($Cfg.deliver -notin 'merge', 'squash', 'pr', 'branch') { $Cfg.deliver = 'merge' }
    $Cfg.detected = @(@($Cfg.detected) + 'affiné par Claude' | Select-Object -Unique)
    "$Ok✓ profil complété par Claude : vérifie-le puis valide$R"
}

function Mode-Profile {
    # écran du profil : ce que l'outil fera dans CE projet ; Entrée = valider (enregistre .flow\config.json)
    $msg = ''
    $first = -not (Test-Path -LiteralPath (Cfg-Path))
    Cls
    while ($true) {
        $W = [Math]::Max(40, (ConW) - 1)
        $L = [Collections.Generic.List[string]]::new()
        $L.Add(''); $L.Add("  $(Grad '⚑ ÉQUIPE — profil du projet' 0.1)   $B$(Split-Path $RepoRoot -Leaf)$R")
        $L.Add("  $Dm$RepoRoot$R")
        if ($first) { $L.Add("  $Info Premier passage dans ce projet : voici comment l'équipe s'adaptera à son workflow.$R") }
        $L.Add("  $Dm détecté : $(@($Cfg.detected) -join ' · ')$R"); $L.Add('')
        $L.Add("  $B Préparer chaque copie$R  $(if ($Cfg.setup) { $Cfg.setup } else { "$Dm(rien)$R" })")
        $L.Add("  $B Fichiers recopiés$R      $(if (@($Cfg.copyFiles).Count) { @($Cfg.copyFiles) -join ', ' } else { "$Dm(aucun)$R" })")
        $L.Add("  $B Vérifications$R")
        if (@($Cfg.checks).Count) { foreach ($c in @($Cfg.checks)) { $L.Add("     $Teal•$R $($c.name) $Dm→$R $($c.cmd)") } }
        else { $L.Add("     $Dm(aucune détectée — A pour demander à Claude, E pour les écrire)$R") }
        $L.Add("  $B Branches$R               $($Cfg.branchPrefix)<équipe>-<tâche>")
        $L.Add("  $B Commits$R                $(if ($Cfg.commitStyle -eq 'conventional') { 'Conventional Commits (feat:, fix:…)' } else { 'style libre, comme l''historique' })")
        $L.Add("  $B Livraison$R              $(Deliver-Label $Cfg.deliver)$(if ($Cfg.targetBranch) { " $Dm→ $($Cfg.targetBranch)$R" } else { " $Dm→ branche actuelle$R" })")
        if ($Cfg.instructions) {
            $L.Add("  $B Règles du projet$R")
            foreach ($x in @(Chunks ([string]$Cfg.instructions) ($W - 8)) | Select-Object -First 6) { $L.Add("     $Dm$x$R") }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'CLAUDE.md'))) {
            $L.Add(''); $L.Add("  $Warn⚠ pas de CLAUDE.md : les Claude connaîtront moins bien le projet — G pour en créer un modèle maintenant.$R")
        }
        $L.Add('')
        $L.Add((Keys @('Entrée', 'valider', 'A', 'affiner avec Claude', 'L', 'mode de livraison', 'E', 'modifier (JSON)', 'D', 'redétecter', 'G', 'créer CLAUDE.md', 'Échap', 'retour')))
        $L.Add("  $Dm Enregistré dans .flow\config.json : tu peux le commiter pour le partager avec le projet.$R")
        if ($msg) { $L.Add("  $msg") }
        Show-Frame $L
        $k = (Read-KeyOrHint); $ch = "$($k.KeyChar)".ToLower()
        if ($k.Key -eq 'Enter') { Save-ProjectConfig; return 'home' }
        elseif ($k.Key -eq 'Escape') { if ($first) { Save-ProjectConfig }; return 'home' }
        elseif ($ch -eq 'g') {
            $f = New-ClaudeMd $RepoRoot
            $msg = if ($f) { "$Ok✓ CLAUDE.md créé : $f — à relire et compléter$R" } else { "$Dm CLAUDE.md existe déjà$R" }
            if ($f) { Write-FlowLog "CLAUDE.md créé dans $RepoRoot" }
        }
        elseif ($ch -eq 'a') { $msg = Refine-WithClaude; Cls }
        elseif ($ch -eq 'd') { $keep = $Cfg.instructions; $script:Cfg = Detect-Project; $Cfg.instructions = $keep; $msg = "$Info↻ profil redétecté$R" }
        elseif ($ch -eq 'l') {
            $order = 'merge', 'squash', 'pr', 'branch'
            $Cfg.deliver = $order[([array]::IndexOf($order, [string]$Cfg.deliver) + 1) % $order.Count]
            if ($Cfg.deliver -eq 'pr' -and -not (Has-Cmd 'gh')) { $msg = "$Warn⚠ la pull request demande GitHub CLI (winget install --id GitHub.cli)$R" } else { $msg = '' }
        }
        elseif ($ch -eq 'e') {
            Save-ProjectConfig
            Start-Process notepad.exe -ArgumentList "`"$(Cfg-Path)`"" -Wait
            $c = Load-ProjectConfig
            if ($c) { $script:Cfg = $c; $msg = "$Ok✓ profil relu$R" } else { $msg = "$Err✗ config.json illisible : corrige-le (E)$R" }
            Cls
        }
    }
}
function Proj-Key([string]$p) { ([IO.Path]::GetFullPath($p).TrimEnd('\', '/')) -replace '[^a-zA-Z0-9]', '-' }

function Save-State {
    $State.updated = (Get-Date).ToString('o')
    Write-JsonAtomic $State (Join-Path $RunDir 'state.json') -Depth 12
}
function Use-Run($st) {
    # équipes créées avant l'ajout des modèles / du conseiller : champs manquants complétés
    foreach ($t in @($st.tasks)) {
        foreach ($kv in @(@('model', 'sonnet'), @('why', ''), @('advisor', ''), @('advice', 0), @('helpSeen', ''),
                          @('review', ''), @('reviews', 0), @('reviewSeen', ''), @('reviewer', ''), @('annSeen', ''))) {
            if ($null -eq $t.($kv[0])) { $t | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1] -Force }
        }
    }
    if ($null -eq $st.crossReview) { $st | Add-Member -NotePropertyName crossReview -NotePropertyValue (-not $NoReview) -Force }
    $script:State = $st
    $script:RunDir = Join-Path $RepoRoot ".flow\runs\$($st.id)"
    $script:WtRoot = Join-Path (Split-Path $RepoRoot -Parent) "$(Split-Path $RepoRoot -Leaf)-flow\$($st.id)"
}
function Open-Runs {
    $dir = Join-Path $RepoRoot '.flow\runs'
    @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
            $f = Join-Path $_.FullName 'state.json'
            if (Test-Path -LiteralPath $f) {
                try { $s = Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json } catch { $s = $null }
                if ($s -and $s.status -notin 'merged', 'discarded') { $s }
            }
        })
}
function Run-Prefix { if ($State.prefix) { [string]$State.prefix } else { 'flow/' } }
function Task-Branch($t) { "$(Run-Prefix)$($State.id)-$($t.id)" }
function Int-Branch { "$(Run-Prefix)$($State.id)" }
function Int-Dir { Join-Path $WtRoot '_integration' }
function Result-File([string]$id) { Join-Path $RunDir "resultats\$id.md" }
function Review-File([string]$id) { Join-Path $RunDir "relectures\$id.md" }      # relectures croisées de la tâche
function Announce-File([string]$id) { Join-Path $RunDir "annonces\$id.md" }      # annonces de l'ouvrier à ses coéquipiers
function Board-File { Join-Path $RunDir 'TABLEAU.md' }                           # état de l'équipe, tenu à jour par FLOW
function Deps($t) { @(@($t.depends) | Where-Object { $_ }) }
function Task-ById([string]$id) { @($State.tasks) | Where-Object { $_.id -eq $id } | Select-Object -First 1 }

function Topo($tasks) {
    $done = @{}; $out = [Collections.Generic.List[object]]::new()
    for ($guard = 0; $out.Count -lt @($tasks).Count -and $guard -lt 50; $guard++) {
        foreach ($t in $tasks) {
            if ($done[$t.id]) { continue }
            if (@(Deps $t | Where-Object { -not $done[$_] }).Count -eq 0) { $out.Add($t); $done[$t.id] = $true }
        }
    }
    if ($out.Count -lt @($tasks).Count) { throw 'dépendances circulaires dans le plan' }
    , $out
}

# ───────────────────────── textes envoyés aux Claude ─────────────────────────
function Planner-Prompt([string]$request, [string]$extra) {
    $n = @(Usable-Accounts).Count
    $more = if ($extra) { "`nPRÉCISION DE L'UTILISATEUR SUR LE PLAN PRÉCÉDENT :`n$extra`n" } else { '' }
    @"
Tu es le PLANIFICATEUR d'une équipe de Claude qui vont travailler EN PARALLÈLE sur ce projet : $RepoRoot

Chaque membre travaillera dans sa propre copie du dépôt (git worktree, sur sa propre branche), sans voir le travail
des autres en cours. Les branches seront fusionnées à la fin. $n compte(s) Claude sont disponibles.

DEMANDE DE L'UTILISATEUR :
<<<
$request
>>>
$more
Ton travail :
1. Explore le projet en lecture seule (Read, Grep, Glob), juste assez pour savoir où intervenir.
2. Découpe la demande en tâches : au plus $MaxTasks. Si la demande est petite ou ne se parallélise pas bien,
   fais UNE seule tâche : ne découpe jamais artificiellement.
3. Règles :
   - chaque tâche est autonome, précise et vérifiable ;
   - un fichier appartient à UNE seule tâche ; si deux tâches doivent toucher le même fichier, la seconde
     dépend de la première ("depends") ;
   - préfère des tâches indépendantes ; n'utilise "depends" que si c'est nécessaire ;
   - le brief contient tout le contexte commun : objectif global, partie du code concernée, conventions du projet,
     décisions que tout le monde doit respecter (noms, interfaces partagées, formats de données), pour que les
     tâches s'assemblent sans conflit ;
   - respecte le workflow du projet décrit ci-dessous (vérifications, style de commit, règles) ;
   - choisis pour chaque tâche le modèle le plus approprié ("model") :
       "haiku"  : tâche simple et mécanique (renommage, petite modification ciblée, documentation, configuration) ;
       "sonnet" : tâche standard (fonctionnalité bien définie, tests, refactorisation locale) ;
       "opus"   : tâche complexe (architecture, débogage difficile, changement transversal, algorithme délicat).
     Ne mets "opus" que si c'est justifié : les tâches simples vont plus vite et coûtent moins avec un modèle léger.
$(Conventions-Text)
4. Réponds UNIQUEMENT avec un objet JSON valide, sans aucun texte avant ou après, de cette forme :
{
  "summary": "la demande résumée en une phrase",
  "commitTitle": "titre du commit (ou de la pull request) final, dans le style de commit du projet",
  "brief": "brief commun, en Markdown",
  "tasks": [
    { "id": "A", "title": "titre court", "goal": "ce qu'il faut faire, précisément",
      "files": ["chemins relatifs des fichiers à créer ou modifier"], "depends": [], "done": "critères de fin vérifiables",
      "model": "haiku | sonnet | opus", "why": "pourquoi ce modèle, en quelques mots" }
  ]
}
"@
}

function Write-TaskFiles {
    New-Item -ItemType Directory -Force (Join-Path $RunDir 'taches'), (Join-Path $RunDir 'resultats') | Out-Null
    $brief = "# Brief commun de l'équipe`n`n**Demande :** $($State.prompt)`n`n**Résumé :** $($State.summary)`n`n$($State.brief)`n"
    Set-Content -LiteralPath (Join-Path $RunDir 'BRIEF.md') $brief -Encoding utf8
    foreach ($t in @($State.tasks)) {
        $others = @($State.tasks | Where-Object { $_.id -ne $t.id } | ForEach-Object { "- $($_.id) — $($_.title) (fichiers : $(@($_.files) -join ', '))" })
        $dep = @(Deps $t | ForEach-Object { "- $_ : son travail est déjà dans ta branche ; lis son compte-rendu $(Result-File $_)" })
        $md = @(
            "# Tâche $($t.id) — $($t.title)", '',
            '## Objectif', $t.goal, '',
            '## Fichiers qui te sont attribués', $(if (@($t.files).Count) { @($t.files) | ForEach-Object { "- $_" } } else { '- (à déterminer : reste au plus près de l''objectif)' }), '',
            '## Terminé quand', $t.done, ''
        )
        if ($dep.Count) { $md += @('## Dépend de') + $dep + @('') }
        if ($others.Count) { $md += @("## Les autres tâches de l'équipe (pour info : n'y touche pas)") + $others }
        Set-Content -LiteralPath (Join-Path $RunDir "taches\$($t.id).md") ($md -join "`n") -Encoding utf8
    }
}

function Conventions-Text {
    # le workflow du projet, tel que décrit par .flow\config.json, pour chaque Claude
    $o = @()
    if (@($Cfg.checks).Count) {
        $o += 'Vérifications du projet (lance celles qui concernent ta tâche avant ton commit, et corrige ce que tu as cassé) :'
        foreach ($c in @($Cfg.checks)) { $o += "   - $($c.name) : $($c.cmd)" }
    }
    if ($Cfg.commitStyle -eq 'conventional') { $o += 'Messages de commit : Conventional Commits (feat:, fix:, refactor:, test:…), comme l''historique du projet.' }
    if (@($Cfg.commitExamples).Count) { $o += "Exemples de messages de commit du projet : $((@($Cfg.commitExamples) | Select-Object -First 3 | ForEach-Object { "« $_ »" }) -join ' · ')" }
    if ($Cfg.instructions) { $o += 'Règles du projet :'; $o += [string]$Cfg.instructions }
    if (-not $o.Count) { return '' }
    "`n## Workflow du projet (à respecter)`n" + ($o -join "`n") + "`n"
}

function Worker-Prompt($t) {
    $wt = $t.worktree; $br = Task-Branch $t
    $rev = if ($State.crossReview) { @(
        "- RELECTURE CROISÉE : une fois ton compte-rendu écrit, un Claude d'un autre compte relit ton travail. S'il trouve des",
        "  problèmes, tu reçois un message « [FLOW] Relecture croisée » : lis $(Review-File $t.id) (dernière section), corrige les",
        "  points bloquants et importants (si tu n'es pas d'accord avec un point, explique pourquoi dans ton compte-rendu),",
        "  relance les vérifications, fais un commit, puis RÉÉCRIS ton compte-rendu en y ajoutant ce que tu as corrigé :",
        "  c'est sa mise à jour qui signale que tu as fini."
    ) -join "`n" } else { '' }
    $conv = Conventions-Text
    $commitHint = if ($Cfg.commitStyle -eq 'conventional') { 'un message Conventional Commits (ex. « feat: … »)' } else { 'un message dans le style de l''historique du projet' }
    @"
# Tu es l'ouvrier de la tâche $($t.id) — $($t.title)

Tu fais partie d'une équipe de plusieurs instances de Claude qui travaillent en parallèle sur le même projet.
Tu travailles dans TA copie du dépôt : $wt (branche $br). Les autres travaillent ailleurs, sur d'autres fichiers.

1. Lis le brief commun : $(Join-Path $RunDir 'BRIEF.md')
2. Lis ta fiche : $(Join-Path $RunDir "taches\$($t.id).md")
3. Réalise ta tâche, et seulement elle :
   - modifie uniquement les fichiers de ta fiche (si un autre fichier est indispensable, fais le minimum et signale-le) ;
   - ne fusionne aucune branche et ne touche pas au dossier principal du projet ;
   - s'il te manque une information importante, pose la question à l'utilisateur au lieu de deviner.
4. Vérifie ton travail avec les vérifications du projet (voir plus bas), au moins celles qui concernent ta tâche.
5. Fais un commit sur ta branche : git add -A puis git commit, avec $commitHint.
6. EN DERNIER, écris ton compte-rendu dans $(Result-File $t.id) :
   - ce que tu as fait, les fichiers modifiés, tes choix importants ;
   - les points d'attention pour l'intégration (interfaces, noms, migrations…) ;
   - ce qui reste à faire ou n'a pas pu être vérifié.
   Ce fichier signale à l'équipe que ta tâche est terminée : ne l'écris qu'une fois le commit fait.

## Travailler en équipe (synchronisation)
- Le tableau de l'équipe est tenu à jour ici : $(Board-File) — qui fait quoi, ce qui est fini, où lire le travail des autres
  (comptes-rendus dans $(Join-Path $RunDir 'resultats'), code des tâches finies avec « git show <branche>:<chemin> »).
  Consulte-le quand ta tâche se raccorde à celle d'un autre, au lieu de deviner ses noms ou ses formats.
- Si tu prends une décision qui concerne les autres (un nom, une signature, un format, un fichier partagé que tu as dû
  toucher, un écart par rapport au brief), ANNONCE-LA tout de suite : ajoute quelques lignes datées dans
  $(Announce-File $t.id). FLOW prévient aussitôt les autres ouvriers. N'annonce que ce qui change leur travail.
- Les messages qui commencent par « [FLOW] Info équipe » ou « [FLOW] Annonce » viennent de tes coéquipiers : tiens-en
  compte si ta tâche est concernée, sinon continue sans t'interrompre.
$rev

## Si la tâche devient trop complexe
Tu as un CONSEILLER (un modèle plus puissant). Si tu bloques, si tu tournes en rond ou si la tâche s'avère plus
complexe que prévu : écris ta question dans $(Help-File $t.id) (le contexte, ce que tu as essayé, ce qui coince),
puis attends. Le conseiller étudie ton travail et répond dans $(Advice-File $t.id) ; tu recevras un message ici.
L'utilisateur peut aussi t'écrire directement dans ce panneau.
$conv
"@
}

function Integrator-Prompt($t, $files) {
    @"
# Tu es l'INTÉGRATEUR de l'équipe

Dossier : $(Int-Dir) (branche $(Int-Branch)).
La fusion de la branche $(Task-Branch $t) (tâche $($t.id) — $($t.title)) est en conflit sur :
$(@($files) | ForEach-Object { "- $_" } | Out-String)
1. Lis le brief : $(Join-Path $RunDir 'BRIEF.md'), puis les comptes-rendus dans $(Join-Path $RunDir 'resultats').
2. Résous les conflits en conservant l'intention de chaque tâche (ne supprime le travail de personne sans raison).
3. Vérifie que le projet compile et que les vérifications du projet passent (voir plus bas).
4. Termine la fusion : git add -A puis git commit --no-edit
5. Écris un court compte-rendu dans $(Join-Path $RunDir "resultats\_integration-$($t.id).md").
$(Conventions-Text)
"@
}

function Prepare-Copy([string]$wt) {
    # copie neuve : on y recopie les fichiers locaux du projet (.env…) ; la commande de préparation
    # (installation des dépendances) est lancée dans le panneau, visible, avant Claude
    foreach ($f in @($Cfg.copyFiles)) {
        if (-not $f) { continue }
        $from = Join-Path $RepoRoot $f; $to = Join-Path $wt $f
        if ((Test-Path -LiteralPath $from) -and -not (Test-Path -LiteralPath $to)) {
            New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
            Copy-Item -LiteralPath $from -Destination $to -Recurse
        }
    }
}

function Setup-Cmd {
    if (-not $Cfg.setup) { return '' }
    "Write-Host '⚙ préparation de la copie : $(([string]$Cfg.setup) -replace "'", "''")' -ForegroundColor DarkGray; $($Cfg.setup); "
}

# ───────────────────────── panneaux des ouvriers ─────────────────────────
function Git-Env {
    # les ouvriers commitent eux-mêmes : git dans le PATH (même s'il vient d'être installé)
    # et une identité de commit si l'utilisateur n'en a pas configuré (sans toucher à sa config)
    $s = ''
    $gd = Split-Path $GitExe -Parent
    if (-not (Get-Command git -ErrorAction SilentlyContinue) -or ($env:PATH -split ';') -notcontains $gd) { $s += "`$env:PATH = $(Q $gd) + ';' + `$env:PATH; " }
    if ($GitId.Count) {
        $s += "`$env:GIT_AUTHOR_NAME = 'FLOW'; `$env:GIT_AUTHOR_EMAIL = 'flow@localhost'; `$env:GIT_COMMITTER_NAME = 'FLOW'; `$env:GIT_COMMITTER_EMAIL = 'flow@localhost'; "
    }
    $s
}

function Pane-Cmd([string]$dir, $acct, [string]$promptFile, [switch]$Continue, [switch]$Setup, [string]$Model) {
    $pre = "Set-Location -LiteralPath $(Q $dir); " + (Acct-Env $acct) + (Git-Env) + 'Clear-Host; '
    if ($Setup) { $pre += Setup-Cmd }
    $mod = if ($Model) { "--model $Model " } else { '' }
    if ($Continue) { return "${pre}claude --continue $mod$WorkerArgs --add-dir $(Q $RunDir)" }
    $msg = "Lis le fichier $promptFile et suis exactement ses instructions."
    # La consigne passe EN PREMIER : « --add-dir » accepte plusieurs dossiers, un texte placé après lui serait pris pour un
    # dossier de plus et Claude s'ouvrirait sur une invite vide (vérifié : « claude -p --add-dir X "texte" » échoue,
    # « claude -p "texte" --add-dir X » répond). Même règle pour toute option à valeurs multiples.
    "${pre}claude $(Q $msg) $mod$WorkerArgs --add-dir $(Q $RunDir)"
}

function Find-Pane([string]$tag) {
    if (-not $Psmux) { return $null }
    foreach ($ln in (& psmux -L $Sock list-panes -t $WinT -F '#{pane_index}|#{@flow_task}' 2>$null)) {
        $f = "$ln" -split '\|', 2
        if ($f.Count -eq 2 -and $f[1] -eq $tag) { return "$WinT.$($f[0])" }
    }
    $null
}

function Open-Pane([string]$tag, [string]$title, [string]$cmd, [string]$dir) {
    if (-not $Psmux) {
        # hors psmux : une fenêtre de terminal par ouvrier
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        Start-Process pwsh -ArgumentList @('-NoExit', '-NoProfile', '-EncodedCommand', $enc)
        return
    }
    $names = @(& psmux -L $Sock list-windows -t $Session -F '#{window_name}' 2>$null)
    if ($names -notcontains 'equipe') { & psmux -L $Sock new-window -d -t $Session -n equipe -c $dir *> $null }
    else { & psmux -L $Sock split-window -d -t $WinT -c $dir *> $null }
    $tgt = $null
    for ($k = 0; $k -lt 40 -and -not $tgt; $k++) {
        foreach ($ln in (& psmux -L $Sock list-panes -t $WinT -F '#{pane_index}|#{@flow_task}' 2>$null)) {
            $f = "$ln" -split '\|', 2
            if (-not $f[1]) { $tgt = "$WinT.$($f[0])"; break }
        }
        if (-not $tgt) { Start-Sleep -Milliseconds 100 }
    }
    if (-not $tgt) { throw "impossible d'ouvrir un panneau pour $tag" }
    & psmux -L $Sock set -p -t $tgt '@flow_task' $tag *> $null
    & psmux -L $Sock set -p -t $tgt '@flow_base' $title *> $null
    & psmux -L $Sock set -p -t $tgt '@flow_role' $title *> $null
    & psmux -L $Sock select-layout -t $WinT tiled *> $null
    for ($k = 0; $k -lt 60; $k++) {
        if (((& psmux -L $Sock capture-pane -p -t $tgt 2>$null) -join '').Trim()) { break }
        Start-Sleep -Milliseconds 100
    }
    & psmux -L $Sock send-keys -t $tgt -l $cmd *> $null
    & psmux -L $Sock send-keys -t $tgt Enter *> $null
}

function Set-PaneState([string]$tag, [string]$pstate, [string]$label) {
    $tgt = Find-Pane $tag
    if (-not $tgt) { return }
    $base = (& psmux -L $Sock display-message -t $tgt -p '#{@flow_base}' 2>$null | Select-Object -First 1)
    & psmux -L $Sock set -p -t $tgt '@flow_role' "$base · $label" *> $null
    & psmux -L $Sock set -p -t $tgt '@flow_state' $pstate *> $null
}

function Focus-Pane([string]$tag) {
    $tgt = Find-Pane $tag
    if (-not $tgt) { return $false }
    & psmux -L $Sock select-window -t $WinT *> $null
    & psmux -L $Sock select-pane -t $tgt *> $null
    $true
}

function Kill-TeamPanes {
    if (-not $Psmux) { return }
    for ($k = 0; $k -lt 20; $k++) {
        $ln = @(& psmux -L $Sock list-panes -t $WinT -F '#{pane_index}|#{@flow_task}' 2>$null | Where-Object { ("$_" -split '\|', 2)[1] })
        if (-not $ln.Count) { break }
        & psmux -L $Sock kill-pane -t "$WinT.$(("$($ln[0])" -split '\|')[0])" *> $null
    }
}

function Claude-State($acct, [string]$dir) {
    # dernier message de la conversation de cet ouvrier : fin de tour = il attend l'utilisateur
    $pd = Join-Path (Join-Path $acct.Home 'projects') (Proj-Key $dir)
    $f = Get-ChildItem -LiteralPath $pd -Filter *.jsonl -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { return 'starting' }
    try {
        $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $n = [int][Math]::Min(262144, $fs.Length); [void]$fs.Seek(-$n, 'End')
            $buf = New-Object byte[] $n; [void]$fs.Read($buf, 0, $n)
            $lines = [Text.Encoding]::UTF8.GetString($buf) -split "`n"
        } finally { $fs.Dispose() }
    } catch { return 'working' }
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $o = $null; try { $o = $lines[$i] | ConvertFrom-Json -Depth 64 -ErrorAction Stop } catch { continue }
        if ($o.isSidechain) { continue }
        if ($o.type -eq 'assistant') { if ($o.message.stop_reason -eq 'end_turn') { return 'waiting' } else { return 'working' } }
        if ($o.type -eq 'user') { return 'working' }
    }
    'starting'
}

# ───────────────────────── saisie ─────────────────────────
function Read-Prompt([string]$initial) {
    # éditeur multi-ligne : Entrée = nouvelle ligne, F5 ou Ctrl+D = envoyer, Échap = annuler
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($ln in ("$initial" -split "`r?`n")) { $lines.Add($ln) }
    Cls
    while ($true) {
        $W = [Math]::Max(40, (ConW) - 1); $H = ConH
        $L = [Collections.Generic.List[string]]::new()
        $L.Add(''); $L.Add("  $(Grad '⚑ ÉQUIPE — nouvelle demande' 0.1)   $B$(Split-Path $RepoRoot -Leaf)$R  $Dm$RepoRoot$R")
        $L.Add("  $(Accounts-Line)")
        $miss = @(Missing-Accounts)
        if ($miss.Count -and $Accs.Count -gt 1) { $L.Add("  $Warn⚠ $(($miss.Label) -join ', ') : non connecté — F4 pour le connecter (sinon tout part sur les autres comptes)$R") }
        $wait = @(Open-Runs).Count
        if ($wait) { $L.Add("  $Teal⚑ $wait équipe(s) ou plan(s) en attente — F6 pour les voir$R") }
        $chk = (@($Cfg.checks) | ForEach-Object { $_.name }) -join ', '
        $L.Add("  $Dm workflow : $(if ($Cfg.setup) { "préparation « $($Cfg.setup) » · " })vérifs : $(if ($chk) { $chk } else { 'aucune' }) · livraison : $($Cfg.deliver)$R")
        $L.Add('')
        $L.Add("  $Dm Décris ce que tu veux : un planificateur va découper la demande en tâches, réparties$R")
        $L.Add("  $Dm sur les comptes Claude (chacun dans sa copie du projet). Tu valideras le plan avant le départ.$R")
        $L.Add('')
        $txt = @(); foreach ($ln in $lines) { $txt += @(Chunks $ln ($W - 6)) }
        if (-not $txt.Count) { $txt = @('') }
        $room = [Math]::Max(3, $H - 16)
        $shown = @($txt | Select-Object -Last $room)
        $bc = Rgb 70 74 96
        $L.Add("  $bc╭$('─' * ($W - 5))╮$R")
        for ($i = 0; $i -lt $shown.Count; $i++) {
            $cur = if ($i -eq $shown.Count - 1) { "$(PalC 0.1)▌$R" } else { '' }
            $L.Add("  $bc│$R $(Fit "$($shown[$i])$cur" ($W - 7)) $bc│$R")
        }
        $L.Add("  $bc╰$('─' * ($W - 5))╯$R")
        $L.Add('')
        $L.Add((Keys @('F5 / Ctrl+D', 'envoyer', 'Entrée', 'nouvelle ligne', 'F2', 'profil du projet', 'F3', 'changer de projet', 'F4', 'comptes', 'F6', 'plans en attente', 'Échap', 'quitter')))
        Show-Frame $L
        $k = (Read-KeyOrHint)
        $ctrl = [bool]($k.Modifiers -band [ConsoleModifiers]::Control)
        if ($k.Key -eq 'Escape') { return $null }
        if ($k.Key -eq 'F2') { return '::profile' }
        if ($k.Key -eq 'F3') { return '::project' }
        if ($k.Key -eq 'F4') { [void](Connect-Missing); continue }
        if ($k.Key -eq 'F6') { return '::home' }
        if ($k.Key -eq 'F5' -or ($ctrl -and $k.Key -eq 'D')) {
            $t = ($lines -join "`n").Trim()
            if ($t) { return $t } else { continue }
        }
        if ($k.Key -eq 'Enter') { $lines.Add(''); continue }
        if ($k.Key -eq 'Backspace') {
            $last = $lines[$lines.Count - 1]
            if ($last.Length) { $lines[$lines.Count - 1] = $last.Substring(0, $last.Length - 1) }
            elseif ($lines.Count -gt 1) { $lines.RemoveAt($lines.Count - 1) }
            continue
        }
        if (-not [char]::IsControl($k.KeyChar)) { $lines[$lines.Count - 1] += $k.KeyChar }
    }
}

function Read-Line([string]$title, [string]$prompt) {
    $buf = ''
    Cls
    while ($true) {
        Show-Frame @('', "  $(Grad $title 0.1)", '', "  $prompt", "  $(PalC 0.1)❯$R $B$buf$R$(PalC 0.1)▌$R", '', (Keys @('Entrée', 'valider', 'Échap', 'annuler')))
        $k = (Read-KeyOrHint)
        if ($k.Key -eq 'Escape') { return $null }
        if ($k.Key -eq 'Enter') { return $buf.Trim() }
        if ($k.Key -eq 'Backspace') { if ($buf.Length) { $buf = $buf.Substring(0, $buf.Length - 1) }; continue }
        if (-not [char]::IsControl($k.KeyChar)) { $buf += $k.KeyChar }
    }
}

function Message-Screen([string]$title, [string[]]$body, [string[]]$keys) {
    # écran fixe : renvoie la touche pressée
    Cls
    $L = @('', "  $(Grad $title 0.1)", '') + @($body | ForEach-Object { "  $_" }) + @('', (Keys $keys))
    Show-Frame $L
    (Read-KeyOrHint)
}

function Connect-Acct($a) {
    # connexion d'un compte dans ce panneau (claude auth login). Renvoie $true si connecté.
    Disable-Mouse
    [Console]::Write("$R$e[?25h$e[2J$e[H")
    Write-Host ''
    Write-Host "  $(Grad "⚑ ÉQUIPE — connexion de « $($a.Label) »" 0.1)"
    Write-Host "  $Dm dossier du compte : $($a.Home)$R"
    Write-Host ''
    Write-Host '  Claude va ouvrir la page de connexion dans ton navigateur.'
    Write-Host "  $Warn Ton navigateur est déjà connecté à un autre compte ?$R Copie le lien ci-dessous dans une fenêtre"
    Write-Host '  privée, connecte-toi avec le bon compte, puis colle ici le code obtenu.'
    Write-Host ''
    New-Item -ItemType Directory -Force $a.Home | Out-Null
    $old = $env:CLAUDE_CONFIG_DIR
    try {
        if ($a.Dir) { $env:CLAUDE_CONFIG_DIR = $a.Dir } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
        # Start-Process : la sortie va droit à l'écran (un appel direct serait capturé par l'appelant, lien compris)
        Start-Process -FilePath (Get-Command claude -ErrorAction Stop).Source -ArgumentList @('auth', 'login') -NoNewWindow -Wait
    } catch { Write-Host "  $Err$($_.Exception.Message)$R" }
    finally { if ($old) { $env:CLAUDE_CONFIG_DIR = $old } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue } }
    $logged = Acct-Logged $a
    if (-not $logged) {
        Write-Host ''
        Write-Host "  $Warn○ « $($a.Label) » n'est pas encore connecté.$R $Dm Entrée pour continuer.$R"
        [void][Console]::ReadLine()
    }
    Enable-Mouse
    $script:LastFrameSize = ''; Cls
    $logged
}

function Connect-Missing {
    # propose de connecter chaque compte non connecté ; renvoie le nombre de comptes connectés à l'instant
    $n = 0
    foreach ($a in @(Missing-Accounts)) {
        $k = Message-Screen "⚑ ÉQUIPE — « $($a.Label) » n'est pas connecté" @(
            "Sans lui, ses tâches iront aux autres comptes : $(Accounts-Line)", '',
            "$Dm dossier du compte : $($a.Home)$R") @('Entrée', 'le connecter maintenant', 'S', 'passer', 'Échap', 'retour')
        if ($k.Key -eq 'Escape') { break }
        if ($k.Key -eq 'Enter') { if (Connect-Acct $a) { $n++ } }
    }
    Cls
    $n
}

function Wait-Job-Spinner($job, [string]$label) {
    # attend une tâche de fond en affichant un indicateur ; Échap l'annule (renvoie $null)
    Cls
    $t0 = Get-Date
    while ($job.State -eq 'Running') {
        $el = ((Get-Date) - $t0).ToString('mm\:ss')
        Show-Frame @('', "  $(Grad '⚑ ÉQUIPE' 0.1)", '', "  $(PalC ($script:Tick * 0.02))$($Spin[$script:Tick % 10])$R $label $Dm$el$R", '', (Keys @('Échap', 'annuler')))
        $script:Tick++
        $act = Read-Action
        if ($act.K -and $act.K.Key -eq 'Escape') { Stop-Job $job; Remove-Job $job -Force; return $null }
        Start-Sleep -Milliseconds 120
    }
    $rv = Receive-Job $job; Remove-Job $job -Force
    $rv
}

# ───────────────────────── étapes ─────────────────────────
function Mode-Setup {
    # Git présent ? dossier sous Git ? au moins un commit ?
    while ($true) {
        if (-not $script:GitExe) {
            $k = Message-Screen '⚑ ÉQUIPE — Git est nécessaire' @(
                "Chaque ouvrier travaille dans sa propre copie du projet (git worktree) : il faut Git.",
                '', "Installe-le, par exemple :  $B winget install --id Git.Git -e$R", '',
                "$Dm puis appuie sur R pour vérifier à nouveau.$R") @('R', 'vérifier', 'Échap', 'quitter')
            if ($k.Key -eq 'Escape') { return 'quit' }
            $script:GitExe = Find-Git; Init-GitId; continue
        }
        $script:RepoRoot = Resolve-Repo
        if (-not $RepoRoot) {
            $target = [IO.Path]::GetFullPath($Repo)
            $top = @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | Select-Object -First 14 | ForEach-Object { $(if ($_.PSIsContainer) { "$($_.Name)\" } else { $_.Name }) })
            $heavy = @('node_modules', '.venv', 'venv', '__pycache__', 'dist', 'build', 'bin', 'obj', 'target', '.next') | Where-Object { Test-Path -LiteralPath (Join-Path $target $_) }
            $k = Message-Screen '⚑ ÉQUIPE — ce dossier n''est pas sous Git' @(
                "$B$target$R", "$Dm contenu : $($top -join '  ')$R", '',
                'Les ouvriers ont besoin d''un dépôt Git (une copie de travail par tâche).',
                "I = initialiser ici : git init + un premier commit de tout le dossier$(if ($heavy) { " (un .gitignore exclura : $($heavy -join ', '))" }).") @('I', 'initialiser', 'Échap', 'quitter')
            if ($k.Key -eq 'Escape') { return 'quit' }
            if ("$($k.KeyChar)".ToLower() -ne 'i') { continue }
            [void](Git-In $target @('init'))
            $gi = Join-Path $target '.gitignore'
            if ($heavy -and -not (Test-Path -LiteralPath $gi)) { Set-Content -LiteralPath $gi (($heavy | ForEach-Object { "$_/" }) -join "`n") -Encoding utf8 }
            $script:RepoRoot = [IO.Path]::GetFullPath($target)
            Exclude-Flow
            [void](Git-In $RepoRoot @('add', '-A'))
            [void](Git-In $RepoRoot @('commit', '-q', '-m', 'flow: commit initial'))
            continue
        }
        Exclude-Flow
        if (-not (Has-Commit)) {
            $k = Message-Screen '⚑ ÉQUIPE — le dépôt n''a encore aucun commit' @('Les ouvriers partent du dernier commit : il en faut au moins un.', 'C = créer un premier commit avec le contenu actuel.') @('C', 'commit', 'Échap', 'quitter')
            if ($k.Key -eq 'Escape') { return 'quit' }
            if ("$($k.KeyChar)".ToLower() -eq 'c') { [void](Git-In $RepoRoot @('add', '-A')); [void](Git-In $RepoRoot @('commit', '-q', '-m', 'flow: commit initial')) }
            continue
        }
        Remember-Project $RepoRoot
        # profil du projet : chargé, sinon détecté et montré pour validation (premier passage)
        $script:Cfg = Load-ProjectConfig
        if (-not $Cfg) { $script:Cfg = Detect-Project; return 'profile' }
        return 'home'
    }
}

# ───────────────────────── projets récents ─────────────────────────
$RecentFile = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\config\team-projects.json'))
function Recent-Projects {
    try { @(Get-Content -LiteralPath $RecentFile -Raw -Encoding utf8 | ConvertFrom-Json) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } } catch { @() }
}
function Remember-Project([string]$p) {
    $list = @($p) + @(Recent-Projects | Where-Object { $_ -ne $p }) | Select-Object -First 10
    try { (ConvertTo-Json @($list)) | Set-Content -LiteralPath $RecentFile -Encoding utf8 } catch {}
}

function Mode-Project {
    # changer de projet sans quitter FLOW : récents, ou n'importe quel dossier
    $items = @(Recent-Projects) + @('…autre dossier')
    $i = 0
    Cls
    while ($true) {
        $L = @('', "  $(Grad '⚑ ÉQUIPE — projet' 0.1)", "  $Dm projet actuel : $RepoRoot$R", '')
        for ($k = 0; $k -lt $items.Count; $k++) {
            $mark = if ($k -eq $i) { "$(PalC 0.1)$B▸$R" } else { ' ' }
            $nm = if ($k -eq $items.Count - 1) { "$Dm$($items[$k])$R" } else { "$B$(Split-Path $items[$k] -Leaf)$R $Dm$($items[$k])$R" }
            $L += "  $mark $nm"
        }
        $L += @('', (Keys @('↑↓', 'choisir', 'Entrée', 'ouvrir', 'Échap', 'retour')))
        Show-Frame $L
        $k = (Read-KeyOrHint)
        if ($k.Key -eq 'UpArrow') { $i = ($i - 1 + $items.Count) % $items.Count }
        elseif ($k.Key -eq 'DownArrow') { $i = ($i + 1) % $items.Count }
        elseif ($k.Key -eq 'Escape') { return 'home' }
        elseif ($k.Key -eq 'Enter') {
            $p = if ($i -eq $items.Count - 1) { Read-Line '⚑ ÉQUIPE — projet' 'Chemin du dossier du projet :' } else { $items[$i] }
            if (-not $p) { Cls; continue }
            $p = [Environment]::ExpandEnvironmentVariables($p.Trim('"')) -replace '^~', $HOME
            if (-not (Test-Path -LiteralPath $p -PathType Container)) { [void](Message-Screen '⚑ ÉQUIPE' @("$Err dossier introuvable : $p$R") @('Entrée', 'retour')); Cls; continue }
            $script:Repo = [IO.Path]::GetFullPath($p)
            return 'setup'
        }
    }
}

function Mode-Home {
    $runs = Open-Runs
    if ($runs.Count) {
        $i = 0
        Cls
        while ($true) {
            $L = @('', "  $(Grad '⚑ ÉQUIPE — équipes en cours' 0.1)", '')
            for ($k = 0; $k -lt $runs.Count; $k++) {
                $rv = $runs[$k]
                $mark = if ($k -eq $i) { "$(PalC 0.1)$B▸$R" } else { ' ' }
                $L += "  $mark $B$($rv.summary)$R $Dm($($rv.id) · $($rv.status) · $(@($rv.tasks).Count) tâche(s))$R"
            }
            $L += @('', (Keys @('↑↓', 'choisir', 'Entrée', 'reprendre', 'N', 'nouvelle demande', 'Échap', 'quitter')))
            Show-Frame $L
            for ($q = 0; $q -lt $runs.Count; $q++) { Add-Zone (3 + $q) (3 + $q) 0 999 @{ Row = $q } }   # chaque équipe est cliquable
            $act = Read-Action -Wait
            if ($act.Click) {
                # clic : choisir ; 2e clic ou double-clic : reprendre
                $q = $act.Click.Row
                if ($q -eq $i -or $act.Double) { $k = Fake-Key 'Enter' } else { $i = $q; continue }
            } else { $k = $act.K }
            if ($k.Key -eq 'UpArrow') { $i = ($i - 1 + $runs.Count) % $runs.Count }
            elseif ($k.Key -eq 'DownArrow') { $i = ($i + 1) % $runs.Count }
            elseif ($k.Key -eq 'Escape') { return 'quit' }
            elseif ("$($k.KeyChar)".ToLower() -eq 'n') { break }
            elseif ($k.Key -eq 'Enter') {
                Use-Run $runs[$i]
                if ($State.status -eq 'planned') {
                    # plan déposé par tools\flow-plan.ps1 (skill « taches-repartir ») : comptes à attribuer
                    if (@($State.tasks | Where-Object { -not (Acct-ById ([string]$_.account)) }).Count) { Assign-Accounts @($State.tasks) }
                    if (-not $State.deliver) { $State.deliver = [string]$Cfg.deliver }
                    Save-State
                }
                switch ($State.status) {
                    'planned' { return 'plan' }
                    'running' { return 'run' }
                    'integrating' { return 'integrate' }
                    default { return 'review' }
                }
            }
        }
    }

    $req = Read-Prompt ''
    if ($null -eq $req) { return 'quit' }
    if ($req -eq '::profile') { return 'profile' }
    if ($req -eq '::project') { return 'project' }
    if ($req -eq '::home') { return 'home' }

    # point de départ : la branche cible du profil, sinon le dernier commit de la branche actuelle
    $baseRef = if ($Cfg.targetBranch) { [string]$Cfg.targetBranch } else { 'HEAD' }
    [void](Git-In $RepoRoot @('rev-parse', '--verify', '-q', $baseRef))
    if ($GitCode -ne 0) { [void](Message-Screen '⚑ ÉQUIPE' @("$Err branche cible introuvable : $baseRef (profil du projet, F2)$R") @('Entrée', 'retour')); return 'home' }
    $dirty = if ($baseRef -eq 'HEAD') { Dirty-Files } else { @() }
    if ($dirty.Count) {
        $k = Message-Screen '⚑ ÉQUIPE — modifications non commitées' @(
            "$($dirty.Count) fichier(s) modifié(s) ne sont pas dans le dernier commit :",
            "$Dm$((@($dirty | Select-Object -First 6) | ForEach-Object { $_.Trim() }) -join '   ')$R", '',
            'Les ouvriers partent du dernier commit : sans commit, ils ne verront pas ces modifications.',
            "C = les commiter maintenant (« flow: point de départ ») · Entrée = partir du dernier commit sans elles") @('C', 'commiter', 'Entrée', 'continuer sans', 'Échap', 'annuler')
        if ($k.Key -eq 'Escape') { return 'home' }
        if ("$($k.KeyChar)".ToLower() -eq 'c') { [void](Git-In $RepoRoot @('add', '-A')); [void](Git-In $RepoRoot @('commit', '-q', '-m', 'flow: point de départ')) }
    }

    $id = Get-Date -Format 'yyyyMMdd-HHmmss'
    $st = [pscustomobject]@{
        id = $id; created = (Get-Date).ToString('o'); updated = ''; status = 'planning'; prompt = $req
        base = (Git-In $RepoRoot @('rev-parse', $baseRef) | Select-Object -First 1).Trim()
        baseBranch = $(if ($Cfg.targetBranch) { [string]$Cfg.targetBranch } else { (Git-In $RepoRoot @('rev-parse', '--abbrev-ref', 'HEAD') | Select-Object -First 1).Trim() })
        prefix = [string]$Cfg.branchPrefix; deliver = [string]$Cfg.deliver; commitTitle = ''
        summary = ''; brief = ''; planner = ''; tasks = @(); crossReview = (-not $NoReview)
        integration = [pscustomobject]@{ merged = @(); skipped = @(); conflict = ''; tests = $null; checks = @(); delivered = '' }
    }
    Use-Run $st
    New-Item -ItemType Directory -Force $RunDir | Out-Null
    Set-Content -LiteralPath (Join-Path $RunDir 'demande.md') $req -Encoding utf8
    Save-State
    if (Invoke-Planner '') { return 'plan' }
    'home'
}

function Invoke-Planner([string]$extra) {
    # planificateur : Claude en mode non interactif, lecture seule, sur le compte le moins chargé
    $acct = Least-Loaded
    $State.planner = $acct.Id
    $pf = Join-Path $RunDir 'planificateur.md'
    Set-Content -LiteralPath $pf (Planner-Prompt $State.prompt $extra) -Encoding utf8
    $msg = "Lis le fichier $pf et suis exactement ses instructions. Ta réponse finale doit être uniquement l'objet JSON demandé."
    $job = Start-Job -ScriptBlock {
        param($cwd, $dir, $msg, $runDir)
        Set-Location -LiteralPath $cwd
        [Console]::OutputEncoding = [Text.Encoding]::UTF8   # la sortie de claude est en UTF-8
        if ($dir) { $env:CLAUDE_CONFIG_DIR = $dir } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
        # le découpage conditionne tout le reste : modèle le plus capable
        $out = & claude -p $msg --model opus --output-format json --allowedTools 'Read,Grep,Glob' --add-dir $runDir 2>&1 | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    } -ArgumentList $RepoRoot, $acct.Dir, $msg, $RunDir
    $res = Wait-Job-Spinner $job "le planificateur (opus, $($acct.Label)) étudie le projet, découpe la demande et choisit les modèles…"
    if ($null -eq $res) { return $false }
    Set-Content -LiteralPath (Join-Path $RunDir 'planificateur-sortie.txt') $res.Out -Encoding utf8
    $plan = $null; $why = ''
    try {
        $j = $res.Out | ConvertFrom-Json -ErrorAction Stop
        $txt = if ($j.result) { [string]$j.result } else { $res.Out }
        if ($j.is_error) { $why = "Claude a signalé une erreur : $txt" }
        $a = $txt.IndexOf('{'); $z = $txt.LastIndexOf('}')
        if (-not $why -and $a -ge 0 -and $z -gt $a) { $plan = $txt.Substring($a, $z - $a + 1) | ConvertFrom-Json -ErrorAction Stop }
    } catch { $why = $_.Exception.Message }
    if (-not $plan -or -not @($plan.tasks).Count) {
        $tail = @(($res.Out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 6)
        $k = Message-Screen '⚑ ÉQUIPE — le plan n''a pas pu être lu' (@("$Err$(if ($why) { $why } else { 'réponse sans plan JSON' })$R", '', "$Dm sortie complète : $(Join-Path $RunDir 'planificateur-sortie.txt')$R", '') + @($tail | ForEach-Object { "$Dm$_$R" })) @('R', 'réessayer', 'Échap', 'abandonner')
        if ("$($k.KeyChar)".ToLower() -eq 'r') { return (Invoke-Planner $extra) }
        $State.status = 'discarded'; Save-State
        return $false
    }
    Apply-Plan $plan
    $true
}

# ───────────────────────── modèles & conseiller ─────────────────────────
# alias de modèle de Claude Code (--model) : toujours la dernière version de chaque famille
$Models = @('haiku', 'sonnet', 'opus')
function Advisor-Model([string]$m) { switch ($m) { 'haiku' { 'sonnet' } default { 'opus' } } }   # un cran au-dessus
function Model-Chip([string]$m) {
    $c = switch ($m) { 'haiku' { @(120, 230, 200) } 'sonnet' { @(120, 160, 255) } 'opus' { @(200, 140, 255) } default { @(150, 150, 170) } }
    "$(RgbA $c)◇ $m$R"
}
function Help-File([string]$id) { Join-Path $RunDir "aide\$id.md" }
function Advice-File([string]$id) { Join-Path $RunDir "conseils\$id.md" }

function Worker-Transcript($t) {
    $acct = Acct-ById $t.account
    $pd = Join-Path (Join-Path $acct.Home 'projects') (Proj-Key $t.worktree)
    (Get-ChildItem -LiteralPath $pd -Filter *.jsonl -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

function Recent-Errors($t) {
    # erreurs d'outils consécutives à la fin de la conversation de l'ouvrier (signe qu'il tourne en rond)
    $f = Worker-Transcript $t
    if (-not $f) { return 0 }
    $n = 0
    $lines = @(Get-Content -LiteralPath $f -Tail 60 -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $o = $null; try { $o = $lines[$i] | ConvertFrom-Json -Depth 32 -ErrorAction Stop } catch { continue }
        if ($o.type -ne 'user' -or $o.message.content -is [string]) { continue }
        $tr = @($o.message.content | Where-Object { $_.type -eq 'tool_result' })
        if (-not $tr.Count) { continue }
        if (@($tr | Where-Object { $_.is_error }).Count) { $n++ } else { break }
    }
    $n
}

function Worker-Digest($t) {
    # résumé de ce que l'ouvrier a fait récemment (pour le conseiller) : ses messages et ses outils
    $f = Worker-Transcript $t
    if (-not $f) { return '(pas encore d''historique)' }
    $out = foreach ($ln in @(Get-Content -LiteralPath $f -Tail 120 -ErrorAction SilentlyContinue)) {
        $o = $null; try { $o = $ln | ConvertFrom-Json -Depth 32 -ErrorAction Stop } catch { continue }
        if ($o.type -eq 'assistant') {
            foreach ($x in @($o.message.content)) {
                if ($x.type -eq 'text' -and $x.text.Trim()) { "OUVRIER : $(($x.text -replace '\s+', ' ').Trim())" }
                elseif ($x.type -eq 'tool_use') { "OUTIL : $($x.name) $((($x.input | ConvertTo-Json -Compress -Depth 4) -replace '\s+', ' ').Substring(0, [Math]::Min(160, ($x.input | ConvertTo-Json -Compress -Depth 4).Length)))" }
            }
        } elseif ($o.type -eq 'user' -and $o.message.content -isnot [string]) {
            foreach ($x in @($o.message.content | Where-Object { $_.type -eq 'tool_result' -and $_.is_error })) {
                $txt = if ($x.content -is [string]) { $x.content } else { (@($x.content) | ForEach-Object { $_.text }) -join ' ' }
                "ERREUR : $(($txt -replace '\s+', ' ').Substring(0, [Math]::Min(240, ($txt -replace '\s+', ' ').Length)))"
            }
        }
    }
    (@($out) | Select-Object -Last 40) -join "`n"
}

function Advisor-Prompt($t, [string]$reason) {
    $help = if (Test-Path -LiteralPath (Help-File $t.id)) { Get-Content -LiteralPath (Help-File $t.id) -Raw } else { '(pas de question écrite)' }
    $diff = (Git-In $t.worktree @('diff', '--stat', "$($State.base)")) -join "`n"
    @"
Tu es le CONSEILLER de l'ouvrier de la tâche $($t.id) ($($t.title)), un Claude ($($t.model)) qui travaille dans
une équipe. Il a besoin d'aide : $reason.
Tu ne modifies AUCUN fichier : tu analyses et tu conseilles.

1. Lis le brief : $(Join-Path $RunDir 'BRIEF.md') et la fiche de la tâche : $(Join-Path $RunDir "taches\$($t.id).md").
2. Sa question (s'il en a écrit une) :
$help
3. Ce qu'il a fait récemment :
$(Worker-Digest $t)
4. Ses changements jusqu'ici (git diff --stat) :
$diff
5. Le code est dans : $($t.worktree) (lecture seule pour toi : Read, Grep, Glob).

Réponds en Markdown, de façon concrète et courte : le diagnostic (pourquoi il bloque), puis le plan à suivre en
étapes numérotées (fichiers, fonctions, commandes), et les pièges à éviter. S'il faut découper la tâche ou si elle
dépasse le périmètre prévu, dis-le clairement.
"@
}

function Apply-Plan($plan) {
    $letters = 'ABCDEFGHIJ'
    $tasks = @(); $i = 0
    foreach ($p in @($plan.tasks) | Select-Object -First $MaxTasks) {
        $id = if ($p.id) { ([string]$p.id -replace '[^A-Za-z0-9_-]', '') } else { '' }
        if (-not $id -or ($tasks | Where-Object { $_.id -eq $id })) { $id = [string]$letters[$i] }
        $model = ([string]$p.model).ToLower().Trim()
        if ($model -notin $Models) { $model = 'sonnet' }
        $tasks += [pscustomobject]@{
            id = $id; title = [string]$p.title; goal = [string]$p.goal; done = [string]$p.done
            files = @(@($p.files) | Where-Object { $_ } | ForEach-Object { [string]$_ })
            depends = @(@($p.depends) | Where-Object { $_ } | ForEach-Object { [string]$_ })
            model = $model; why = [string]$p.why
            account = ''; status = 'pending'; worktree = ''; error = ''; live = ''; startedAt = ''; doneAt = ''
            advisor = ''; advice = 0; helpSeen = ''
            review = ''; reviews = 0; reviewSeen = ''; reviewer = ''; annSeen = ''
        }
        $i++
    }
    $ids = $tasks.id
    foreach ($t in $tasks) { $t.depends = @($t.depends | Where-Object { $_ -in $ids -and $_ -ne $t.id }) }
    $State.summary = if ($plan.summary) { [string]$plan.summary } else { ($State.prompt -split "`n")[0] }
    $State.commitTitle = if ($plan.commitTitle) { [string]$plan.commitTitle } else { '' }
    $State.brief = [string]$plan.brief
    $State.tasks = $tasks
    try { [void](Topo $tasks) } catch { foreach ($t in $tasks) { $t.depends = @() } }
    Assign-Accounts $tasks
    $State.status = 'planned'
    Save-State
}

function Plan-Warnings {
    $w = @(); $ts = @($State.tasks)
    for ($i = 0; $i -lt $ts.Count; $i++) {
        for ($j = $i + 1; $j -lt $ts.Count; $j++) {
            $a = $ts[$i]; $tb = $ts[$j]
            if ($a.id -in (Deps $tb) -or $tb.id -in (Deps $a)) { continue }
            $shared = @($a.files | Where-Object { $f = $_; @($tb.files | Where-Object { $_ -ieq $f }).Count })
            if ($shared.Count) { $w += "⚠ $($a.id) et $($tb.id) modifient tous deux : $($shared -join ', ') (risque de conflit)" }
        }
    }
    $w
}

function Mode-Plan {
    $sel = 0
    Cls
    while ($true) {
        $W = [Math]::Max(40, (ConW) - 1)
        $ts = @($State.tasks)
        $L = [Collections.Generic.List[string]]::new()
        $L.Add(''); $L.Add("  $(Grad '⚑ ÉQUIPE — plan proposé' 0.1)   $Dm$($State.id)$R")
        $L.Add("  $B$($State.summary)$R"); $L.Add("  $(Accounts-Line)"); $L.Add('')
        $planZones = @()
        for ($i = 0; $i -lt $ts.Count; $i++) {
            $t = $ts[$i]
            $mark = if ($i -eq $sel) { "$(PalC 0.1)$B▸$R" } else { ' ' }
            $dep = if ((Deps $t).Count) { "$Dm après $((Deps $t) -join ', ')$R" } else { "$Dm en parallèle$R" }
            # zones cliquables : la ligne entière (choisir), le compte et le modèle (changer)
            $pre = "  $mark $B$($t.id)$R  "; $ac = Acct-Chip $t.account; $mc = Model-Chip $t.model
            $xa = VisLen $pre; $xm = $xa + (VisLen $ac) + 2
            $planZones += @{ Y = $L.Count; Row = $i; XA = $xa; XA2 = $xa + (VisLen $ac) - 1; XM = $xm; XM2 = $xm + (VisLen $mc) - 1 }
            $L.Add("$pre$ac  $mc  $B$($t.title)$R  $dep")
            $L.Add("        $Dm$(@($t.files) -join '  ')$R")
        }
        $L.Add('')
        $t = $ts[$sel]
        foreach ($x in @(Chunks "Objectif : $($t.goal)" ($W - 8)) | Select-Object -First 4) { $L.Add("    $x") }
        if ($t.why) { foreach ($x in @(Chunks "Modèle $($t.model) : $($t.why)" ($W - 8)) | Select-Object -First 2) { $L.Add("    $Dm$x$R") } }
        $L.Add("    $Dm conseiller si la tâche se complique : $(Model-Chip (Advisor-Model $t.model))$R")
        foreach ($x in @(Chunks "Fini quand : $($t.done)" ($W - 8)) | Select-Object -First 2) { $L.Add("    $Dm$x$R") }
        foreach ($x in Plan-Warnings) { $L.Add("  $Warn$x$R") }
        $miss = @(Missing-Accounts)
        if ($miss.Count -and $Accs.Count -gt 1) {
            $onMiss = @($ts | Where-Object { $_.account -in $miss.Id })
            $L.Add("  $Warn⚠ $(($miss.Label) -join ', ') : non connecté$(if ($onMiss.Count) { " — tâche(s) $(($onMiss.id) -join ', ') à réattribuer" } else { ' — tout est réparti sur les comptes connectés' }) · C pour le connecter$R")
        }
        $L.Add("  $Dm relecture croisée : $(if ($State.crossReview) { 'activée — chaque tâche finie est relue par un Claude d''un autre compte avant la fusion' } else { 'désactivée' }) · V pour changer$R")
        $L.Add('')
        $L.Add((Keys @('Entrée', 'lancer l''équipe', 'Tab', 'compte', 'M', 'modèle', 'A', 'répartir', 'C', 'comptes', 'E', 'modifier le plan', 'R', 'replanifier', 'Échap', 'abandonner')))
        $L.Add("  $Dm clic : choisir une tâche · clic sur ◆ compte ou ◇ modèle : le changer$R")
        Show-Frame $L
        foreach ($pz in $planZones) {
            Add-Zone $pz.Y ($pz.Y + 1) 0 999 @{ Row = $pz.Row; What = 'row' }
            Add-Zone $pz.Y $pz.Y $pz.XA $pz.XA2 @{ Row = $pz.Row; What = 'account' }
            Add-Zone $pz.Y $pz.Y $pz.XM $pz.XM2 @{ Row = $pz.Row; What = 'model' }
        }
        $act = Read-Action -Wait
        if ($act.Click) {
            # (pas de « continue » dans un switch : il ne relancerait pas la boucle)
            $sel = $act.Click.Row; $t = $ts[$sel]
            if ($act.Click.What -eq 'model') { $k = Fake-Key 'm' }
            elseif ($act.Click.What -eq 'account') { $k = Fake-Key 'Tab' }
            else { continue }
        } else { $k = $act.K }
        $ch = "$($k.KeyChar)".ToLower()
        if ($k.Key -eq 'UpArrow') { $sel = ($sel - 1 + $ts.Count) % $ts.Count }
        elseif ($k.Key -eq 'DownArrow') { $sel = ($sel + 1) % $ts.Count }
        elseif ($ch -eq 'm') { $t.model = $Models[([array]::IndexOf($Models, [string]$t.model) + 1) % $Models.Count]; $t.why = 'choisi à la main'; Save-State }
        elseif ($k.Key -eq 'Tab') {
            $ids = @($Accs.Id); $cur = [array]::IndexOf($ids, $t.account)
            $t.account = $ids[($cur + 1) % $ids.Count]; Save-State
        }
        elseif ($ch -eq 'a') { Assign-Accounts $ts; Save-State }
        elseif ($ch -eq 'v') { $State.crossReview = -not $State.crossReview; Save-State }
        elseif ($ch -eq 'c') {
            if (-not @(Missing-Accounts).Count) { [void](Message-Screen '⚑ ÉQUIPE — comptes' @("$Ok Tous les comptes sont connectés :$R $(Accounts-Line)") @('Entrée', 'retour')) }
            elseif ((Connect-Missing) -gt 0) { Assign-Accounts $ts; Save-State }   # un compte de plus : nouvelle répartition
            Cls
        }
        elseif ($k.Key -eq 'Enter') {
            # une tâche confiée à un compte non connecté resterait bloquée sur l'écran de connexion de Claude
            $missIds = @((Missing-Accounts).Id)
            $stuck = @($ts | Where-Object { $_.account -in $missIds })
            if ($stuck.Count -and @($Accs | Where-Object { $_.Id -notin $missIds }).Count) {
                $k2 = Message-Screen '⚑ ÉQUIPE — compte non connecté' @(
                    "La ou les tâches $(($stuck.id) -join ', ') sont confiées à un compte qui n'est pas connecté.", '',
                    'C = connecter le compte maintenant · A = les donner aux comptes connectés') @('C', 'connecter', 'A', 'répartir sur les comptes connectés', 'Échap', 'retour au plan')
                $c2 = "$($k2.KeyChar)".ToLower()
                if ($c2 -eq 'c') { [void](Connect-Missing) }
                elseif ($c2 -eq 'a') { Assign-Accounts $ts; Save-State }
                Cls; continue
            }
            Write-TaskFiles
            $State.status = 'running'; Save-State
            return 'run'
        }
        elseif ($ch -eq 'e') {
            # édition du plan à la main (tâches, fichiers, dépendances, compte) puis relecture
            $pf = Join-Path $RunDir 'plan.json'
            ([pscustomobject]@{ summary = $State.summary; brief = $State.brief; tasks = @($State.tasks | Select-Object id, title, goal, files, depends, done, model, why, account) } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $pf -Encoding utf8
            Start-Process notepad.exe -ArgumentList "`"$pf`"" -Wait
            try {
                $p = Get-Content -LiteralPath $pf -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
                $keep = @{}; foreach ($x in @($p.tasks)) { if ($x.account) { $keep[[string]$x.id] = [string]$x.account } }
                Apply-Plan $p
                foreach ($x in @($State.tasks)) { if ($keep[$x.id] -and (Acct-ById $keep[$x.id])) { $x.account = $keep[$x.id] } }
                Save-State
            } catch { [void](Message-Screen '⚑ ÉQUIPE' @("$Err plan.json illisible : $($_.Exception.Message)$R") @('Entrée', 'continuer')) }
            $sel = 0; Cls
        }
        elseif ($ch -eq 'r') {
            $extra = Read-Line '⚑ ÉQUIPE — replanifier' 'Qu''est-ce qui ne va pas dans ce plan ? (laisser vide pour simplement recommencer)'
            if ($null -ne $extra) { if (-not (Invoke-Planner $extra)) { return 'home' } }
            $sel = 0; Cls
        }
        elseif ($k.Key -eq 'Escape') {
            $State.status = 'discarded'; Save-State
            return 'home'
        }
    }
}

function Start-Task($t) {
    # copie de travail : depuis le point de départ, ou depuis la branche de sa (ses) dépendance(s)
    $deps = Deps $t
    $branch = Task-Branch $t
    $wt = Join-Path $WtRoot $t.id
    New-Item -ItemType Directory -Force $WtRoot | Out-Null
    $from = if ($deps.Count) { Task-Branch (Task-ById $deps[0]) } else { $State.base }
    $o = Git-In $RepoRoot @('worktree', 'add', '-b', $branch, $wt, $from)
    if ($GitCode -ne 0) { $t.status = 'failed'; $t.error = "worktree : $(($o | Select-Object -Last 1))"; return }
    foreach ($d in ($deps | Select-Object -Skip 1)) {
        [void](Git-In $wt @('merge', '--no-edit', '-q', (Task-Branch (Task-ById $d))))
        if ($GitCode -ne 0) { [void](Git-In $wt @('merge', '--abort')); $t.status = 'failed'; $t.error = "conflit entre les dépendances $($deps -join ' et ')"; return }
    }
    $t.worktree = $wt
    Prepare-Copy $wt
    $pf = Join-Path $RunDir "taches\$($t.id).prompt.md"
    Set-Content -LiteralPath $pf (Worker-Prompt $t) -Encoding utf8
    $acct = Acct-ById $t.account
    New-Item -ItemType Directory -Force (Split-Path (Help-File $t.id)), (Split-Path (Advice-File $t.id)) | Out-Null
    Open-Pane $t.id "⚑ $($t.id) · $($t.title) · $($acct.Short) · $($t.model)" (Pane-Cmd $wt $acct $pf -Setup -Model $t.model) $wt
    $t.status = 'running'; $t.startedAt = (Get-Date).ToString('o')
}

function Send-ToPane([string]$tag, [string]$text) {
    # écrit un message dans le panneau d'un Claude (comme si l'utilisateur le tapait) ; Claude le traite à son tour
    $tgt = Find-Pane $tag
    if (-not $tgt) { Write-FlowLog "message non envoyé : aucun panneau pour « $tag »" 'WARN'; return $false }
    Write-FlowLog "message envoyé à $tag : $(($text -replace '\s+', ' ').Substring(0, [Math]::Min(120, ($text -replace '\s+', ' ').Length)))"
    & psmux -L $Sock send-keys -t $tgt -l ($text -replace "`r?`n", ' ') *> $null
    & psmux -L $Sock send-keys -t $tgt Enter *> $null
    $true
}

$AdvJobs = @{}   # tâche → tâche de fond du conseiller en cours

function Start-Advisor($t, [string]$reason) {
    if ($AdvJobs.ContainsKey($t.id)) { return }
    $model = Advisor-Model $t.model
    $acct = Least-Loaded
    $pf = Join-Path $RunDir "conseils\$($t.id).prompt.md"
    New-Item -ItemType Directory -Force (Split-Path $pf) | Out-Null
    Set-Content -LiteralPath $pf (Advisor-Prompt $t $reason) -Encoding utf8
    $msg = "Lis le fichier $pf et suis exactement ses instructions. Ta réponse finale est le conseil, en Markdown."
    $job = Start-Job -ScriptBlock {
        param($cwd, $dir, $msg, $runDir, $model)
        Set-Location -LiteralPath $cwd
        [Console]::OutputEncoding = [Text.Encoding]::UTF8   # la sortie de claude est en UTF-8
        if ($dir) { $env:CLAUDE_CONFIG_DIR = $dir } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
        $out = & claude -p $msg --model $model --output-format json --allowedTools 'Read,Grep,Glob' --add-dir $runDir 2>&1 | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    } -ArgumentList $t.worktree, $acct.Dir, $msg, $RunDir, $model
    $AdvJobs[$t.id] = [pscustomobject]@{ Job = $job; Model = $model; Reason = $reason; Start = Get-Date }
    $t.advisor = 'running'; $t | Add-Member -NotePropertyName advisorModel -NotePropertyValue $model -Force
    Save-State
}

function Check-Advisors {
    # conseils prêts : on les écrit dans conseils\<tâche>.md et on prévient l'ouvrier dans son panneau
    foreach ($id in @($AdvJobs.Keys)) {
        $a = $AdvJobs[$id]
        if ($a.Job.State -eq 'Running') { continue }
        $rv = Receive-Job $a.Job; Remove-Job $a.Job -Force; $AdvJobs.Remove($id)
        $t = Task-ById $id
        $txt = ''
        try { $j = $rv.Out | ConvertFrom-Json -ErrorAction Stop; $txt = [string]$j.result } catch { $txt = '' }
        if (-not $txt.Trim()) { $t.advisor = 'failed'; Save-State; Notify "⚠ Conseiller de $id" 'Le conseiller n''a pas pu répondre.'; continue }
        $head = "`n---`n## Conseil du $(Get-Date -Format 'HH:mm') ($($a.Model)) — $($a.Reason)`n`n"
        Add-Content -LiteralPath (Advice-File $id) ($head + $txt) -Encoding utf8
        $t.advisor = 'done'; $t.advice = [int]$t.advice + 1; Save-State
        [void](Send-ToPane $id "[FLOW] Ton conseiller ($($a.Model)) a répondu : lis $(Advice-File $id) (dernière section) et applique son plan.")
        Notify "◈ Conseil pour la tâche $id" "Le conseiller ($($a.Model)) a répondu à l'ouvrier."
    }
}

# ───────────────────────── relecture croisée & synchronisation ─────────────────────────
$RevJobs = @{}   # tâche → relecture en cours (tâche de fond)

function Review-Model([string]$m) { if ($m -eq 'opus') { 'opus' } else { 'sonnet' } }

function Pick-Reviewer($t) {
    # un Claude d'un AUTRE compte que l'ouvrier (le moins chargé) ; à défaut, le même compte (regard neuf quand même)
    $u = @(Usable-Accounts)
    $other = @($u | Where-Object { $_.Id -ne $t.account })
    if ($other.Count) { $other | Sort-Object { Acct-Load $_ } | Select-Object -First 1 } else { $u | Select-Object -First 1 }
}

function Review-Prompt($t, [string]$diffFile, [int]$round) {
    $prev = if ($round -gt 1) { "`nC'est la relecture n°$round : lis d'abord la relecture précédente ($(Review-File $t.id)) et vérifie que ses points ont été corrigés (ou que l'ouvrier a expliqué son désaccord dans son compte-rendu) avant de chercher autre chose.`n" } else { '' }
    @"
Tu es le RELECTEUR de la tâche $($t.id) — $($t.title), réalisée par un autre Claude de l'équipe. C'est une relecture
croisée : un regard neuf avant que ce travail soit fusionné avec celui des autres. Tu ne modifies AUCUN fichier.
$prev
1. Lis le brief commun : $(Join-Path $RunDir 'BRIEF.md'), la fiche de la tâche : $(Join-Path $RunDir "taches\$($t.id).md")
   et le compte-rendu de l'ouvrier : $(Result-File $t.id).
2. Lis ses changements : $diffFile (le code complet est dans $($t.worktree), en lecture seule : Read, Grep, Glob).
3. Regarde les autres tâches de l'équipe (fiches dans $(Join-Path $RunDir 'taches'), comptes-rendus déjà écrits dans
   $(Join-Path $RunDir 'resultats'), annonces dans $(Join-Path $RunDir 'annonces')) : ce travail doit s'y raccorder.

Cherche, par ordre d'importance :
- ce qui ne fait pas ce que demande la fiche, ou un critère de fin non rempli ;
- les erreurs de logique et les cas non gérés qui casseraient à l'usage ;
- ce qui ne respecte pas les décisions communes du brief ou ne se raccorde pas aux autres tâches (noms, signatures,
  formats de données, emplacements) ;
- les fichiers modifiés hors du périmètre de la tâche sans raison donnée ;
- un comportement ajouté sans aucun test alors que le projet en a.
Ne signale ni le style ni les préférences personnelles. Si le travail est bon, dis-le : ne cherche pas des problèmes
pour en trouver. Un problème = un endroit précis et la correction que tu proposes.

Réponds UNIQUEMENT avec un objet JSON valide, sans texte avant ni après :
{ "verdict": "ok" ou "changes",
  "summary": "ton avis en deux phrases",
  "issues": [ { "severity": "bloquant" ou "important" ou "mineur", "file": "chemin", "problem": "ce qui ne va pas", "fix": "correction proposée" } ] }
"verdict" vaut "changes" seulement s'il y a au moins un problème bloquant ou important.
"@
}

function Start-Review($t) {
    if ($RevJobs.ContainsKey($t.id)) { return }
    $acct = Pick-Reviewer $t
    $model = Review-Model $t.model
    $round = [int]$t.reviews + 1
    New-Item -ItemType Directory -Force (Split-Path (Review-File $t.id)) | Out-Null
    $deps = Deps $t
    $from = if ($deps.Count) { Task-Branch (Task-ById $deps[0]) } else { $State.base }
    $diff = (Git-In $t.worktree @('diff', "$from..HEAD")) -join "`n"
    if ($diff.Length -gt 300000) { $diff = $diff.Substring(0, 300000) + "`n… (diff tronqué : lis les fichiers dans la copie de travail)" }
    $df = Join-Path $RunDir "relectures\$($t.id)-$round.diff"
    Set-Content -LiteralPath $df $diff -Encoding utf8
    $pf = Join-Path $RunDir "relectures\$($t.id)-$round.prompt.md"
    Set-Content -LiteralPath $pf (Review-Prompt $t $df $round) -Encoding utf8
    $msg = "Lis le fichier $pf et suis exactement ses instructions. Ta réponse finale doit être uniquement l'objet JSON demandé."
    $job = Start-Job -ScriptBlock {
        param($cwd, $dir, $msg, $runDir, $model)
        Set-Location -LiteralPath $cwd
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        if ($dir) { $env:CLAUDE_CONFIG_DIR = $dir } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
        $out = & claude -p $msg --model $model --output-format json --allowedTools 'Read,Grep,Glob' --add-dir $runDir 2>&1 | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    } -ArgumentList $t.worktree, $acct.Dir, $msg, $RunDir, $model
    $RevJobs[$t.id] = [pscustomobject]@{ Job = $job; Model = $model; Acct = $acct; Round = $round; Start = Get-Date }
    $t.review = 'pending'; $t.reviewer = $acct.Id
    Save-State
}

function Check-Reviews {
    # relectures rendues : écrites dans relectures\<tâche>.md ; s'il y a des corrections, l'ouvrier est prévenu
    $note = ''
    foreach ($id in @($RevJobs.Keys)) {
        $a = $RevJobs[$id]
        if ($a.Job.State -eq 'Running') {
            if (((Get-Date) - $a.Start).TotalMinutes -lt 10) { continue }
            # délai dépassé : la relecture est abandonnée, l'équipe n'attend pas indéfiniment
            Stop-Job $a.Job -ErrorAction SilentlyContinue
            Write-FlowLog "relecture de $id : délai de 10 minutes dépassé" 'ERREUR'
        }
        $rv = Receive-Job $a.Job; Remove-Job $a.Job -Force; $RevJobs.Remove($id)
        $t = Task-ById $id
        $rvw = $null
        try {
            $j = $rv.Out | ConvertFrom-Json -ErrorAction Stop
            $txt = [string]$j.result; $x = $txt.IndexOf('{'); $z = $txt.LastIndexOf('}')
            if (-not $j.is_error -and $x -ge 0 -and $z -gt $x) { $rvw = $txt.Substring($x, $z - $x + 1) | ConvertFrom-Json -ErrorAction Stop }
        } catch { $rvw = $null }
        $head = "`n---`n## Relecture n°$($a.Round) du $(Get-Date -Format 'HH:mm') — par $($a.Acct.Label) ($($a.Model))`n`n"
        if (-not $rvw) {
            # relecteur muet, hors délai ou réponse illisible : l'équipe n'est pas bloquée, mais la tâche n'est PAS « relue »
            $raw = Join-Path $RunDir "relectures\$id-$($a.Round).sortie.txt"
            try { Set-Content -LiteralPath $raw "$($rv.Out)" -Encoding utf8 } catch {}
            Add-Content -LiteralPath (Review-File $id) ($head + "(la relecture n'a pas pu être faite : sortie brute dans $raw)`n") -Encoding utf8
            $t.review = 'impossible'
            Write-FlowLog "relecture de $id impossible (sortie brute : $raw)" 'ERREUR'
            Notify "⚠ Relecture de la tâche $id impossible" 'La tâche est acceptée sans relecture.'
            $note = "$Err⌕ relecture de $id IMPOSSIBLE : tâche acceptée SANS relecture (détail : relectures\$id-$($a.Round).sortie.txt)$R"
            continue
        }
        $t.reviews = [int]$t.reviews + 1
        $issues = @($rvw.issues | Where-Object { $_ })
        $serious = @($issues | Where-Object { "$($_.severity)" -match 'bloquant|important' })
        $md = $head + "**Avis :** $($rvw.summary)`n"
        foreach ($is in $issues) { $md += "`n- **[$($is.severity)]** ``$($is.file)`` — $($is.problem)`n  - correction proposée : $($is.fix)" }
        Add-Content -LiteralPath (Review-File $id) ($md + "`n") -Encoding utf8
        if ("$($rvw.verdict)" -eq 'changes' -and $serious.Count) {
            $t.review = 'changes'
            $sent = Send-ToPane $id "[FLOW] Relecture croisée par $($a.Acct.Label) : $($serious.Count) point(s) à corriger. Lis $(Review-File $id) (dernière section), corrige les points bloquants et importants, relance les vérifications, fais un commit, puis RÉÉCRIS ton compte-rendu $(Result-File $id) en y ajoutant ce que tu as corrigé : c'est ce qui signale que tu as fini."
            if ($Psmux) { Set-PaneState $id 'busy' "✎ corrige après relecture ($($a.Acct.Short))" }
            Notify "⌕ Relecture de la tâche $id" "$($serious.Count) point(s) à corriger, renvoyés à l'ouvrier."
            $note = if ($sent) { "$Info⌕ $id relue par $($a.Acct.Short) : $($serious.Count) correction(s) demandée(s) à l'ouvrier$R" } else { "$Err⌕ $id : corrections demandées mais panneau introuvable (L pour relancer, T pour accepter)$R" }
        } else {
            $t.review = 'ok'
            $note = "$Ok⌕ $id relue par $($a.Acct.Short) : rien de bloquant$R"
        }
    }
    Save-State
    $note
}

function Tell-Others([string]$fromId, [string]$text) {
    # message aux autres ouvriers encore au travail (écrit dans leur panneau)
    foreach ($o in @($State.tasks | Where-Object { $_.id -ne $fromId -and $_.status -eq 'running' })) { [void](Send-ToPane $o.id $text) }
}

function Finish-Task($t) {
    $t.status = 'done'; $t.doneAt = (Get-Date).ToString('o'); $t.live = 'done'
    Write-FlowLog "tâche $($t.id) terminée ($($t.title))"
    $rel = if ([int]$t.reviews -and $t.review -ne 'impossible') { ' et relue' } else { '' }
    if ($Psmux) { Set-PaneState $t.id 'done' "✓ terminé$(if ($rel) { ' · relu' })" }
    Notify "✓ Tâche $($t.id) terminée$rel" $t.title
    Tell-Others $t.id "[FLOW] Info équipe : la tâche $($t.id) ($($t.title)) est terminée$rel. Compte-rendu : $(Result-File $t.id). Son code est sur la branche $(Task-Branch $t) (lecture : git show $(Task-Branch $t):<chemin>). Si ta tâche s'y raccorde, vérifie que tu utilises bien ses noms et ses formats ; sinon continue sans t'interrompre."
}

$BoardLast = ''
function Write-Board {
    # TABLEAU.md : l'état de l'équipe, lisible par tous les ouvriers (réécrit seulement quand il change)
    $rows = foreach ($t in @($State.tasks)) {
        $etat = switch ($t.status) {
            'pending' { 'en attente' }
            'done'    { "terminée$(if ([int]$t.reviews) { ' et relue' })" }
            'failed'  { "en échec ($($t.error))" }
            default   { switch ($t.live) { 'review' { 'en relecture croisée' } 'fixing' { 'corrige après relecture' } default { 'en cours' } } }
        }
        $cr = if (Test-Path -LiteralPath (Result-File $t.id)) { Result-File $t.id } else { '—' }
        $an = if (Test-Path -LiteralPath (Announce-File $t.id)) { Announce-File $t.id } else { '—' }
        "| $($t.id) | $($t.title) | $etat | $(@($t.files) -join ', ') | $(if ($t.worktree) { Task-Branch $t } else { '—' }) | $cr | $an |"
    }
    $body = @("# Tableau de l'équipe — $($State.summary)", '',
        '| Tâche | Titre | État | Fichiers | Branche | Compte-rendu | Annonces |', '|---|---|---|---|---|---|---|') + @($rows) + @('',
        "Brief commun : $(Join-Path $RunDir 'BRIEF.md')",
        'Lire le code d''une tâche sans quitter ta copie : git show <branche>:<chemin>  (ou git diff <branche> -- <chemin>)')
    $txt = $body -join "`n"
    if ($txt -ne $script:BoardLast) { try { Set-Content -LiteralPath (Board-File) $txt -Encoding utf8; $script:BoardLast = $txt } catch {} }
}

function Commits-Of($t) {
    if (-not $t.worktree) { return 0 }
    $n = Git-In $RepoRoot @('rev-list', '--count', "$($State.base)..$(Task-Branch $t)")
    if ($GitCode -eq 0) { [int]($n | Select-Object -First 1) } else { 0 }
}

function Mode-Run {
    $sel = 0; $lastPoll = [datetime]::MinValue; $msg = ''
    $prevLive = @{}; foreach ($t in @($State.tasks)) { $prevLive[$t.id] = $t.live }
    $commits = @{}   # nombre de commits par tâche (recalculé toutes les 2 s, pas à chaque image)
    $autoAdv = @{}   # dernier appel automatique du conseiller par tâche (au plus un toutes les 5 min)
    foreach ($t in @($State.tasks)) { $autoAdv[$t.id] = [datetime]::MinValue; if ($t.advisor -eq 'running') { $t.advisor = '' } }
    # relecture interrompue par une fermeture de la fenêtre : elle sera relancée
    foreach ($t in @($State.tasks)) { if ($t.review -eq 'pending' -and -not $RevJobs.ContainsKey($t.id)) { $t.review = ''; $t.reviewSeen = '' } }
    New-Item -ItemType Directory -Force (Join-Path $RunDir 'annonces'), (Join-Path $RunDir 'relectures') | Out-Null
    Cls
    while ($true) {
        $ts = @($State.tasks)
        if (((Get-Date) - $lastPoll).TotalSeconds -ge 2) {
            $lastPoll = Get-Date
            foreach ($t in $ts) {
                if ($t.status -eq 'pending') {
                    $wait = @(Deps $t | Where-Object { (Task-ById $_).status -ne 'done' })
                    $bad = @(Deps $t | Where-Object { (Task-ById $_).status -eq 'failed' })
                    if ($bad.Count) { $t.status = 'failed'; $t.error = "dépendance en échec : $($bad -join ', ')" }
                    elseif (-not $wait.Count) { try { Start-Task $t } catch { $t.status = 'failed'; $t.error = $_.Exception.Message } }
                    $t.live = if ($t.status -eq 'pending') { "attend $($wait -join ', ')" } else { '' }
                }
                elseif ($t.status -eq 'running') {
                    if (Test-Path -LiteralPath (Result-File $t.id)) {
                        # compte-rendu écrit : relecture croisée par un autre compte, puis seulement « terminée »
                        $stamp = [string](Get-Item -LiteralPath (Result-File $t.id)).LastWriteTimeUtc.Ticks
                        if ($RevJobs.ContainsKey($t.id)) { $t.live = 'review' }
                        elseif (-not $State.crossReview -or $t.review -in 'ok', 'impossible' -or -not $t.worktree) { Finish-Task $t }
                        elseif ($stamp -ne [string]$t.reviewSeen) {
                            if ([int]$t.reviews -ge $MaxReviews) { Finish-Task $t }   # il a répondu à la dernière relecture
                            else {
                                $t.reviewSeen = $stamp; Start-Review $t; $t.live = 'review'
                                if ($Psmux) { Set-PaneState $t.id 'busy' "⌕ relecture par $((Acct-ById $t.reviewer).Short)" }
                            }
                        }
                        else { $t.live = 'fixing' }   # corrections demandées : on attend la mise à jour du compte-rendu
                    } elseif ($Psmux -and -not (Find-Pane $t.id)) {
                        $t.live = 'closed'
                    } else {
                        $t.live = Claude-State (Acct-ById $t.account) $t.worktree
                        if ($t.live -ne $prevLive[$t.id] -and $Psmux) {
                            switch ($t.live) {
                                'working' { Set-PaneState $t.id 'busy' '● travaille' }
                                'waiting' { Set-PaneState $t.id 'done' '✋ attend ta réponse' }
                            }
                        }
                        if ($t.live -eq 'waiting' -and $prevLive[$t.id] -eq 'working') { Notify "✋ Tâche $($t.id) attend ta réponse" $t.title }
                    }
                }
                $prevLive[$t.id] = $t.live
                if ($t.status -in 'running', 'done') { $commits[$t.id] = Commits-Of $t }
                # annonce écrite par l'ouvrier : relayée aux autres ouvriers au travail
                if ($t.status -in 'running', 'done' -and (Test-Path -LiteralPath (Announce-File $t.id))) {
                    $as = [string](Get-Item -LiteralPath (Announce-File $t.id)).LastWriteTimeUtc.Ticks
                    if ($as -ne [string]$t.annSeen) {
                        $t.annSeen = $as
                        Tell-Others $t.id "[FLOW] Annonce de l'ouvrier $($t.id) ($($t.title)) : lis $(Announce-File $t.id) (dernières lignes). Si elle concerne ta tâche, adapte-toi ; sinon continue sans t'interrompre."
                        $msg = "$Info⇄ annonce de $($t.id) relayée aux autres ouvriers$R"
                    }
                }
                # besoin d'un conseiller ? (question écrite par l'ouvrier, ou erreurs à la chaîne)
                if ($t.status -eq 'running' -and $t.worktree -and -not $AdvJobs.ContainsKey($t.id)) {
                    $hf = Help-File $t.id
                    if (Test-Path -LiteralPath $hf) {
                        $stamp = [string](Get-Item -LiteralPath $hf).LastWriteTimeUtc.Ticks
                        if ($stamp -ne [string]$t.helpSeen) { $t.helpSeen = $stamp; Start-Advisor $t "il a écrit une question dans $hf"; $msg = "$Info◈ $($t.id) a demandé de l'aide : conseiller $(Advisor-Model $t.model) en route$R" }
                    }
                    if (-not $AdvJobs.ContainsKey($t.id) -and ($autoAdv[$t.id] -lt (Get-Date).AddMinutes(-5))) {
                        $ne = Recent-Errors $t
                        if ($ne -ge 3) { $autoAdv[$t.id] = Get-Date; Start-Advisor $t "il enchaîne $ne erreurs d'outils"; $msg = "$Warn◈ $($t.id) enchaîne les erreurs : conseiller $(Advisor-Model $t.model) appelé$R" }
                    }
                }
            }
            Check-Advisors
            $rn = Check-Reviews; if ($rn) { $msg = $rn }
            Write-Board
            Save-State
            $open = @($ts | Where-Object { $_.status -in 'pending', 'running' })
            if (-not $open.Count) {
                Notify '⚑ Équipe : toutes les tâches sont finies' 'Intégration en cours, puis validation.'
                $State.status = 'integrating'; Save-State
                return 'integrate'
            }
        }

        $W = [Math]::Max(40, (ConW) - 1)
        $L = [Collections.Generic.List[string]]::new()
        $L.Add(''); $L.Add("  $(Grad '⚑ ÉQUIPE — au travail' ($script:Tick * 0.01))   $Dm$($State.id)$R")
        $L.Add("  $B$($State.summary)$R"); $L.Add("  $(Accounts-Line)"); $L.Add('')
        $runRows = @()
        for ($i = 0; $i -lt $ts.Count; $i++) {
            $t = $ts[$i]
            $mark = if ($i -eq $sel) { "$(PalC 0.1)$B▸$R" } else { ' ' }
            $st = switch ($t.status) {
                'pending' { "$Dm⏳ $($t.live)$R" }
                'done'    { "$Ok✓ terminée$(if ([int]$t.reviews) { " · relue par $((Acct-ById $t.reviewer).Short)" })$R" }
                'failed'  { "$Err✗ $($t.error)$R" }
                default {
                    switch ($t.live) {
                        'review'   { "$Info⌕ relecture croisée par $((Acct-ById $t.reviewer).Short) $($Spin[$script:Tick % 10])$R" }
                        'fixing'   { "$Warn✎ corrige après relecture n°$($t.reviews)$R" }
                        'working'  { "$Warn$($Spin[$script:Tick % 10]) travaille$R" }
                        'waiting'  { "$B$Teal✋ attend ta réponse$R" }
                        'closed'   { "$Err○ panneau fermé (L pour relancer)$R" }
                        default    { "$Dm… démarre$R" }
                    }
                }
            }
            $cm = if ($commits.ContainsKey($t.id)) { " $Dm$($commits[$t.id]) commit(s)$R" } else { '' }
            $adv = if ($AdvJobs.ContainsKey($t.id)) { "  $(RgbA @(200,140,255))◈ conseiller $($AdvJobs[$t.id].Model) $($Spin[$script:Tick % 10])$R" }
                   elseif ([int]$t.advice) { "  $Dm◈ conseillée ×$($t.advice)$R" } else { '' }
            $runRows += @{ Y = $L.Count; Row = $i }
            $L.Add("  $mark $B$($t.id)$R  $(Acct-Chip $t.account)  $(Model-Chip $t.model)  $(Fit $t.title 30)  $st$cm$adv")
        }
        $L.Add('')
        $t = $ts[$sel]
        foreach ($x in @(Chunks $t.goal ($W - 8)) | Select-Object -First 3) { $L.Add("    $Dm$x$R") }
        if ($t.worktree) { $L.Add("    $Dm dossier : $($t.worktree)$R") }
        $L.Add('')
        if ((Test-Path -LiteralPath (Review-File $t.id)) -and [int]$t.reviews) { $L.Add("    $Dm relecture(s) : $(Review-File $t.id)$R") }
        $L.Add("  $Dm relecture croisée : $(if ($State.crossReview) { "activée (au plus $MaxReviews par tâche)" } else { 'désactivée' }) · V pour changer · tableau partagé : TABLEAU.md$R")
        if ($Psmux) { $L.Add("  $Dm Les ouvriers sont dans la fenêtre « equipe » (Ctrl+B puis 2 ; Ctrl+B puis 1 pour revenir ici).$R") }
        $L.Add((Keys @('↑↓', 'choisir', 'Entrée', 'voir l''ouvrier', 'M', 'lui écrire', 'C', 'appeler son conseiller', 'T', 'terminée', 'V', 'relecture', 'L', 'relancer', 'I', 'intégrer', 'X', 'abandonner')))
        if ($msg) { $L.Add("  $msg") }
        Show-Frame $L
        foreach ($rr in $runRows) { Add-Zone $rr.Y $rr.Y 0 999 @{ Row = $rr.Row } }   # chaque ouvrier est cliquable
        $script:Tick++

        $deadline = (Get-Date).AddMilliseconds(250)
        while ((Get-Date) -lt $deadline) {
            $act = Read-Action
            if (-not $act) { Start-Sleep -Milliseconds 40; continue }
            if ($act.Click) {
                # clic : choisir l'ouvrier ; 2e clic ou double-clic : aller à son panneau
                $q = $act.Click.Row
                if ($q -eq $sel -or $act.Double) { $k = Fake-Key 'Enter' } else { $sel = $q; $msg = ''; continue }
            } else { $k = $act.K }
            $ch = "$($k.KeyChar)".ToLower()
            $t = $ts[$sel]
            if ($k.Key -eq 'UpArrow') { $sel = ($sel - 1 + $ts.Count) % $ts.Count; $msg = '' }
            elseif ($k.Key -eq 'DownArrow') { $sel = ($sel + 1) % $ts.Count; $msg = '' }
            elseif ($k.Key -eq 'Enter') { if (-not (Focus-Pane $t.id)) { $msg = "$Dm(pas de panneau ouvert pour $($t.id))$R" } }
            elseif ($ch -eq 'm' -and $t.status -eq 'running') {
                $txt = Read-Line "⚑ ÉQUIPE — message pour l'ouvrier $($t.id)" "Ce que tu veux dire à « $($t.title) » ($($t.model)) :"
                Cls
                if ($txt) { $msg = if (Send-ToPane $t.id $txt) { "$Ok✓ message envoyé à $($t.id)$R" } else { "$Err✗ panneau de $($t.id) introuvable (L pour le relancer)$R" } }
            }
            elseif ($ch -eq 'c' -and $t.status -eq 'running' -and $t.worktree) {
                if ($AdvJobs.ContainsKey($t.id)) { $msg = "$Dm(le conseiller de $($t.id) travaille déjà)$R" }
                else {
                    $why = Read-Line "⚑ ÉQUIPE — conseiller pour $($t.id)" 'Qu''est-ce qui coince ? (facultatif, Entrée pour laisser le conseiller juger)'
                    Cls
                    if ($null -ne $why) { Start-Advisor $t $(if ($why) { "l'utilisateur signale : $why" } else { 'l''utilisateur demande un avis sur la tâche' }); $msg = "$Info◈ conseiller $(Advisor-Model $t.model) appelé pour $($t.id)$R" }
                }
            }
            elseif ($ch -eq 'v') { $State.crossReview = -not $State.crossReview; Save-State; $msg = "$Info relecture croisée $(if ($State.crossReview) { 'activée' } else { 'désactivée' }) pour les tâches à venir$R" }
            elseif ($ch -eq 't' -and $t.status -eq 'running') {
                $t.review = 'ok'   # décision de l'utilisateur : acceptée sans (autre) relecture
                if (-not (Test-Path -LiteralPath (Result-File $t.id))) {
                    Set-Content -LiteralPath (Result-File $t.id) "# Tâche $($t.id)`n`n(marquée terminée à la main par l'utilisateur)`n" -Encoding utf8
                }
                $lastPoll = [datetime]::MinValue; $msg = "$Ok✓ $($t.id) marquée terminée$R"
            }
            elseif ($ch -eq 'l' -and $t.status -eq 'running' -and $t.worktree) {
                $acct = Acct-ById $t.account
                Open-Pane $t.id "⚑ $($t.id) · $($t.title) · $($acct.Short) · $($t.model)" (Pane-Cmd $t.worktree $acct '' -Continue -Model $t.model) $t.worktree
                $msg = "$Info↻ ouvrier $($t.id) relancé (conversation reprise)$R"
            }
            elseif ($ch -eq 'i') {
                $left = @($ts | Where-Object { $_.status -in 'pending', 'running' })
                if ($left.Count) {
                    $k2 = Message-Screen '⚑ ÉQUIPE — intégrer maintenant ?' @("$($left.Count) tâche(s) pas finie(s) : $($left.id -join ', ').", 'Elles seront laissées de côté (leurs panneaux restent ouverts).') @('O', 'intégrer quand même', 'Échap', 'retour')
                    Cls
                    if ("$($k2.KeyChar)".ToLower() -ne 'o') { continue }
                    foreach ($x in $left) { $x.status = 'failed'; $x.error = 'laissée de côté' }
                }
                $State.status = 'integrating'; Save-State
                return 'integrate'
            }
            elseif ($ch -eq 'x') {
                $go = Confirm-Discard '⚑ ÉQUIPE — abandonner l''équipe ?'
                Cls
                if ($go) { $arch = @(Cleanup-Run -Abandon); $State.status = 'discarded'; Save-State; Show-Archive $arch; return 'home' }
            }
        }
    }
}

function Project-Checks {
    # vérifications à lancer sur la branche d'intégration : -TestCommand (FLOW) sinon le profil du projet
    if ($TestCommand) { return @([pscustomobject]@{ name = 'tests'; cmd = $TestCommand }) }
    @($Cfg.checks | Where-Object { $_ -and $_.cmd })
}

function Run-Checks([string]$dir) {
    # préparation de la copie puis chaque vérification, dans l'ordre ; résultat détaillé par vérification
    $checks = Project-Checks
    if (-not $checks.Count) { return @() }
    Prepare-Copy $dir
    $spec = ConvertTo-Json -Compress -Depth 4 @(@($(if ($Cfg.setup) { [pscustomobject]@{ name = 'préparation'; cmd = [string]$Cfg.setup } })) + $checks | Where-Object { $_ })
    $envPre = Git-Env
    $job = Start-Job -ScriptBlock {
        param($d, $spec, $envPre)
        $out = @()
        foreach ($c in ($spec | ConvertFrom-Json)) {
            $o = & pwsh -NoProfile -Command "Set-Location -LiteralPath '$($d -replace "'", "''")'; $envPre$($c.cmd)" 2>&1 | Out-String
            $out += [pscustomobject]@{ name = $c.name; cmd = $c.cmd; code = $LASTEXITCODE; out = $o }
            if ($c.name -eq 'préparation' -and $LASTEXITCODE -ne 0) { break }
        }
        $out
    } -ArgumentList $dir, $spec, $envPre
    $rv = Wait-Job-Spinner $job "vérifications du projet sur la branche d'intégration : $(($checks | ForEach-Object { $_.name }) -join ', ')"
    if ($null -eq $rv) { return @([pscustomobject]@{ name = 'vérifications'; cmd = ''; ok = $false; ran = $false; tail = @('(annulées)') }) }
    $log = foreach ($x in @($rv)) { "===== $($x.name) : $($x.cmd) (code $($x.code))"; $x.out }
    Set-Content -LiteralPath (Join-Path $RunDir 'verifications.txt') ($log -join "`n") -Encoding utf8
    @($rv | ForEach-Object {
            [pscustomobject]@{ name = $_.name; cmd = $_.cmd; ok = ($_.code -eq 0); ran = $true
                tail = @(("$($_.out)" -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 8) }
        })
}

function Final-Title {
    $t = if ($State.commitTitle) { [string]$State.commitTitle } else { [string]$State.summary }
    if ($Cfg.commitStyle -eq 'conventional' -and $t -notmatch '^\w+(\([^)]*\))?!?: ') { $t = "feat: $t" }
    $t
}
function Final-Body {
    $lines = @("Travail réalisé par une équipe FLOW ($($State.id)) :")
    foreach ($t in @($State.tasks)) { if ($t.id -in @($State.integration.merged)) { $lines += "- $($t.id) : $($t.title)" } }
    $lines -join "`n"
}

function Mode-Integrate {
    $ib = Int-Branch; $iw = Int-Dir
    $log = [Collections.Generic.List[string]]::new()
    function Show-Log { Cls; Show-Frame (@('', "  $(Grad '⚑ ÉQUIPE — intégration' 0.1)", '') + @($log | ForEach-Object { "  $_" })) }

    if (-not (Test-Path -LiteralPath $iw)) {
        $o = Git-In $RepoRoot @('worktree', 'add', '-b', $ib, $iw, $State.base)
        if ($GitCode -ne 0) { [void](Message-Screen '⚑ ÉQUIPE' @("$Err impossible de créer la branche d'intégration : $($o | Select-Object -Last 1)$R") @('Entrée', 'retour')); return 'quit' }
    }
    $merged = @($State.integration.merged)
    $skipped = @($State.integration.skipped)

    # fusion en cours (conflit résolu par l'intégrateur ?)
    if ($State.integration.conflict) {
        $cid = $State.integration.conflict
        [void](Git-In $iw @('rev-parse', '-q', '--verify', 'MERGE_HEAD'))
        $inMerge = $GitCode -eq 0
        $unmerged = @(Git-In $iw @('diff', '--name-only', '--diff-filter=U') | Where-Object { $_ })
        if ($inMerge -or $unmerged.Count) {
            $t = Task-ById $cid
            $k = Message-Screen '⚑ ÉQUIPE — conflit de fusion' @(
                "La tâche $B$cid$R ($($t.title)) entre en conflit avec le travail déjà fusionné :",
                "$Warn$($unmerged -join '   ')$R", '',
                'C = lancer un Claude intégrateur pour résoudre (il termine la fusion lui-même), puis Entrée ici.',
                'A = laisser cette tâche de côté · Entrée = vérifier à nouveau') @('C', 'intégrateur', 'A', 'laisser de côté', 'Entrée', 'vérifier', 'Échap', 'plus tard')
            $ch = "$($k.KeyChar)".ToLower()
            if ($k.Key -eq 'Escape') { return 'quit' }
            if ($ch -eq 'c') {
                $pf = Join-Path $RunDir "taches\_integration-$cid.prompt.md"
                Set-Content -LiteralPath $pf (Integrator-Prompt $t $unmerged) -Encoding utf8
                $acct = Least-Loaded
                Open-Pane "_int-$cid" "⚑ intégration · $cid · $($acct.Short) · opus" (Pane-Cmd $iw $acct $pf -Model 'opus') $iw
                [void](Focus-Pane "_int-$cid")
            }
            elseif ($ch -eq 'a') {
                [void](Git-In $iw @('merge', '--abort'))
                $skipped += $cid; $State.integration.skipped = $skipped; $State.integration.conflict = ''; Save-State
            }
            return 'integrate'
        }
        $tc = Task-ById $cid
        [void](Git-In $iw @('merge-base', '--is-ancestor', (Task-Branch $tc), 'HEAD'))
        if ($GitCode -eq 0) {
            $merged += $cid; $State.integration.merged = $merged; $State.integration.conflict = ''; Save-State
            $log.Add("$Ok✓ conflit de $cid résolu$R")
        } else {
            # aucune fusion en cours et la branche n'est pas dans l'intégration : fusion abandonnée ou refusée
            $why = [string]$State.integration.conflictMsg
            $k = Message-Screen '⚑ ÉQUIPE — fusion non terminée' @(
                "La tâche $B$cid$R ($($tc.title)) n'est $B$Err PAS$R dans la branche d'intégration : la fusion a été abandonnée ou refusée.",
                $(if ($why) { "$Dm$why$R" } else { '' }), '',
                'Entrée / R = réessayer la fusion · A = laisser cette tâche de côté (son travail est conservé)') @('R', 'réessayer', 'A', 'laisser de côté', 'Échap', 'plus tard')
            if ($k.Key -eq 'Escape') { return 'quit' }
            if ("$($k.KeyChar)".ToLower() -eq 'a') { $skipped += $cid; $State.integration.skipped = $skipped }
            $State.integration.conflict = ''; Save-State
            return 'integrate'
        }
    }

    foreach ($t in (Topo @($State.tasks))) {
        if ($t.id -in $merged -or $t.id -in $skipped) { continue }
        if ($t.status -ne 'done') { $skipped += $t.id; $log.Add("$Dm– $($t.id) laissée de côté ($($t.status))$R"); continue }
        # travail non commité dans la copie de l'ouvrier : on le garde
        if ($t.worktree -and (Test-Path -LiteralPath $t.worktree)) {
            $d = @(Git-In $t.worktree @('status', '--porcelain') | Where-Object { $_ })
            if ($d.Count) {
                $oa = Git-In $t.worktree @('add', '-A'); $c1 = $GitCode
                $oc = Git-In $t.worktree @('commit', '-q', '--no-verify', '-m', "tâche $($t.id) : changements non commités"); $c2 = $GitCode
                if ($c1 -ne 0 -or $c2 -ne 0) {
                    # ne pas fusionner sans ses changements : la tâche est laissée de côté et sa copie reste intacte
                    $skipped += $t.id; $State.integration.skipped = $skipped; Save-State
                    Write-FlowLog "commit automatique de $($t.id) impossible : tâche laissée de côté" 'ERREUR'
                    $why = (@($(if ($c1 -ne 0) { $oa } else { $oc })) | Where-Object { "$_".Trim() } | Select-Object -Last 1)
                    $log.Add("$Err✗ $($t.id) : le commit automatique de ses changements a échoué ($why) : tâche laissée de côté, sa copie est conservée : $($t.worktree)$R")
                    continue
                }
                $log.Add("$Warn• $($t.id) : $($d.Count) changement(s) non commité(s) ajouté(s)$R")
            }
        }
        $log.Add("$Info→ fusion de $($t.id) — $($t.title)$R"); Show-Log
        $om = Git-In $iw @('merge', '--no-ff', '--no-edit', '-m', "flow: tâche $($t.id) — $($t.title)", (Task-Branch $t))
        if ($GitCode -ne 0) {
            Write-FlowLog "fusion de $($t.id) refusée ou en conflit : $((@($om) | Where-Object { "$_".Trim() } | Select-Object -Last 1))" 'WARN'
            $State.integration | Add-Member -NotePropertyName conflictMsg -NotePropertyValue ((@($om) | Where-Object { "$_".Trim() } | Select-Object -Last 2) -join ' / ') -Force
            $State.integration.conflict = $t.id; $State.integration.merged = $merged; $State.integration.skipped = $skipped; Save-State
            Notify "⚠ Conflit de fusion (tâche $($t.id))" 'Ouvre la fenêtre Équipe pour le résoudre.'
            return 'integrate'
        }
        $merged += $t.id
        $State.integration.merged = $merged; $State.integration.skipped = $skipped; Save-State
    }

    # contrôle : toute tâche annoncée fusionnée est bien dans la branche d'intégration
    $gone = @($merged | Where-Object { [void](Git-In $iw @('merge-base', '--is-ancestor', (Task-Branch (Task-ById $_)), 'HEAD')); $GitCode -ne 0 })
    if ($gone.Count) {
        $merged = @($merged | Where-Object { $_ -notin $gone }); $State.integration.merged = $merged
        $State.integration.checks = @(); Save-State
        return 'integrate'
    }
    # vérifications du projet (lint, types, tests, build…) sur la branche d'intégration
    if (-not @($State.integration.checks).Count) { $State.integration.checks = @(Run-Checks $iw) }
    $State.status = 'review'; Save-State
    Notify '⚑ Équipe : prêt à valider' "$($merged.Count) tâche(s) fusionnée(s) sur la branche d'intégration."
    'review'
}

function Archive-Ref($t) { "refs/flow-archive/$($State.id)/$($t.id)" }

function Backup-Task($t) {
    # met à l'abri les fichiers non commités d'une tâche (commit de sauvegarde). Renvoie $true si sa copie peut être supprimée
    # sans rien perdre (propre, ou sauvegardée) ; $false si la sauvegarde a échoué : la copie doit alors être gardée.
    if (-not ($t.worktree -and (Test-Path -LiteralPath $t.worktree))) { return $true }
    $d = @(Git-In $t.worktree @('status', '--porcelain') | Where-Object { $_ })
    if (-not $d.Count) { return $true }
    [void](Git-In $t.worktree @('add', '-A'))
    if ($GitCode -ne 0) { return $false }
    [void](Git-In $t.worktree @('commit', '-q', '--no-verify', '-m', "flow: sauvegarde de la tâche $($t.id) avant nettoyage"))
    $GitCode -eq 0
}

function Cleanup-Run([switch]$KeepIntegration, [switch]$Abandon) {
    # Supprime les copies de travail et les branches de l'équipe SANS RIEN PERDRE : le travail non commité est sauvegardé,
    # et la branche de toute tâche qui n'est pas dans l'intégration (ou de toute l'équipe si on abandonne) est conservée
    # sous refs/flow-archive/<équipe>/<tâche>. Renvoie des lignes d'information pour l'utilisateur.
    $notes = [Collections.Generic.List[string]]::new()
    Kill-TeamPanes
    $ib = Int-Branch
    [void](Git-In $RepoRoot @('rev-parse', '--verify', '-q', "refs/heads/$ib")); $ibOk = $GitCode -eq 0
    foreach ($t in @($State.tasks)) {
        $br = Task-Branch $t
        [void](Git-In $RepoRoot @('rev-parse', '--verify', '-q', "refs/heads/$br")); $brOk = $GitCode -eq 0
        if (-not (Backup-Task $t)) { $notes.Add("la copie de $($t.id) est conservée (sa sauvegarde a échoué) : $($t.worktree)"); continue }
        if ($brOk) {
            $inInt = $false
            if ($ibOk -and -not $Abandon) { [void](Git-In $RepoRoot @('merge-base', '--is-ancestor', $br, $ib)); $inInt = $GitCode -eq 0 }
            if (-not $inInt) {
                [void](Git-In $RepoRoot @('update-ref', (Archive-Ref $t), $br))
                if ($GitCode -ne 0) { $notes.Add("la branche de $($t.id) est conservée ($br) : l'archivage a échoué"); continue }
                $notes.Add("tâche $($t.id) ($($t.title)) mise de côté : $(Archive-Ref $t)")
            }
        }
        if ($t.worktree -and (Test-Path -LiteralPath $t.worktree)) { [void](Git-In $RepoRoot @('worktree', 'remove', '--force', $t.worktree)) }
        if ($brOk) { [void](Git-In $RepoRoot @('branch', '-D', $br)) }
    }
    if (Test-Path -LiteralPath (Int-Dir)) { [void](Git-In $RepoRoot @('worktree', 'remove', '--force', (Int-Dir))) }
    if (-not $KeepIntegration -and $ibOk) {
        if ($Abandon) {
            [void](Git-In $RepoRoot @('update-ref', "refs/flow-archive/$($State.id)/_integration", $ib))
            if ($GitCode -eq 0) { $notes.Add("assemblage mis de côté : refs/flow-archive/$($State.id)/_integration") }
        }
        [void](Git-In $RepoRoot @('branch', '-D', $ib))
    }
    [void](Git-In $RepoRoot @('worktree', 'prune'))
    if ((Test-Path -LiteralPath $WtRoot) -and -not (Get-ChildItem -LiteralPath $WtRoot -Force)) { Remove-Item -LiteralPath $WtRoot }
    # ménage des archives de plus de 60 jours
    $old = [DateTimeOffset]::UtcNow.AddDays(-60).ToUnixTimeSeconds()
    foreach ($l in @(Git-In $RepoRoot @('for-each-ref', '--format=%(refname) %(committerdate:unix)', 'refs/flow-archive/'))) {
        $p = "$l" -split ' '
        if ($p.Count -eq 2 -and $p[1] -match '^\d+$' -and [long]$p[1] -lt $old) { [void](Git-In $RepoRoot @('update-ref', '-d', $p[0])) }
    }
    foreach ($n in $notes) { Write-FlowLog "nettoyage de l'équipe $($State.id) : $n" 'WARN' }
    $notes
}

function Archive-Lines($lines) {
    # texte à montrer après un nettoyage qui a mis du travail de côté
    $l = @($lines | Where-Object { $_ })
    if (-not $l.Count) { return @() }
    @('', "$Warn Travail mis de côté (rien n'est perdu) :$R") + @($l | ForEach-Object { "  • $_" }) +
        @('', "$Dm Pour retrouver une tâche : git branch <nom> refs/flow-archive/$($State.id)/<lettre de la tâche>$R")
}

function Show-Archive($lines) {
    $l = @(Archive-Lines $lines)
    if (-not $l.Count) { return }
    [void](Message-Screen '⚑ ÉQUIPE — travail mis de côté' $l @('Entrée', 'continuer'))
    Cls
}

function Confirm-Discard([string]$title) {
    # abandon de l'équipe : on chiffre ce qui part, et on demande une touche volontaire (pas une double frappe)
    $rows = foreach ($t in @($State.tasks)) {
        if (-not ($t.worktree -and (Test-Path -LiteralPath $t.worktree))) { continue }
        $dirty = @(Git-In $t.worktree @('status', '--porcelain') | Where-Object { $_ }).Count
        "  $B$($t.id)$R $($t.title) : $(Commits-Of $t) commit(s), $dirty fichier(s) non commité(s)"
    }
    $k = Message-Screen $title (@('L''équipe va être retirée de ton projet (copies de travail et branches temporaires) :', '') + @($rows) + @('',
            "$Ok Rien n'est détruit : chaque tâche, même non terminée, est mise de côté dans Git (refs/flow-archive/…) et je te dirai comment la retrouver.$R",
            "$Dm Ton dossier de projet n'est pas touché.$R")) @('O', 'abandonner l''équipe', 'Échap', 'annuler')
    "$($k.KeyChar)".ToLower() -eq 'o'
}

function Deliver-Run([string]$dlv, [string]$target, [string]$cur) {
    # livraison selon le workflow du projet ; renvoie @{ Ok ; Info }
    $ib = Int-Branch; $title = Final-Title; $body = Final-Body
    switch ($dlv) {
        { $_ -in 'merge', 'squash' } {
            if ($cur -ne $target) { return @{ Ok = $false; Info = "$Err✗ ton dossier est sur « $cur » et la cible est « $target » : bascule sur $target (git switch $target), puis F$R" } }
            $dirty = Dirty-Files -TrackedOnly
            if ($dirty.Count) { return @{ Ok = $false; Info = "$Err✗ ton dossier a $($dirty.Count) modification(s) non commitée(s) : commit-les ou mets-les de côté (git stash), puis F$R" } }
            if ($dlv -eq 'merge') {
                [void](Git-In $RepoRoot @('merge', '--no-ff', '-m', $title, '-m', $body, $ib))
                if ($GitCode -ne 0) { [void](Git-In $RepoRoot @('merge', '--abort')); return @{ Ok = $false; Info = "$Err✗ « $target » a changé depuis le départ et la fusion est en conflit : rien n'a été modifié. Fusionne $ib à la main (O).$R" } }
            } else {
                [void](Git-In $RepoRoot @('merge', '--squash', $ib))
                if ($GitCode -ne 0) { [void](Git-In $RepoRoot @('reset', '--merge')); return @{ Ok = $false; Info = "$Err✗ conflit en appliquant le squash : rien n'a été modifié. Fusionne $ib à la main (O).$R" } }
                [void](Git-In $RepoRoot @('commit', '-q', '-m', $title, '-m', $body))
                if ($GitCode -ne 0) { [void](Git-In $RepoRoot @('reset', '--merge')); return @{ Ok = $false; Info = "$Err✗ le commit final a échoué (hook du projet ?) : rien n'a été modifié.$R" } }
            }
            $arch = @(Cleanup-Run)
            return @{ Ok = $true; Archive = $arch; Info = "Le travail de l'équipe est dans $target ($(if ($dlv -eq 'merge') { 'merge' } else { 'un commit' }) : « $title »)." }
        }
        'pr' {
            if (-not (Has-Cmd 'gh')) { return @{ Ok = $false; Info = "$Err✗ GitHub CLI absent : winget install --id GitHub.cli, puis gh auth login (ou L pour une autre livraison)$R" } }
            $o = Git-In $RepoRoot @('push', '-u', 'origin', $ib)
            if ($GitCode -ne 0) { return @{ Ok = $false; Info = "$Err✗ push impossible : $($o | Select-Object -Last 1)$R" } }
            $bf = Join-Path $RunDir 'pull-request.md'
            $prBody = @($body, '') + @(@($State.tasks) | Where-Object { Test-Path -LiteralPath (Result-File $_.id) } | ForEach-Object { "### $($_.id) — $($_.title)"; Get-Content -LiteralPath (Result-File $_.id) -Raw; '' })
            Set-Content -LiteralPath $bf ($prBody -join "`n") -Encoding utf8
            Push-Location -LiteralPath $RepoRoot
            try { $url = & gh pr create --base $target --head $ib --title $title --body-file $bf 2>&1 | Out-String; $code = $LASTEXITCODE } finally { Pop-Location }
            if ($code -ne 0) { return @{ Ok = $false; Info = "$Err✗ gh pr create : $(($url.Trim() -split "`n")[-1])$R" } }
            $arch = @(Cleanup-Run -KeepIntegration)
            return @{ Ok = $true; Archive = $arch; Info = "Pull request ouverte : $($url.Trim())" }
        }
        'branch' {
            $remote = Git-In $RepoRoot @('remote')
            $pushed = $false
            if (@($remote | Where-Object { $_ -eq 'origin' }).Count) { [void](Git-In $RepoRoot @('push', '-u', 'origin', $ib)); $pushed = $GitCode -eq 0 }
            $arch = @(Cleanup-Run -KeepIntegration)
            return @{ Ok = $true; Archive = $arch; Info = "Branche « $ib » prête$(if ($pushed) { ' et poussée sur origin' }) : à fusionner selon le workflow du projet." }
        }
    }
    @{ Ok = $false; Info = "$Err✗ mode de livraison inconnu : $dlv$R" }
}

function Mode-Review {
    $iw = Int-Dir; $ib = Int-Branch; $msg = ''
    Cls
    while ($true) {
        $W = [Math]::Max(40, (ConW) - 1)
        $L = [Collections.Generic.List[string]]::new()
        $L.Add(''); $L.Add("  $(Grad '⚑ ÉQUIPE — à valider' 0.1)   $Dm$($State.id)$R")
        $L.Add("  $B$($State.summary)$R"); $L.Add('')
        $merged = @($State.integration.merged); $skipped = @($State.integration.skipped)
        $L.Add("  $Dm branche d'intégration$R $ib   $Dm dossier$R $iw")
        $L.Add("  $Ok✓ fusionnées : $(if ($merged) { $merged -join ', ' } else { 'aucune' })$R$(if ($skipped) { "   $Warn laissées de côté : $($skipped -join ', ')$R" })")
        $chks = @($State.integration.checks)
        if ($chks.Count) {
            $L.Add("  $B Vérifications$R  " + (($chks | ForEach-Object { if ($_.ok) { "$Ok✓ $($_.name)$R" } elseif ($_.ran) { "$Err✗ $($_.name)$R" } else { "$Dm– $($_.name)$R" } }) -join '   '))
            foreach ($c in ($chks | Where-Object { $_.ran -and -not $_.ok } | Select-Object -First 1)) {
                $L.Add("    $Dm$($c.cmd) — détail : $(Join-Path $RunDir 'verifications.txt')$R")
                foreach ($x in @($c.tail) | Select-Object -Last 4) { $L.Add("    $Dm$x$R") }
            }
        } else { $L.Add("  $Dm(aucune vérification configurée — F2 dans l'accueil pour le profil du projet)$R") }
        $L.Add('')
        $L.Add("  $B Changements$R")
        foreach ($x in @(Git-In $iw @('diff', '--stat', "$($State.base)..HEAD")) | Select-Object -Last 10) { $L.Add("    $Dm$x$R") }
        $L.Add('')
        $L.Add("  $B Comptes-rendus$R")
        foreach ($t in @($State.tasks)) {
            $rf = Result-File $t.id
            $first = if (Test-Path -LiteralPath $rf) { @(Get-Content -LiteralPath $rf -Encoding utf8 | Where-Object { $_.Trim() -and $_ -notmatch '^#' } | Select-Object -First 1) } else { @('(pas de compte-rendu)') }
            $L.Add("    $B$($t.id)$R $(Acct-Chip $t.account) $Dm$(Fit "$first" ($W - 16))$R")
        }
        $L.Add('')
        $cur = (Git-In $RepoRoot @('rev-parse', '--abbrev-ref', 'HEAD') | Select-Object -First 1).Trim()
        $dlv = if ($State.deliver) { [string]$State.deliver } else { 'merge' }
        $target = if ($State.baseBranch) { $State.baseBranch } else { $cur }
        $fLabel = switch ($dlv) {
            'squash' { "squash dans $target" }
            'pr'     { "ouvrir une pull request vers $target" }
            'branch' { 'garder la branche (et la pousser)' }
            default  { "fusionner dans $target" }
        }
        $L.Add("  $Dm commit final : « $(Final-Title) »$R")
        $L.Add((Keys @('F', $fLabel, 'L', 'autre livraison', 'D', 'diff', 'O', 'terminal', 'J', 'jeter', 'Échap', 'plus tard')))
        if ($msg) { $L.Add("  $msg") }
        Show-Frame $L
        $k = (Read-KeyOrHint); $ch = "$($k.KeyChar)".ToLower()
        if ($k.Key -eq 'Escape') { return 'quit' }
        elseif ($ch -eq 'd') {
            $c = "Set-Location -LiteralPath $(Q $iw); $(Git-Env)git diff $($State.base)..HEAD"
            Open-Pane '_diff' "⚑ diff · $($State.id)" $c $iw; [void](Focus-Pane '_diff')
            $msg = "$Dm diff ouvert dans la fenêtre « equipe » (q pour quitter le diff)$R"
        }
        elseif ($ch -eq 'o') {
            Open-Pane '_shell' "⚑ intégration · terminal" "Set-Location -LiteralPath $(Q $iw); $(Git-Env)Clear-Host; git log --oneline -n 12" $iw; [void](Focus-Pane '_shell')
            $msg = "$Dm terminal ouvert sur la branche d'intégration$R"
        }
        elseif ($ch -eq 'l') {
            $order = 'merge', 'squash', 'pr', 'branch'
            $State.deliver = $order[([array]::IndexOf($order, $dlv) + 1) % $order.Count]; Save-State
            $msg = "$Dm livraison pour cette équipe : $(Deliver-Label $State.deliver)$R"
        }
        elseif ($ch -eq 'f') {
            # 1) chaque tâche dite fusionnée doit réellement être dans la branche d'intégration
            $gone = @($merged | Where-Object { $tt = Task-ById $_; [void](Git-In $RepoRoot @('merge-base', '--is-ancestor', (Task-Branch $tt), $ib)); $GitCode -ne 0 })
            if ($gone.Count) {
                $State.integration.merged = @($merged | Where-Object { $_ -notin $gone }); $State.integration.checks = @(); $State.status = 'integrating'; Save-State
                [void](Message-Screen '⚑ ÉQUIPE — assemblage à refaire' @("$Warn La tâche $($gone -join ', ') n'est pas dans la branche d'intégration (fusion annulée ou refusée).$R", 'FLOW va refaire l''assemblage avant de livrer : rien n''est perdu.') @('Entrée', 'continuer'))
                return 'integrate'
            }
            # 2) rien à livrer ?
            if (-not $merged.Count) { $msg = "$Err✗ aucune tâche n'a été fusionnée : il n'y a rien à livrer (Échap pour revenir, J pour jeter)$R"; continue }
            # 3) tâches qui ne seront PAS livrées : on le dit avant, et leur travail est mis à l'abri
            $left = @($State.tasks | Where-Object { $_.id -notin $merged })
            if ($left.Count) {
                $k2 = Message-Screen '⚑ ÉQUIPE — tâches qui ne seront pas livrées' @(
                    "Ces tâches ne sont pas dans le travail livré : $B$(($left.id) -join ', ')$R.",
                    "$Ok Leur travail est mis de côté dans Git (refs/flow-archive/$($State.id)/…) : tu pourras le récupérer.$R") @('O', 'livrer quand même', 'Échap', 'annuler')
                Cls
                if ("$($k2.KeyChar)".ToLower() -ne 'o') { continue }
            }
            # 4) une vérification du projet a échoué : on ne livre pas sans le dire
            $failed = @(@($State.integration.checks) | Where-Object { $_.ran -and -not $_.ok })
            if ($failed.Count) {
                $k3 = Message-Screen '⚑ ÉQUIPE — une vérification a échoué' @(
                    "$Err✗ En échec sur la branche d'intégration : $(($failed.name) -join ', ').$R",
                    "$Dm Détail : $(Join-Path $RunDir 'verifications.txt')$R", '',
                    'Livrer maintenant mettrait ce code dans ton projet.') @('O', 'livrer quand même', 'Échap', 'annuler')
                Cls
                if ("$($k3.KeyChar)".ToLower() -ne 'o') { continue }
            }
            $res = Deliver-Run $dlv $target $cur
            if ($res.Ok) {
                $State.status = 'merged'; $State.integration.delivered = $res.Info; Save-State
                [void](Message-Screen '⚑ ÉQUIPE — livré' (@("$Ok✓ $($res.Info)$R", "$Dm Copies de travail et branches temporaires supprimées ; l'historique reste dans $RunDir.$R") + @(Archive-Lines $res.Archive)) @('Entrée', 'nouvelle demande'))
                return 'home'
            }
            $msg = $res.Info
        }
        elseif ($ch -eq 'j') {
            $go = Confirm-Discard '⚑ ÉQUIPE — jeter le travail de l''équipe ?'
            Cls
            if ($go) { $arch = @(Cleanup-Run -Abandon); $State.status = 'discarded'; Save-State; Show-Archive $arch; return 'home' }
        }
    }
}

# ───────────────────────── boucle principale ─────────────────────────
if ($LoadOnly) { return }   # tests : les fonctions sont chargées, l'écran n'est pas lancé
$mode = 'setup'
Enable-Mouse
try {
    while ($mode -ne 'quit') {
        try {
            $mode = switch ($mode) {
                'setup'     { Mode-Setup }
                'profile'   { Mode-Profile }
                'project'   { Mode-Project }
                'home'      { Mode-Home }
                'plan'      { Mode-Plan }
                'run'       { Mode-Run }
                'integrate' { Mode-Integrate }
                'review'    { Mode-Review }
                default     { 'quit' }
            }
        } catch {
            $k = Message-Screen '⚑ ÉQUIPE — erreur' @("$Err$($_.Exception.Message)$R", "$Dm$($_.InvocationInfo.PositionMessage)$R") @('Entrée', 'revenir à l''accueil', 'Échap', 'quitter')
            $mode = if ($k.Key -eq 'Escape') { 'quit' } else { 'setup' }
        }
    }
} finally {
    Disable-Mouse
    [Console]::Write("$R$e[?25h")
}

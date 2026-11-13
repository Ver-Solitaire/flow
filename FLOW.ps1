<#
  FLOW — lanceur Claude × psmux avec sélecteur de profils (version portable).

    FLOW.ps1                    ouvre le sélecteur animé
    FLOW.ps1 -Open standard     lance directement profiles\standard.json
    FLOW.ps1 -Open standard -NoAttach   construit la session en arrière-plan sans s'y attacher
    FLOW.ps1 -InstallShortcut   crée / met à jour le raccourci « FLOW » sur le bureau
    FLOW.ps1 -Login second      ouvre Claude avec le compte « second » (config\accounts.json) pour s'y connecter
    FLOW.ps1 -Team C:\projet    ouvre la fenêtre Équipe sur n'importe quel projet (une session par projet)
    FLOW.ps1 -Doctor            diagnostic : qu'est-ce qui ne va pas sur cette machine ? (versions, comptes, sessions, journal)
    FLOW.ps1 -InstallSkills     installe les skills FLOW (dossier skills\) dans chaque compte Claude (fait aussi à chaque lancement)
    FLOW.ps1 -Project C:\projet tous les profils travaillent dans ce projet (sessions propres au projet ; J pour changer)
    FLOW.exe                    application : fenêtre de choix du projet, puis ce sélecteur (créée par -InstallShortcut)

  Tout vit dans ce dossier : profils (profiles\*.json), config psmux (config\),
  outils (tools\). Déplace le dossier puis relance -InstallShortcut.
#>
param(
    [string]$Open,
    [switch]$NoAttach,
    [switch]$InstallShortcut,
    [string]$Login,             # FLOW.ps1 -Login second : ouvre Claude avec ce compte pour s'y connecter
    [string]$Team,              # FLOW.ps1 -Team C:\mon\projet : session Équipe sur ce projet (sans créer de profil)
    [switch]$InstallSkills,     # FLOW.ps1 -InstallSkills : (ré)installe les skills FLOW dans chaque compte Claude
    [switch]$Doctor,            # FLOW.ps1 -Doctor : contrôle l'installation, les comptes et les sessions, et dit quoi faire
    [switch]$LoadOnly,          # charge les fonctions sans lancer l'écran (tests)
    [string]$Project,           # FLOW.ps1 -Project C:\mon\projet : les profils s'ouvrent dans ce projet
    [switch]$Demo,              # FLOW.ps1 -Demo : démonstration avec activité simulée (moniteur, Bureau, personnages)
    [switch]$TeamDemo,          # FLOW.ps1 -TeamDemo : simulation de la fenêtre Équipe (prompt → plan → ouvriers → fusion)
    [switch]$ShareDemo          # FLOW.ps1 -ShareDemo : démonstration des bibliothèques de profils partagés
)
if ($ShareDemo) { & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'tools\flow-share-demo.ps1'); return }
if ($Demo) { & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'tools\flow-demo.ps1'); return }
if ($TeamDemo) { & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'tools\flow-team-demo.ps1'); return }

$Root      = $PSScriptRoot
$Sock      = 'flow'                                  # serveur psmux isolé
$Conf      = Join-Path $Root 'config\psmux.conf'
$StateFile = Join-Path $Root 'config\state.json'     # dernier profil utilisé
$AcctFile  = Join-Path $Root 'config\accounts.json'  # comptes Claude
$ProfDir   = Join-Path $Root 'profiles'
$TrashDir  = Join-Path $ProfDir '.corbeille'
$Tools     = Join-Path $Root 'tools'
$SrcFile   = Join-Path $Root 'config\sources.json'        # bibliothèques de profils partagés
$SrcCache  = Join-Path $Root 'config\sources-cache'       # copies locales des bibliothèques Git
$ShLocFile = Join-Path $Root 'config\shared-local.json'   # dossier de travail choisi pour chaque profil partagé
$ProjFile  = Join-Path $Root 'config\projects.json'       # projets récents (partagé avec FLOW.exe)
$ProjectsRoot = Split-Path $Root -Parent                  # les projets proposés : dossiers voisins de FLOW
$ProjectDir = $null                                       # projet courant (-Project, touche J) ; $null = dossiers des profils
$ProjSlug  = ''
$Sources   = @()

# Environnement propre : pas de NO_COLOR hérité, rendu ANSI forcé
foreach ($v in 'NO_COLOR', 'GIT_TERMINAL_PROMPT') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
if ($PSStyle) { $PSStyle.OutputRendering = 'Ansi' }
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ───────────────────────── couleurs ─────────────────────────
$e  = [char]27
$R  = "$e[0m"; $B = "$e[1m"; $Dm = "$e[2m"
$ansiRx = "$e\[[0-9;]*m"
$Pal = @(@(255,138,92), @(255,94,158), @(168,112,255), @(84,186,255), @(96,232,196))

function Rgb([int]$r, [int]$g, [int]$b) { "$e[38;2;$r;$g;$($b)m" }
function RgbA($c) { Rgb $c[0] $c[1] $c[2] }
function Mix($a, $b, [double]$f) {
    $f = [Math]::Max(0.0, [Math]::Min(1.0, $f))
    @([int]($a[0] + ($b[0] - $a[0]) * $f), [int]($a[1] + ($b[1] - $a[1]) * $f), [int]($a[2] + ($b[2] - $a[2]) * $f))
}
function PalAt([double]$t) {
    $t -= [Math]::Floor($t)
    $x = $t * $Pal.Count
    $i = [int][Math]::Floor($x) % $Pal.Count
    Mix $Pal[$i] $Pal[($i + 1) % $Pal.Count] ($x - [Math]::Floor($x))
}
function PalC([double]$t) { RgbA (PalAt $t) }
function Grad([string]$s, [double]$phase, [double]$spread = 0.03) {
    $sb = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt $s.Length; $i++) {
        $ch = $s[$i]
        if ($ch -eq ' ') { [void]$sb.Append(' '); continue }
        [void]$sb.Append((PalC ($phase + $i * $spread))).Append($ch)
    }
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

$Ok   = Rgb 120 230 140
$Err  = Rgb 255 110 90
$Info = Rgb 120 200 255
$Warn = Rgb 255 210 110
. (Join-Path $PSScriptRoot 'tools\flow-input.ps1')   # clavier + souris (clics)
. (Join-Path $PSScriptRoot 'tools\flow-common.ps1')  # écritures atomiques, Q, journal
. (Join-Path $PSScriptRoot 'tools\flow-claudemd.ps1')  # création d'un CLAUDE.md de départ
$global:FlowLogFile = Join-Path $PSScriptRoot 'config\flow.log'
$FlowVersion = try { (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -TotalCount 1 -ErrorAction Stop).Trim() } catch { '' }
$KeyPairs = [Collections.Generic.List[string]]::new()  # aides affichées (rendues cliquables)
function Key([string]$key, [string]$txt) { $KeyPairs.Add("$key|$txt"); "$B$Warn$key$R $Dm$txt$R" }
function Hint-Zones($lines) {
    # rend cliquables les aides affichées dans cette image, puis les oublie
    $map = @{}
    foreach ($kp in $KeyPairs) { $kk, $tt = $kp -split '\|', 2; $hn = Hint-FromLabel $kk; if ($hn) { $map["$kk $tt"] = $hn } }
    Add-HintZones $lines $map
    $KeyPairs.Clear()
}

$RoleInfo = @{
    claude  = @{ Icon = '✦'; Label = 'claude';   Rgb = @(255,138,92) }
    monitor = @{ Icon = '◉'; Label = 'moniteur'; Rgb = @(84,186,255) }
    shell   = @{ Icon = '»'; Label = 'terminal'; Rgb = @(150,150,175) }
    command = @{ Icon = '▶'; Label = 'commande'; Rgb = @(168,112,255) }
    team    = @{ Icon = '⚑'; Label = 'équipe';   Rgb = @(96,232,196) }
    office  = @{ Icon = '⌂'; Label = 'bureau';   Rgb = @(255,94,158) }
    exchanges = @{ Icon = '⇄'; Label = 'échanges'; Rgb = @(96,232,196) }
}
function RoleOf($pane) { $r = [string]$pane.role; if ($RoleInfo.ContainsKey($r)) { $RoleInfo[$r] } else { $RoleInfo.command } }

# ───────────────────────── profils ─────────────────────────
function Resolve-Dir([string]$p) {
    if (-not $p) { return $Root }
    $p = [Environment]::ExpandEnvironmentVariables($p) -replace '^~', $HOME
    if ([IO.Path]::IsPathRooted($p)) { return [IO.Path]::GetFullPath($p) }
    [IO.Path]::GetFullPath((Join-Path $Root $p))
}

function Dir-OrRoot([string]$p) {
    $d = Resolve-Dir $p
    if (Test-Path -LiteralPath $d -PathType Container) { $d } else { $Root }
}

function Rel([string]$path) {
    # chemin relatif au dossier FLOW quand c'est possible (portabilité)
    try { $r = [IO.Path]::GetRelativePath($Root, $path) } catch { return $path }
    if ([IO.Path]::IsPathRooted($r)) { $path } else { $r }
}

function Get-Profiles {
    if (-not (Test-Path -LiteralPath $ProfDir)) { New-Item -ItemType Directory -Force $ProfDir | Out-Null }
    $list = foreach ($f in Get-ChildItem -LiteralPath $ProfDir -Filter *.json -File) {
        $j = $null
        try { $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json } catch {}
        if (-not $j) { continue }
        $j | Add-Member -NotePropertyName Id -NotePropertyValue $f.BaseName -Force
        $j | Add-Member -NotePropertyName File -NotePropertyValue $f.FullName -Force
        if (-not $j.name) { $j | Add-Member -NotePropertyName name -NotePropertyValue $f.BaseName -Force }
        $j
    }
    @($list | Sort-Object @{ e = { if ($null -ne $_.order) { [int]$_.order } else { 999 } } }, name)
}

function Get-ProfilesSig {
    # empreinte des profils (locaux + partagés) et des réglages : sert à recharger automatiquement après une modification
    $files = @(Get-ChildItem -LiteralPath $ProfDir -Filter *.json -File -ErrorAction SilentlyContinue)
    $files += @(Get-Item -LiteralPath $AcctFile, $SrcFile, $ShLocFile -ErrorAction SilentlyContinue)
    foreach ($src in $Sources) { if ($src.Ok) { $files += @(Get-ChildItem -LiteralPath $src.Dir -Filter *.json -File -ErrorAction SilentlyContinue) } }
    ($files | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
}

function Read-ProfileFile([string]$file) {
    Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json
}

function Write-ProfileFile($p, [string]$file) {
    $o = [ordered]@{}
    foreach ($pr in $p.PSObject.Properties) { if ($pr.Name -notin 'Id', 'File', 'Shared', 'SharedSrc', 'SharedKey') { $o[$pr.Name] = $pr.Value } }
    Write-JsonAtomic $o $file -Depth 20 -Backup
}

function Slugify([string]$name, [string]$fallback = 'profil') {
    $slug = ($name.ToLower().Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '' -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug) { $slug } else { $fallback }
}

function New-ProfilePath([string]$name) {
    $slug = Slugify $name
    $file = Join-Path $ProfDir "$slug.json"
    $n = 2; while (Test-Path -LiteralPath $file) { $file = Join-Path $ProfDir "$slug-$n.json"; $n++ }
    $file
}

function Next-Order {
    $m = (Get-Profiles | ForEach-Object { if ($null -ne $_.order) { [int]$_.order } else { 0 } } | Measure-Object -Maximum).Maximum
    [int]$m + 1
}

function SessionName($p) {
    $s = if ($p.session) { [string]$p.session } else { "flow-$($p.Id)" }
    if ($ProjectDir) { $s = "$s--$ProjSlug" }    # un même profil peut tourner dans plusieurs projets
    $s -replace '[:.\s]', '-'
}

# dossier de travail d'un profil (ou d'un de ses panneaux) : le projet courant l'emporte
function PCwd($p, $pane) {
    if ($ProjectDir) { return $ProjectDir }
    Dir-OrRoot $(if ($pane -and $pane.cwd) { $pane.cwd } else { $p.cwd })
}

# ───────────────────────── projets ─────────────────────────
function Get-RecentProjects {
    try { @((Get-Content -LiteralPath $ProjFile -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json).recent) } catch { @() }
}

function Set-Project([string]$dir) {
    if (-not $dir) { $script:ProjectDir = $null; $script:ProjSlug = ''; $Host.UI.RawUI.WindowTitle = 'FLOW'; return }
    $d = [IO.Path]::GetFullPath(([Environment]::ExpandEnvironmentVariables($dir.Trim().Trim('"')) -replace '^~', $HOME)).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { throw "dossier de projet introuvable : $d" }
    $script:ProjectDir = $d
    $script:ProjSlug = Slugify (Split-Path $d -Leaf) 'projet'
    $Host.UI.RawUI.WindowTitle = "FLOW · $(Split-Path $d -Leaf)"
    $rec = @(Get-RecentProjects | Where-Object { $_.path -and ([string]$_.path).TrimEnd('\') -ne $d })
    $rec = @([pscustomobject]@{ path = $d; last = (Get-Date).ToString('s') }) + $rec | Select-Object -First 30
    try {
        New-Item -ItemType Directory -Force (Split-Path $ProjFile) | Out-Null
        Write-JsonAtomic ([pscustomobject]@{ recent = @($rec) }) $ProjFile -Depth 5
    } catch {}
}

function Get-ProjectList {
    $map = [ordered]@{}
    foreach ($r in Get-RecentProjects) {
        $d = ([string]$r.path).TrimEnd('\')
        if ($d -and (Test-Path -LiteralPath $d -PathType Container) -and -not $map.Contains($d)) {
            $map[$d] = [pscustomobject]@{ Dir = $d; Name = (Split-Path $d -Leaf); Last = [string]$r.last }
        }
    }
    foreach ($dd in (Get-ChildItem -LiteralPath $ProjectsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($dd.FullName.TrimEnd('\') -eq $Root.TrimEnd('\') -or $dd.Name.StartsWith('.')) { continue }
        # <projet>-flow : copies de travail du mode Équipe
        if ($dd.Name -match '^(.+)-flow$' -and (Test-Path -LiteralPath (Join-Path $ProjectsRoot $Matches[1]))) { continue }
        if (-not $map.Contains($dd.FullName)) { $map[$dd.FullName] = [pscustomobject]@{ Dir = $dd.FullName; Name = $dd.Name; Last = '' } }
    }
    @($map.Values)
}

function Invoke-ProjectPick {
    # renvoie un message pour le sélecteur
    $items = @([pscustomobject]@{ Kind = 'none'; Name = 'aucun projet'; Dir = '' }) +
             @(Get-ProjectList | ForEach-Object { $_ | Add-Member -NotePropertyName Kind -NotePropertyValue 'dir' -PassThru -Force }) +
             @([pscustomobject]@{ Kind = 'new'; Name = 'nouveau projet…'; Dir = '' }, [pscustomobject]@{ Kind = 'path'; Name = 'autre dossier…'; Dir = '' })
    $i = Pick-Item '◆ PROJET — où Claude doit-il travailler ?' $items {
        param($x)
        switch ($x.Kind) {
            'none' { "$Dm◇ aucun projet$R $Dm(chaque profil garde son dossier)$R" }
            'new'  { "$Ok＋ nouveau projet…$R" }
            'path' { "$Info↗ autre dossier…$R" }
            default {
                $cur = if ($ProjectDir -and $x.Dir -eq $ProjectDir) { " $Ok● actuel$R" } else { '' }
                $git = if (Test-Path -LiteralPath (Join-Path $x.Dir '.git')) { " $Dm git$R" } else { '' }
                "▣ $($x.Name)$git$cur"
            }
        }
    } { param($x) if ($x.Dir) { "$Dm dossier$R  $($x.Dir)" } elseif ($x.Kind -eq 'new') { "$Dm créé dans$R  $ProjectsRoot" } }
    if ($i -lt 0) { return '' }
    $x = $items[$i]
    switch ($x.Kind) {
        'none' { Set-Project $null; return "$Info◇ sans projet : chaque profil s'ouvre dans son propre dossier$R" }
        'path' {
            $d = Read-Line '◆ PROJET' 'Chemin du dossier :' $(if ($ProjectDir) { $ProjectDir } else { $ProjectsRoot }) {
                param($v) if (-not (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($v.Trim('"')) -replace '^~', $HOME) -PathType Container)) { 'dossier introuvable' }
            }
            if ($null -eq $d) { return '' }
            Set-Project $d
        }
        'new' {
            $n = Read-Line '◆ NOUVEAU PROJET' "Nom du dossier (dans $ProjectsRoot) :" '' {
                param($v) if (-not $v.Trim()) { 'nom vide' } elseif ($v.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { 'caractère interdit' }
            }
            if ($null -eq $n) { return '' }
            $d = Join-Path $ProjectsRoot $n.Trim()
            if (-not (Test-Path -LiteralPath $d)) {
                New-Item -ItemType Directory -Force $d | Out-Null
                if (Get-Command git -ErrorAction SilentlyContinue) { & git -C $d init -b main *> $null }
            }
            Set-Project $d
        }
        default { Set-Project $x.Dir }
    }
    [void](Invoke-AccountGate $null -ForProject)   # connexion des comptes dès le choix du projet
    Offer-ClaudeMd
    "$Ok▣ projet : $(Split-Path $ProjectDir -Leaf)$R $Dm($ProjectDir)$R"
}

function Uses-Role($p, [string]$role) {
    foreach ($row in @($p.rows)) { foreach ($pn in @($row.panes)) { if ([string]$pn.role -eq $role) { return $true } } }
    $false
}

# ───────────────────────── comptes Claude ─────────────────────────
# config\accounts.json : liste des comptes ; un profil (ou un panneau) choisit le sien avec "account": "<id>".
# "dir": null = compte par défaut (~\.claude) ; sinon dossier passé à Claude via CLAUDE_CONFIG_DIR.
function HexToRgb([string]$h) {
    $h = "$h".TrimStart('#')
    if ($h -notmatch '^[0-9a-fA-F]{6}$') { return @(200, 140, 255) }
    @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}

function New-AcctObj([string]$id, [string]$label, [string]$short, [string]$dirRaw, [string]$color, [bool]$enabled) {
    $dir = if ($dirRaw) { Resolve-Dir $dirRaw } else { $null }
    $home_ = if ($dir) { $dir } else { Join-Path $HOME '.claude' }
    $hex = "$color".TrimStart('#'); if ($hex -notmatch '^[0-9a-fA-F]{6}$') { $hex = 'c88cff' }
    [pscustomobject]@{
        Id = $id; Label = $(if ($label) { $label } else { $id }); Short = $(if ($short) { $short } else { $id })
        DirRaw = $dirRaw; Dir = $dir; Home = $home_; Hex = $hex; Rgb = (HexToRgb $hex); Enabled = $enabled
        Logged = (Test-Path -LiteralPath (Join-Path $home_ '.credentials.json'))
    }
}

function Get-Accounts {
    $list = [Collections.Generic.List[object]]::new()
    $j = $null
    try { $j = Get-Content -LiteralPath $AcctFile -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json } catch {}
    foreach ($a in @($j.accounts)) {
        if (-not $a.id) { continue }
        $o = New-AcctObj ([string]$a.id) ([string]$a.label) ([string]$a.short) ([string]$a.dir) ([string]$a.color) ($a.enabled -ne $false)
        # "email" (facultatif) : adresse préremplie sur la page de connexion de ce compte
        $o | Add-Member -NotePropertyName Email -NotePropertyValue ([string]$a.email)
        $list.Add($o)
    }
    if (-not $list.Count) { $list.Add((New-AcctObj 'principal' 'Compte 1' 'C1' $null 'ff8a5c' $true)) }
    , $list
}

function Acct-Mail($a) {
    # adresse du compte actuellement connecté (lue dans la configuration locale de Claude), '' si inconnue
    if (-not $a.Logged) { return '' }
    $f = if ($a.Dir) { Join-Path $a.Dir '.claude.json' } else { Join-Path $HOME '.claude.json' }
    try { if ((Get-Content -LiteralPath $f -Raw -ErrorAction Stop) -match '"emailAddress"\s*:\s*"([^"]+)"') { return $Matches[1] } } catch {}
    ''
}

function Profile-Accounts($p) {
    # comptes dont le profil a besoin : ceux de ses panneaux Claude ; avec un panneau Équipe, tous les comptes activés
    $map = [ordered]@{}
    foreach ($pn in @(Claude-Panes $p)) { $a = Acct-For $pn $p; if ($a -and -not $map.Contains($a.Id)) { $map[$a.Id] = $a } }
    if (Uses-Role $p 'team') { foreach ($a in $Accounts) { if ($a.Enabled -and -not $map.Contains($a.Id)) { $map[$a.Id] = $a } } }
    @($map.Values)
}

function Dup-Of($a) {
    # un autre compte connecté avec la même adresse que $a (deux « comptes » qui sont en fait le même) ; $null sinon
    $m = Acct-Mail $a
    if (-not $m) { return $null }
    @($Accounts | Where-Object { $_.Id -ne $a.Id -and $_.Enabled -and $_.Logged -and (Acct-Mail $_) -eq $m })[0]
}

function Connect-Account($a, [switch]$Relogin) {
    # connexion d'un compte dans CETTE fenêtre (claude auth login) : pas de fenêtre à chercher. Renvoie $true si connecté.
    # -Relogin : déconnecte d'abord le compte (pour changer d'adresse).
    Disable-Mouse
    [Console]::Write("$R$e[?25h$e[2J$e[H")
    Write-Host ''
    Write-Host "   $(Grad "◆ CONNEXION — $($a.Label)" 0.1 0.03)"
    Write-Host "   $Dm dossier du compte : $($a.Home)$R"
    Write-Host ''
    Write-Host "   Claude va ouvrir la page de connexion dans ton navigateur."
    Write-Host "   $Warn Ton navigateur est déjà connecté à un autre compte ?$R Copie le lien affiché ci-dessous dans une"
    Write-Host "   fenêtre privée, connecte-toi avec le bon compte, puis colle ici le code obtenu."
    Write-Host ''
    New-Item -ItemType Directory -Force $a.Home | Out-Null
    $old = $env:CLAUDE_CONFIG_DIR
    try {
        if ($a.Dir) { $env:CLAUDE_CONFIG_DIR = $a.Dir } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
        if ($Relogin) { Start-Process -FilePath (Get-Command claude -ErrorAction Stop).Source -ArgumentList @('auth', 'logout') -NoNewWindow -Wait; Write-FlowLog "compte « $($a.Label) » déconnecté pour changer d'adresse" }
        $largs = @('auth', 'login'); if ($a.Email) { $largs += @('--email', $a.Email) }
        # Start-Process : la sortie va droit à l'écran (un appel direct serait capturé par l'appelant, lien compris)
        Start-Process -FilePath (Get-Command claude -ErrorAction Stop).Source -ArgumentList $largs -NoNewWindow -Wait
    } catch { Write-Host "   $Err$($_.Exception.Message)$R" }
    finally { if ($old) { $env:CLAUDE_CONFIG_DIR = $old } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue } }
    $logged = Test-Path -LiteralPath (Join-Path $a.Home '.credentials.json')
    if ($logged) {
        Ensure-StatusLine $a.Home; Install-Skills $a.Home
        Write-FlowLog "compte « $($a.Label) » connecté"
        # deux « comptes » qui ouvrent la même identité ne doublent rien : on le dit tout de suite
        $fresh = @(Get-Accounts | Where-Object { $_.Id -eq $a.Id })[0]
        $mine = if ($fresh) { Acct-Mail $fresh } else { '' }
        $same = if ($mine) { @(Get-Accounts | Where-Object { $_.Id -ne $a.Id -and $_.Logged -and (Acct-Mail $_) -eq $mine }) } else { @() }
        if ($same.Count) {
            Write-Host ''
            Write-Host "   $Warn⚠ « $($a.Label) » est connecté avec la MÊME adresse que « $($same[0].Label) » ($mine).$R"
            Write-Host "   $Dm Deux comptes identiques n'ajoutent aucune capacité. Pour changer : relance la connexion de « $($a.Label) » avec l'autre adresse (fenêtre privée).$R"
            Write-Host "   $Dm Entrée pour continuer.$R"
            Write-FlowLog "« $($a.Label) » et « $($same[0].Label) » ont la même identité" 'WARN'
            [void][Console]::ReadLine()
        }
    }
    else {
        Write-Host ''
        Write-Host "   $Warn○ « $($a.Label) » n'est pas encore connecté.$R $Dm Entrée pour revenir à la liste.$R"
        [void][Console]::ReadLine()
    }
    Enable-Mouse
    [Console]::Write("$e[?25l$e[2J")
    $logged
}

function Add-Account {
    # ajoute un compte à config\accounts.json (dossier séparé ~\.claude-compteN) ; renvoie le compte, $null si annulé
    $j = $null
    try { $j = Get-Content -LiteralPath $AcctFile -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json } catch {}
    $list = @(@($j.accounts) | Where-Object { $_ -and $_.id })
    if (-not $list.Count) { $list = @([pscustomobject][ordered]@{ id = 'principal'; label = 'Compte 1'; short = 'C1'; dir = $null; color = '#ff8a5c'; enabled = $true }) }
    $n = $list.Count + 1
    while (@($list | Where-Object { $_.id -eq "compte$n" -or $_.short -eq "C$n" -or "$($_.dir)" -match "claude-compte$n$" }).Count -or
           (Test-Path -LiteralPath (Join-Path $HOME ".claude-compte$n"))) { $n++ }
    $label = Read-Line '◆ NOUVEAU COMPTE CLAUDE' 'Nom du compte :' "Compte $n" { param($v) if (-not "$v".Trim()) { 'le nom ne peut pas être vide' } } @(
        "ses identifiants seront rangés à part, dans $(Join-Path $HOME ".claude-compte$n")", 'la connexion est proposée juste après')
    if ($null -eq $label) { return $null }
    $cols = '#ff8a5c', '#54baff', '#60e8c4', '#ff5e9e', '#a870ff', '#ffd26e'
    $usedC = @($list | ForEach-Object { "$($_.color)".ToLower() })
    $col = $cols | Where-Object { $_ -notin $usedC } | Select-Object -First 1
    if (-not $col) { $col = $cols[($n - 1) % $cols.Count] }
    $list += [pscustomobject][ordered]@{ id = "compte$n"; label = "$label".Trim(); short = "C$n"; dir = "~/.claude-compte$n"; color = $col; enabled = $true }
    New-Item -ItemType Directory -Force (Split-Path $AcctFile) | Out-Null
    Write-JsonAtomic ([pscustomobject]@{ accounts = @($list) }) $AcctFile -Depth 5 -Backup
    $script:Accounts = Get-Accounts
    $Accounts | Where-Object { $_.Id -eq "compte$n" } | Select-Object -First 1
}

function Offer-ClaudeMd {
    # propose de créer un CLAUDE.md quand le projet n'en a pas (la « mémoire » que lit chaque Claude au début d'une session)
    if (-not $ProjectDir -or (Test-Path -LiteralPath (Join-Path $ProjectDir 'CLAUDE.md'))) { return }
    $decl = Join-Path $Root 'config\claudemd-refuse.json'
    $refused = @(try { Get-Content -LiteralPath $decl -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json } catch { @() })
    if ($refused -contains $ProjectDir) { return }
    $choices = @('Oui : créer un modèle maintenant (gratuit, d''après ce qui est détecté dans le dossier)', 'Plus tard (je redemanderai la prochaine fois)', 'Non, pas pour ce projet')
    $i = Pick-Item "◆ « $(Split-Path $ProjectDir -Leaf) » n'a pas de CLAUDE.md — le créer ?" $choices { param($x) $x } {
        param($x)
        @("$Dm CLAUDE.md est la mémoire du projet : chaque Claude (et chaque ouvrier d'une équipe) le lit au début de sa session.$R",
          "$Dm Le modèle contient les commandes, l'organisation et les conventions détectées ; tu le compléteras ensuite.$R")
    } 0
    if ($i -eq 0) {
        $f = New-ClaudeMd $ProjectDir
        if ($f) {
            Write-FlowLog "CLAUDE.md créé dans $ProjectDir"
            Show-Frame @('', "   $Ok✓ CLAUDE.md créé : $f$R", '', "   $Dm Ouvre-le pour compléter les passages « (à compléter) » (ou demande à Claude de le faire).$R", '', "  $(Key 'Entrée' 'continuer')")
            [void](Read-Action -Wait)
        }
    }
    elseif ($i -eq 2) { Write-JsonAtomic @(@($refused) + $ProjectDir) $decl -Depth 3 }
}

function Invoke-RemoveAccount {
    # retire un compte de FLOW (config\accounts.json), avec ou sans déconnexion. Le compte par défaut de Claude Code (~\.claude) ne se retire pas.
    # renvoie un message pour l'écran.
    $script:Accounts = Get-Accounts
    $cands = @($Accounts | Where-Object { $_.Dir })
    if (-not $cands.Count) { return "$Dm aucun compte à retirer : le compte par défaut de Claude Code reste toujours$R" }
    $i = Pick-Item '◆ RETIRER UN COMPTE — lequel ?' $cands {
        param($a)
        "$(RgbA $a.Rgb)◆ $($a.Label)$R $Dm[$($a.Id)]$R  $(if ($a.Logged) { "$Ok● connecté$R $Dm$(Acct-Mail $a)$R" } else { "$Dm○ pas connecté$R" })"
    } { param($a) @("$Dm dossier$R  $($a.Home)") }
    if ($i -lt 0) { return '' }
    $a = $cands[$i]
    $used = @(Get-Profiles | Where-Object { $pp = $_; ([string]$pp.account -eq $a.Id) -or @(Claude-Panes $pp | Where-Object { [string]$_.account -eq $a.Id }).Count } | ForEach-Object { $_.name })
    $choices = @('Retirer et déconnecter le compte (efface sa connexion)', 'Retirer de FLOW seulement (la connexion et l''historique restent dans son dossier)', 'Annuler')
    $c = Pick-Item "◆ Retirer « $($a.Label) » de FLOW ?" $choices { param($x) $x } {
        param($x)
        $l = @("$Dm Le dossier $($a.Home) n'est jamais supprimé : tu peux le retirer à la main plus tard.$R")
        if ($used) { $l += "$Warn Profils qui utilisent ce compte : $($used -join ', ') — ils ne se lanceront plus tant que tu ne les as pas modifiés (E dans le sélecteur).$R" }
        $l
    } 2
    if ($c -notin 0, 1) { return "$Dm retrait annulé$R" }
    if ($c -eq 0 -and $a.Logged) {
        $old = $env:CLAUDE_CONFIG_DIR
        try { $env:CLAUDE_CONFIG_DIR = $a.Dir; Start-Process -FilePath (Get-Command claude -ErrorAction Stop).Source -ArgumentList @('auth', 'logout') -NoNewWindow -Wait }
        catch { Write-FlowLog "déconnexion de « $($a.Label) » impossible : $($_.Exception.Message)" 'WARN' }
        finally { if ($old) { $env:CLAUDE_CONFIG_DIR = $old } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue } }
    }
    $j = $null
    try { $j = Get-Content -LiteralPath $AcctFile -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json } catch {}
    $list = @(@($j.accounts) | Where-Object { $_ -and $_.id -ne $a.Id })
    Write-JsonAtomic ([pscustomobject]@{ accounts = $list }) $AcctFile -Depth 5 -Backup
    $script:Accounts = Get-Accounts
    $script:AcctLines = $null
    Write-FlowLog "compte « $($a.Label) » retiré de FLOW$(if ($c -eq 0) { ' et déconnecté' })"
    "$Ok✓ « $($a.Label) » retiré de FLOW$(if ($c -eq 0) { ' et déconnecté' })$(if ($used) { " $Warn— à corriger dans les profils : $($used -join ', ')" })$R"
}

function Invoke-AccountGate($p, [switch]$ForProject) {
    # connecter les comptes qui ne le sont pas encore. Deux moments :
    #  - -ForProject : à la sélection du projet (tous les comptes activés ; signale aussi deux comptes qui ont la même adresse) ;
    #  - sinon : au lancement d'un profil à plusieurs comptes (ceux dont le profil a besoin).
    # renvoie @{ Go = continuer ? ; Shown = un écran a été affiché }
    if (-not $ForProject -and (Test-Session (SessionName $p))) { return @{ Go = $true } }
    $shown = $false
    while ($true) {
        $script:Accounts = Get-Accounts
        $need = if ($ForProject) { @($Accounts | Where-Object { $_.Enabled }) } else { @(Profile-Accounts $p) }
        $missing = @($need | Where-Object { -not $_.Logged })
        $dupes = if ($ForProject) { @($need | Where-Object { $_.Logged -and $_.Dir -and (Dup-Of $_) }) } else { @() }
        if ($ForProject) { if (-not $missing.Count -and -not $dupes.Count) { return @{ Go = $true; Shown = $shown } } }
        elseif ($need.Count -lt 2 -or -not $missing.Count) { return @{ Go = $true; Shown = $shown } }
        $shown = $true
        $team = $ForProject -or (Uses-Role $p 'team')
        $items = @($need) + @(if ($team) { [pscustomobject]@{ Add = $true } }) + @(if (@($Accounts | Where-Object { $_.Dir }).Count) { [pscustomobject]@{ Remove = $true } }) + @([pscustomobject]@{ Go = $true })
        $first = 0; for ($q = 0; $q -lt $need.Count; $q++) { if (-not $need[$q].Logged) { $first = $q; break } }
        if (-not $missing.Count -and $dupes.Count) { $first = [Math]::Max(0, [array]::IndexOf($need, ($dupes | Where-Object { $_.Dir } | Select-Object -First 1))) }   # le compte à reconnecter est déjà sélectionné
        $title = if ($ForProject) { "◆ COMPTES — projet « $(Split-Path $ProjectDir -Leaf) » · $(if ($missing.Count) { "$($missing.Count) compte(s) à connecter" } else { 'comptes à vérifier' })" }
                 else { "◆ COMPTES — « $($p.name) » utilise $($need.Count) comptes · $($missing.Count) à connecter" }
        $i = Pick-Item $title $items {
            param($x)
            if ($x.Go) { return "$Info▶ $(if ($ForProject) { 'continuer' } else { 'lancer maintenant' })$R $Dm$(if ($missing.Count) { "(sans $(($missing.Label) -join ', '))" } else { '(garder les comptes tels quels)' })$R" }
            if ($x.Add) { return "$Ok＋ ajouter un compte Claude…$R" }
            if ($x.Remove) { return "$Warn－ retirer un compte…$R" }
            $st = if ($x.Logged) { $m = Acct-Mail $x; $dp = Dup-Of $x; "$Ok● connecté$R$(if ($m) { " $Dm$m$R" })$(if ($dp) { "  $Warn$B⚠ même adresse que $($dp.Label) — Entrée pour reconnecter$R" })" } else { "$Warn○ à connecter$R $Dm— Entrée$R" }
            "$(RgbA $x.Rgb)◆ $($x.Label)$R  $st"
        } {
            param($x)
            if ($x.Add) { return @("$Dm Un compte de plus = un Claude de plus pour se partager les tâches.$R") }
            if ($x.Remove) { return @("$Dm Retire un compte de la liste de FLOW (avec ou sans le déconnecter).$R") }
            if ($x.Go) {
                if ($team) { return @("$Dm Les tâches seront réparties uniquement sur les comptes connectés.$R") }
                return @("$Dm Les panneaux des comptes non connectés afficheront l'écran de connexion de Claude.$R")
            }
            if ($x.Logged) { return @("$Dm dossier$R  $($x.Home)", "$Dm Entrée : reconnecter ce compte (pour en changer)$R") }
            @("$Dm dossier$R  $($x.Home)", "$Dm Entrée : se connecter ici même ; une fois tous les comptes connectés, le profil se lance.$R")
        } $first
        if ($i -lt 0) { return @{ Go = [bool]$ForProject; Shown = $true } }   # à la sélection du projet, Échap ne bloque rien
        $x = $items[$i]
        if ($x.Go) { return @{ Go = $true; Shown = $true } }
        if ($x.Remove) { [void](Invoke-RemoveAccount); continue }
        if ($x.Add) { $x = Add-Account; if (-not $x) { continue } }
        [void](Connect-Account $x -Relogin:([bool]($x.Logged -and $x.Dir -and (Dup-Of $x))))
    }
}

function Default-Acct {
    $d = $Accounts | Where-Object { $_.Enabled -and -not $_.Dir } | Select-Object -First 1
    if (-not $d) { $d = $Accounts | Where-Object { $_.Enabled } | Select-Object -First 1 }
    if (-not $d) { $d = $Accounts[0] }
    $d
}

function Acct-For($pane, $p) {
    # compte d'un panneau : "account" du panneau > "account" du profil > ancien "claudeConfigDir" > compte par défaut
    # renvoie $null si l'identifiant n'existe pas dans accounts.json
    $id = if ($pane -and $pane.account) { [string]$pane.account } elseif ($p.account) { [string]$p.account } else { '' }
    if ($id) { return ($Accounts | Where-Object { $_.Id -eq $id } | Select-Object -First 1) }
    if ($p.claudeConfigDir) {
        $d = Resolve-Dir $p.claudeConfigDir
        $known = $Accounts | Where-Object { $_.Dir -and $_.Dir -eq $d } | Select-Object -First 1
        if ($known) { return $known }
        return (New-AcctObj 'perso' (Split-Path $d -Leaf) 'P' $p.claudeConfigDir 'c88cff' $true)
    }
    Default-Acct
}

function Multi-Accounts { @($Accounts | Where-Object { $_.Enabled }).Count -gt 1 }

function Expand-Rows($p) {
    # Les comptes ne sont liés à aucun profil : un panneau « "perAccount": true » devient UN panneau par compte connecté
    # (autant qu'il y en a), ou un seul sur le compte par défaut si aucun n'est connecté.
    $conn = @($Accounts | Where-Object { $_.Enabled -and $_.Logged })
    if (-not $conn.Count) { $conn = @(Default-Acct) }
    foreach ($row in @($p.rows)) {
        $panes = foreach ($pn in @($row.panes)) {
            if ($pn.perAccount -eq $true) {
                $w = [double]$(if ($pn.width) { $pn.width } else { 1 }) / $conn.Count
                for ($i = 0; $i -lt $conn.Count; $i++) {
                    $c = $pn.PSObject.Copy()
                    $c.PSObject.Properties.Remove('perAccount')
                    $c | Add-Member -NotePropertyName account -NotePropertyValue $conn[$i].Id -Force
                    $c | Add-Member -NotePropertyName width -NotePropertyValue $w -Force
                    $c | Add-Member -NotePropertyName fromPerAccount -NotePropertyValue $true -Force
                    if ($i -gt 0 -and $c.PSObject.Properties['focus']) { $c.PSObject.Properties.Remove('focus') }
                    $c
                }
            } else { $pn }
        }
        $nr = $row.PSObject.Copy()
        $nr | Add-Member -NotePropertyName panes -NotePropertyValue @($panes) -Force
        $nr
    }
}

function Claude-Panes($p) {
    foreach ($row in @(Expand-Rows $p)) { foreach ($pn in @($row.panes)) { if ([string]$pn.role -eq 'claude') { $pn } } }
}

function Bad-Accounts($p) {
    # identifiants de compte inconnus utilisés par le profil
    $ids = @()
    if ($p.account) { $ids += [string]$p.account }
    foreach ($row in @($p.rows)) { foreach ($pn in @($row.panes)) { if ($pn.account) { $ids += [string]$pn.account } } }
    @($ids | Select-Object -Unique | Where-Object { $id = $_; -not ($Accounts | Where-Object { $_.Id -eq $id }) })
}

function Watch-Arg($p, $monPane) {
    # liste des comptes pour le moniteur : « libellé|couleur|dossier du compte|dossier suivi ; … »
    $map = [ordered]@{}
    foreach ($pn in @(Claude-Panes $p)) {
        $a = Acct-For $pn $p
        if ($a -and -not $map.Contains($a.Id)) { $map[$a.Id] = @{ A = $a; Cwd = (PCwd $p $pn) } }
    }
    if ($monPane.allAccounts -ne $false) {
        # les autres comptes activés : limites seulement (moniteur partagé)
        foreach ($a in $Accounts) { if ($a.Enabled -and -not $map.Contains($a.Id)) { $map[$a.Id] = @{ A = $a; Cwd = '' } } }
    }
    if (-not $map.Count) { $a = Default-Acct; $map[$a.Id] = @{ A = $a; Cwd = (PCwd $p $null) } }
    (@($map.Values | ForEach-Object { "$($_.A.Label)|$($_.A.Hex)|$($_.A.Home)|$($_.Cwd)|$($_.A.Id)|$($_.A.Short)" })) -join ';'
}

function Acct-Env($a) {
    # commande PowerShell qui sélectionne le compte dans un panneau (et écarte toute authentification héritée de l'environnement)
    (Auth-Strip) + $(if ($a -and $a.Dir) { "`$env:CLAUDE_CONFIG_DIR = $(Q $a.Dir); " } else { "Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue; " })
}

function Start-AccountLogin($a, [switch]$Inline) {
    # ouvre Claude avec ce compte (première connexion : Claude propose de se connecter, sinon /login)
    Ensure-StatusLine $a.Home
    $cmd = (Acct-Env $a) + "Write-Host ''; Write-Host '  Compte « $($a.Label -replace "'", "''") » ($($a.Home -replace "'", "''"))' -ForegroundColor Cyan; " +
        "Write-Host '  Connecte-toi si Claude le demande (sinon /login), puis /exit pour fermer.' -ForegroundColor DarkGray; Write-Host ''; claude"
    if ($Inline) { & pwsh -NoProfile -Command $cmd; return }
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
        Start-Process wt.exe -ArgumentList @('-w', 'new', '--title', "FLOW · $($a.Label)", 'pwsh', '-NoExit', '-NoProfile', '-EncodedCommand', $enc)
    } else {
        Start-Process pwsh -ArgumentList @('-NoExit', '-NoProfile', '-EncodedCommand', $enc)
    }
}

function Get-State { try { Get-Content -LiteralPath $StateFile -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json } catch { $null } }
function Save-LastUsed([string]$id) {
    try { Write-JsonAtomic ([ordered]@{ last = $id }) $StateFile -Depth 3 } catch {}
}

# dispositions proposées à la création d'un profil
$Presets = @(
    [pscustomobject]@{ Name = 'Standard'; Desc = 'moniteur + Claude, deux terminaux en dessous'; Rows = '[{"height":75,"panes":[{"role":"monitor","width":50},{"role":"claude","width":50,"args":"--teammate-mode tmux","focus":true}]},{"height":25,"panes":[{"role":"office","width":50},{"role":"shell","width":50}]}]' }
    [pscustomobject]@{ Name = 'Claude + moniteur'; Desc = 'deux colonnes, sans terminal'; Rows = '[{"height":100,"panes":[{"role":"monitor","width":40},{"role":"claude","width":60,"focus":true}]}]' }
    [pscustomobject]@{ Name = 'Claude + terminal'; Desc = 'Claude en haut, un terminal en bas'; Rows = '[{"height":75,"panes":[{"role":"claude","width":100,"focus":true}]},{"height":25,"panes":[{"role":"shell","width":100}]}]' }
    [pscustomobject]@{ Name = 'Grille 2×2'; Desc = 'Claude, moniteur et deux terminaux'; Rows = '[{"height":60,"panes":[{"role":"claude","width":60,"focus":true},{"role":"monitor","width":40}]},{"height":40,"panes":[{"role":"shell","width":60},{"role":"shell","width":40}]}]' }
    [pscustomobject]@{ Name = 'Claude seul'; Desc = 'un seul panneau plein écran'; Rows = '[{"height":100,"panes":[{"role":"claude","width":100,"focus":true}]}]' }
    [pscustomobject]@{ Name = 'Équipe multi-comptes'; Desc = 'prompt découpé en tâches réparties sur tous tes comptes connectés + un Claude par compte (Git requis)'; Rows = '[{"height":60,"panes":[{"role":"team","width":62,"focus":true},{"role":"monitor","width":38}]},{"height":40,"panes":[{"role":"claude","perAccount":true,"args":"--teammate-mode tmux","width":62},{"role":"office","width":38}]}]' }
    [pscustomobject]@{ Name = 'Un Claude par compte'; Desc = 'moniteur partagé + un Claude par compte connecté (autant que tu en as), Bureau et terminal'; Rows = '[{"height":75,"panes":[{"role":"monitor","width":30},{"role":"claude","perAccount":true,"args":"--teammate-mode tmux","width":70,"focus":true}]},{"height":25,"panes":[{"role":"office","width":50},{"role":"shell","width":50}]}]' }
)

# ───────────────────────── psmux ─────────────────────────
function Test-Session([string]$s) {
    & psmux -L $Sock has-session -t $s *> $null
    $LASTEXITCODE -eq 0
}

function Get-PaneIds([string]$s) {
    @(& psmux -L $Sock list-panes -t $s -F '#{pane_id}' 2>$null |
        ForEach-Object { if ("$_" -match '^(%\d+)') { $Matches[1] } })
}

function PaneTarget([string]$s, [string]$id) {
    # Avec psmux, les identifiants %N sont propres à chaque session : « -t %1 » peut viser le panneau
    # d'une AUTRE session du serveur. On cible donc toujours « session:.index ».
    foreach ($l in (& psmux -L $Sock list-panes -t $s -F '#{pane_id} #{pane_index}' 2>$null)) {
        $a = "$l" -split ' '
        if ($a[0] -eq $id) { return "${s}:.$($a[1])" }
    }
    throw "panneau $id introuvable dans la session $s"
}

function SumFrom($arr, [int]$from) { ($arr[$from..($arr.Count - 1)] | Measure-Object -Sum).Sum }
function Pct([double]$a, [double]$b) { [int][Math]::Max(5, [Math]::Min(95, [Math]::Round($a / $b * 100))) }

function Split-Pane([string]$s, [string]$target, [string]$dir, [int]$pct, [string]$cwd) {
    $before = Get-PaneIds $s
    & psmux -L $Sock split-window $dir -p $pct -t (PaneTarget $s $target) -c $cwd *> $null
    for ($k = 0; $k -lt 40; $k++) {
        $new = @(Get-PaneIds $s | Where-Object { $_ -notin $before })
        if ($new.Count) { return $new[0] }
        Start-Sleep -Milliseconds 100
    }
    throw "split-window a échoué (cible $target)"
}

function Ensure-StatusLine([string]$claudeDir) {
    # branche tools\statusline.ps1 (limites d'utilisation pour le moniteur) dans settings.json du compte
    $file = Join-Path $claudeDir 'settings.json'
    $cmd = "pwsh -NoProfile -File `"$((Join-Path $Tools 'statusline.ps1') -replace '\\', '/')`""
    $j = $null
    if (Test-Path -LiteralPath $file) {
        try { $j = Get-Content -LiteralPath $file -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json } catch { return }
    }
    if (-not $j) { $j = [pscustomobject]@{} }
    $cur = $j.statusLine.command
    if ($cur -eq $cmd) { return }
    if ($cur -and $cur -notmatch 'statusline\.ps1') { return }   # barre de statut perso : on n'y touche pas
    $j | Add-Member -NotePropertyName statusLine -NotePropertyValue ([pscustomobject]@{ type = 'command'; command = $cmd }) -Force
    New-Item -ItemType Directory -Force $claudeDir | Out-Null
    Write-JsonAtomic $j $file -Depth 20 -Backup
}

function Ensure-BypassAllowed([string]$claudeDir) {
    # Les Claude des équipes tournent sans aucune demande de permission (mode « bypassPermissions »). Claude Code affiche alors, une fois par
    # compte, un écran d'avertissement qui bloquerait un ouvrier lancé tout seul : on l'écarte dans le settings.json du compte.
    $file = Join-Path $claudeDir 'settings.json'
    $j = $null
    if (Test-Path -LiteralPath $file) {
        try { $j = Get-Content -LiteralPath $file -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json } catch { return }
    }
    if (-not $j) { $j = [pscustomobject]@{} }
    if ($j.skipDangerousModePermissionPrompt -eq $true) { return }
    $j | Add-Member -NotePropertyName skipDangerousModePermissionPrompt -NotePropertyValue $true -Force
    New-Item -ItemType Directory -Force $claudeDir | Out-Null
    Write-JsonAtomic $j $file -Depth 20 -Backup
    Write-FlowLog "avertissement « bypass permissions » désactivé dans $file (équipes sans demandes de permission)"
}

function Install-Skills([string]$claudeDir) {
    # copie les skills livrés avec FLOW (dossier skills\) dans <compte>\skills\ : disponibles dans tous les projets,
    # pour chaque compte. « {{FLOW_ROOT}} » y est remplacé par l'emplacement de FLOW (appel de ses outils).
    # Un skill du même nom créé par l'utilisateur (sans marqueur .flow-skill) n'est jamais remplacé.
    $srcRoot = Join-Path $Root 'skills'
    if (-not (Test-Path -LiteralPath $srcRoot)) { return }
    foreach ($d in Get-ChildItem -LiteralPath $srcRoot -Directory) {
        $dest = Join-Path $claudeDir "skills\$($d.Name)"
        $mark = Join-Path $dest '.flow-skill'
        if ((Test-Path -LiteralPath $dest) -and -not (Test-Path -LiteralPath $mark)) { continue }
        $files = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File)
        $sig = "$Root|" + (($files | ForEach-Object { "$($_.FullName.Substring($d.FullName.Length))|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';')
        if ((Test-Path -LiteralPath $mark) -and ((Get-Content -LiteralPath $mark -Raw -ErrorAction SilentlyContinue) -eq $sig)) { continue }
        try {
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            foreach ($f in $files) {
                $to = Join-Path $dest $f.FullName.Substring($d.FullName.Length).TrimStart('\')
                New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
                $txt = (Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8).Replace('{{FLOW_ROOT}}', $Root)
                [IO.File]::WriteAllText($to, $txt, [Text.UTF8Encoding]::new($false))
            }
            Set-Content -LiteralPath $mark $sig -NoNewline -Encoding utf8
        } catch {}
    }
}

function Install-AllSkills {
    $n = 0
    foreach ($a in @($Accounts | Where-Object { $_.Enabled })) { if (Test-Path -LiteralPath $a.Home) { Install-Skills $a.Home; $n++ } }
    $n
}


function Team-Accounts {
    # comptes passés à la fenêtre Équipe : « id|libellé|couleur|dossier|nom court ; … »
    (@($Accounts | Where-Object { $_.Enabled } | ForEach-Object { "$($_.Id)|$($_.Label)|$($_.Hex)|$($_.Dir)|$($_.Short)" })) -join ';'
}

function Team-Hint {
    # consigne ajoutée aux Claude lancés par FLOW quand plusieurs comptes sont déclarés
    $n = @($Accounts | Where-Object { $_.Enabled }).Count
    "Contexte FLOW : $n comptes Claude sont disponibles et forment une équipe autonome. " +
    "Toute demande de travail de l'utilisateur (créer, modifier, corriger, analyser du code ou des fichiers), même petite, est confiée à l'équipe : " +
    "utilise le skill taches-repartir pour la découper (par morceaux, ou par rôles réalisateur / testeur / documentation / contre-vérification quand elle est petite) " +
    "et la répartir sur tous les comptes ; l'équipe démarre d'elle-même après un court délai. " +
    "Ne traite seul que les simples questions, explications et échanges de conversation."
}

function Pane-Command($pane, $p) {
    $cd = PCwd $p $pane
    $pre = "Set-Location -LiteralPath $(Q $cd); " + (Acct-Env (Acct-For $pane $p))
    switch ([string]$pane.role) {
        'claude'  {
            # plusieurs comptes : ce Claude répartit lui-même les demandes qui s'y prêtent (skill taches-repartir) au lieu de tout faire seul
            $hint = if (Multi-Accounts) { " --append-system-prompt $(Q (Team-Hint))" } else { '' }
            return ("${pre}Clear-Host; claude$hint $($pane.args)").TrimEnd()
        }
        'monitor' {
            $notify = if ($pane.notify -eq $false) { ' -NotifyAfter -1' } elseif ($null -ne $pane.notifyAfter) { " -NotifyAfter $([int]$pane.notifyAfter)" } else { '' }
            return ("${pre}Clear-Host; pwsh -NoProfile -File $(Q (Join-Path $Tools 'claude-monitor.ps1')) -Latest -Watch $(Q (Watch-Arg $p $pane)) -Sock $Sock -Session $(Q (SessionName $p))$notify $($pane.args)").TrimEnd()
        }
        'office' {
            # Bureau : un personnage animé par Claude, une pièce par lot d'agents / workflow / équipe
            return "${pre}Clear-Host; pwsh -NoProfile -File $(Q (Join-Path $Tools 'flow-office.ps1')) -Watch $(Q (Watch-Arg $p $pane)) -Sock $Sock -Session $(Q (SessionName $p))"
        }
        'exchanges' {
            # ce que les Claude de l'équipe s'écrivent (messages directs, annonces, relectures, conseils), en direct
            return "${pre}Clear-Host; pwsh -NoProfile -File $(Q (Join-Path $Tools 'flow-exchanges.ps1')) -Repo $(Q $cd)"
        }
        'team' {
            # fenêtre Équipe : prompt → plan → ouvriers répartis sur les comptes (tools\flow-team.ps1)
            $accs = Team-Accounts
            $opt = ''
            if ($pane.maxTasks) { $opt += " -MaxTasks $([int]$pane.maxTasks)" }
            if ($pane.autoStart) { $opt += " -AutoStart $([int]$pane.autoStart)" }   # secondes avant lancement automatique d'un plan sans risque
            if ($pane.testCommand) { $opt += " -TestCommand $(Q ([string]$pane.testCommand))" }
            if ($pane.workerArgs) { $opt += " -WorkerArgs $(Q ([string]$pane.workerArgs))" }
            if ($pane.review -eq $false) { $opt += ' -NoReview' }                     # "review": false = sans relecture croisée
            if ($pane.maxReviews) { $opt += " -MaxReviews $([int]$pane.maxReviews)" }
            return "${pre}Clear-Host; pwsh -NoProfile -File $(Q (Join-Path $Tools 'flow-team.ps1')) -Repo $(Q $cd) -Sock $Sock -Session $(Q (SessionName $p)) -Accounts $(Q $accs)$opt"
        }
        default   { if ($pane.command) { return "$pre$($pane.command)" } else { return "${pre}Clear-Host" } }
    }
}

function Pane-Title($pane, $p) {
    if ($pane.title) { return [string]$pane.title }
    $ri = RoleOf $pane
    if ([string]$pane.role -eq 'command' -and $pane.command) {
        $c = [string]$pane.command; if ($c.Length -gt 30) { $c = $c.Substring(0, 29) + '…' }
        return "$($ri.Icon) $c"
    }
    if ([string]$pane.role -eq 'claude' -and ((Multi-Accounts) -or $pane.account -or $p.account -or $p.claudeConfigDir)) {
        $a = Acct-For $pane $p
        if ($a) { return "$($ri.Icon) claude · $($a.Label)" }
    }
    if ([string]$pane.role -eq 'monitor' -and (Multi-Accounts) -and $pane.allAccounts -ne $false) { return "$($ri.Icon) moniteur · tous les comptes" }
    "$($ri.Icon) $($ri.Label)"
}

function Step([string]$txt) { Write-Host "   $(PalC ((Get-Date).Millisecond / 1000))◆$R $txt" }

function Start-FlowProfile($p) {
    $s = SessionName $p
    if (Test-Session $s) { Step "session déjà ouverte : rattachement"; return $s }

    $script:Accounts = Get-Accounts
    # les panneaux « perAccount » deviennent un Claude par compte connecté (le profil d'origine n'est pas modifié)
    $p = $p.PSObject.Copy(); $p | Add-Member -NotePropertyName rows -NotePropertyValue @(Expand-Rows $p) -Force
    $bad = Bad-Accounts $p
    if ($bad.Count) { throw "compte(s) inconnu(s) dans le profil : $($bad -join ', ') — voir config\accounts.json" }
    # barre de statut (limites pour le moniteur) branchée sur chaque compte utilisé ou affiché
    $homes = @(foreach ($row in @($p.rows)) { foreach ($pn in @($row.panes)) { (Acct-For $pn $p).Home } })
    if (Uses-Role $p 'monitor') { $homes += @($Accounts | Where-Object { $_.Enabled } | ForEach-Object { $_.Home }) }
    foreach ($h in ($homes | Select-Object -Unique)) { Ensure-StatusLine $h }
    # profils d'équipe : aucune demande de permission, pour aucun Claude (ni les ouvriers ni les Claude du profil) ; l'écran d'avertissement de Claude est écarté
    if ((Uses-Role $p 'team') -or (@(Claude-Panes $p | Where-Object { "$($_.args)" -match 'bypassPermissions' }).Count)) {
        foreach ($ac in @($Accounts | Where-Object { $_.Enabled -and (Test-Path -LiteralPath $_.Home) })) { Ensure-BypassAllowed $ac.Home }
    }
    [void](Install-AllSkills)   # skills FLOW (créer / reprendre / maintenir un projet, répartir les tâches) dans chaque compte
    foreach ($pn in @(Claude-Panes $p)) {
        $a = Acct-For $pn $p
        if ($a -and -not $a.Logged) { Step "$Warn⚠ compte « $($a.Label) » pas encore connecté : Claude proposera de se connecter$R" }
    }

    $cwd = PCwd $p $null
    $win =if ($p.window) { [string]$p.window } else { 'flow' }

    Step "création de la session $Dm$s$R"
    & psmux -L $Sock -f $Conf new-session -d -s $s -n $win -c $cwd *> $null
    for ($k = 0; $k -lt 50 -and -not (Test-Session $s); $k++) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Session $s)) { throw "impossible de créer la session « $s »" }

    $rows = @($p.rows)
    if (-not $rows.Count) { $rows = @([pscustomobject]@{ height = 100; panes = @([pscustomobject]@{ role = 'claude'; width = 100 }) }) }
    $total = ($rows | ForEach-Object { [Math]::Max(1, @($_.panes).Count) } | Measure-Object -Sum).Sum
    Step "découpage en $total panneaux"

    # 1) lignes (découpes verticales sur toute la largeur)
    $rowFirst = [Collections.Generic.List[string]]::new()
    $rowFirst.Add(@(Get-PaneIds $s)[0])
    $hs = @($rows | ForEach-Object { [double]$(if ($_.height) { $_.height } else { 1 }) })
    for ($i = 1; $i -lt $rows.Count; $i++) {
        $rowFirst.Add((Split-Pane $s $rowFirst[$i - 1] '-v' (Pct (SumFrom $hs $i) (SumFrom $hs ($i - 1))) $cwd))
    }

    # 2) colonnes de chaque ligne
    $plan = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $panes = @($rows[$i].panes)
        if (-not $panes.Count) { $panes = @([pscustomobject]@{ role = 'shell'; width = 100 }) }
        $ws = @($panes | ForEach-Object { [double]$(if ($_.width) { $_.width } else { 1 }) })
        $ids = [Collections.Generic.List[string]]::new(); $ids.Add($rowFirst[$i])
        for ($j = 1; $j -lt $panes.Count; $j++) {
            $ids.Add((Split-Pane $s $ids[$j - 1] '-h' (Pct (SumFrom $ws $j) (SumFrom $ws ($j - 1))) $cwd))
        }
        for ($j = 0; $j -lt $panes.Count; $j++) { $plan.Add([pscustomobject]@{ Id = $ids[$j]; Pane = $panes[$j] }) }
    }

    # 3) cibles définitives (les index ne bougent plus) + titres des panneaux (cf. config\psmux.conf)
    foreach ($x in $plan) {
        $x | Add-Member -NotePropertyName T -NotePropertyValue (PaneTarget $s $x.Id)
        $title = Pane-Title $x.Pane $p
        & psmux -L $Sock set -p -t $x.T '@flow_role' $title *> $null
        & psmux -L $Sock set -p -t $x.T '@flow_base' $title *> $null
        # description du panneau : suit le panneau quand on le déplace, sert à enregistrer la disposition
        # le panneau d'un compte ajouté automatiquement se réenregistre sous sa forme d'origine (« perAccount »), pas avec son compte
        $spec = if ($x.Pane.fromPerAccount) { $x.Pane | Select-Object * -ExcludeProperty width, focus, account, fromPerAccount | Add-Member -NotePropertyName perAccount -NotePropertyValue $true -PassThru }
                else { $x.Pane | Select-Object * -ExcludeProperty width, focus }
        & psmux -L $Sock set -p -t $x.T '@flow_spec' ($spec | ConvertTo-Json -Compress -Depth 8) *> $null
        if ([string]$x.Pane.role -eq 'claude') {
            # repère pour le moniteur : il ajoute l'état de Claude dans la bordure de ce panneau
            $ac = Acct-For $x.Pane $p
            if ($ac) { & psmux -L $Sock set -p -t $x.T '@flow_acct' $ac.Id *> $null }
        }
    }

    # 4) attendre que les shells soient prêts, puis lancer les commandes
    Step 'démarrage des terminaux'
    for ($k = 0; $k -lt 60; $k++) {
        $ready = @($plan | Where-Object { ((& psmux -L $Sock capture-pane -p -t $_.T 2>$null) -join '').Trim() }).Count
        if ($ready -ge $plan.Count) { break }
        Start-Sleep -Milliseconds 100
    }
    Step "lancement : $((@($plan | ForEach-Object { (RoleOf $_.Pane).Label } | Select-Object -Unique)) -join ', ')"
    foreach ($x in $plan) {
        & psmux -L $Sock send-keys -t $x.T -l (Pane-Command $x.Pane $p) *> $null
        & psmux -L $Sock send-keys -t $x.T Enter *> $null
    }
    $f = $plan | Where-Object { $_.Pane.focus } | Select-Object -First 1
    if ($f) { & psmux -L $Sock select-pane -t $f.T *> $null }
    # réorganiser les panneaux : fichier du profil (pour Ctrl+B W) et raccourcis
    if ($p.File) { & psmux -L $Sock set -t $s '@flow_profile' ([string]$p.File) *> $null }
    # pour Ctrl+B T (fenêtre Équipe à la demande) : dossier du projet et comptes de la session
    & psmux -L $Sock set -t $s '@flow_cwd' $cwd *> $null
    & psmux -L $Sock set -t $s '@flow_accounts' (Team-Accounts) *> $null
    Bind-PaneKeys
    $s
}

function Bind-PaneKeys {
    # Alt+Maj+flèches : déplacer le panneau · Ctrl+B W : enregistrer · Ctrl+B G et clic droit : menu « Agencer »
    $ps = Join-Path $Tools 'flow-pane.ps1'
    $run = { param($a) "pwsh -NoProfile -File `"$ps`" -Sock $Sock -Target #{session_name}:#{window_index}.#{pane_index} $a" }
    foreach ($d in @(@('Left', 'L'), @('Right', 'R'), @('Up', 'U'), @('Down', 'D'))) {
        & psmux -L $Sock bind-key -n "M-S-$($d[0])" run-shell (& $run "-Move $($d[1])") *> $null
    }
    & psmux -L $Sock bind-key -T prefix W run-shell (& $run '-Save') *> $null
    & psmux -L $Sock bind-key -T prefix T run-shell (& $run '-Team') *> $null
    $menu = @('-T', ' Agencer ',
        'Déplacer à gauche', 'h', "run-shell '$(& $run '-Move L')'",
        'Déplacer à droite', 'l', "run-shell '$(& $run '-Move R')'",
        'Déplacer en haut', 'k', "run-shell '$(& $run '-Move U')'",
        'Déplacer en bas', 'j', "run-shell '$(& $run '-Move D')'",
        '', '', '',
        'Agrandir / rétablir', 'z', 'resize-pane -Z',
        'Enregistrer la disposition', 'w', "run-shell '$(& $run '-Save')'",
        '', '', '',
        'Équipe : répartir une demande en tâches', 't', "run-shell '$(& $run '-Team')'")
    # « Ajouter un Claude » : un bouton par compte déclaré (menu clic droit, ou Ctrl+B puis A)
    $add = @(); $kk = 1
    foreach ($ac in @($Accounts | Where-Object { $_.Enabled })) { $add += @("＋ Ajouter un Claude : $($ac.Label)", "$kk", "run-shell '$(& $run "-AddClaude $($ac.Id)")'"); $kk++ }
    if ($add.Count) {
        $menu += @('', '', '') + $add
        & psmux -L $Sock bind-key -T prefix A display-menu -T ' Ajouter un Claude ' @add *> $null
    }
    & psmux -L $Sock bind-key -T prefix g display-menu @menu *> $null
    # (pas d'enchaînement « select-pane \; display-menu » ici : psmux coupe la commande au « \; » et ouvrait le menu
    #  immédiatement, au lancement — menu qui avalait ensuite les touches envoyées aux panneaux)
    & psmux -L $Sock bind-key -n MouseDown3Pane display-menu @menu *> $null
}

function Enter-Flow([string]$s) {
    Disable-Mouse                       # psmux gère lui-même la souris dans la session
    [Console]::Write("$R$e[?25h$e[2J$e[H")
    & psmux -L $Sock attach -t $s
}

# ───────────────────────── petits écrans interactifs ─────────────────────────
$LastFrameSize = ''
function Show-Frame($lines) {
    $W = [Math]::Max(40, (ConW) - 1)
    $H = [Math]::Max(15, (ConH))
    # fenêtre redimensionnée : tout effacer, sinon des morceaux de l'ancienne image restent à l'écran
    $sz = "$(ConW)x$(ConH)"
    if ($sz -ne $script:LastFrameSize) { [Console]::Write("$e[2J"); $script:LastFrameSize = $sz }
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append("$e[H")
    for ($i = 0; $i -lt $H - 1; $i++) {
        $line = if ($i -lt $lines.Count) { $lines[$i] } else { '' }
        [void]$sb.Append((Fit $line $W)).Append($R).Append("$e[K`n")
    }
    [Console]::Write($sb.ToString())
    Clear-Zones; Hint-Zones $lines
}

function Pick-Item([string]$title, $items, [scriptblock]$label, [scriptblock]$detail, [int]$start = 0) {
    # liste au clavier : renvoie l'index choisi, ou -1 si annulé
    $items = @($items)
    if (-not $items.Count) { return -1 }
    $i = [Math]::Max(0, [Math]::Min($start, $items.Count - 1))
    [Console]::Write("$e[?25l$e[2J")
    while ($true) {
        $L = [Collections.Generic.List[string]]::new()
        $L.Add(''); $L.Add("   $(Grad $title 0.1 0.03)"); $L.Add('')
        $cap = [Math]::Max(3, (ConH) - 22)
        $top = [Math]::Max(0, [Math]::Min($i - [int]($cap / 2), $items.Count - $cap))
        if ($top -gt 0) { $L.Add("     $Dm▲ $top de plus$R") }
        $rowsY = @{}
        for ($k = $top; $k -lt [Math]::Min($items.Count, $top + $cap); $k++) {
            $mark = if ($k -eq $i) { "$(PalC 0.1)$B▸$R" } else { ' ' }
            $txt = & $label $items[$k]
            $rowsY[$L.Count] = $k
            $L.Add("   $mark $Dm[$($k + 1)]$R $(if ($k -eq $i) { $B } else { '' })$txt$R")
        }
        $rest = $items.Count - [Math]::Min($items.Count, $top + $cap)
        if ($rest -gt 0) { $L.Add("     $Dm▼ $rest de plus$R") }
        $L.Add('')
        if ($detail) { foreach ($x in @(& $detail $items[$i])) { $L.Add("   $x") } ; $L.Add('') }
        $L.Add('   ' + ((Key '↑↓' 'choisir'), (Key 'Entrée' 'valider'), (Key 'Échap' 'annuler') -join '   '))
        Show-Frame $L
        foreach ($ry in $rowsY.Keys) { Add-Zone $ry $ry 0 999 @{ Row = $rowsY[$ry] } }
        # clic : choisir ; 2e clic ou double-clic : valider
        $act = Read-Action -Wait
        if ($act.Click) {
            if ($act.Click.Row -eq $i -or $act.Double) { return $act.Click.Row }
            $i = $act.Click.Row; continue
        }
        $k = $act.K
        switch ($k.Key) {
            'UpArrow'   { $i = ($i - 1 + $items.Count) % $items.Count; continue }
            'DownArrow' { $i = ($i + 1) % $items.Count; continue }
            'Enter'     { return $i }
            'Escape'    { return -1 }
        }
        if ("$($k.Key)" -match '^(D|NumPad)([1-9])$' -and [int]$Matches[2] -le $items.Count) { return [int]$Matches[2] - 1 }
    }
}

function Read-Line([string]$title, [string]$prompt, [string]$default = '', [scriptblock]$validate, [string[]]$hints) {
    # saisie d'une ligne de texte : renvoie le texte, ou $null si annulé
    $buf = $default; $errMsg = ''
    [Console]::Write("$e[?25l$e[2J")
    while ($true) {
        $L = [Collections.Generic.List[string]]::new()
        $L.Add(''); $L.Add("   $(Grad $title 0.1 0.03)"); $L.Add('')
        $L.Add("   $prompt")
        $cur = "$(PalC 0.1)▌$R"
        $L.Add("   $(PalC 0.1)❯$R $B$buf$R$cur")
        foreach ($h in $hints) { $L.Add("     $Dm$h$R") }
        $L.Add($(if ($errMsg) { "   $Err✗ $errMsg$R" } else { '' }))
        $L.Add('')
        $L.Add('   ' + ((Key 'Entrée' 'valider'), (Key 'Échap' 'annuler'), (Key 'Ctrl+U' 'effacer') -join '   '))
        Show-Frame $L
        $k = Read-KeyOrHint
        if ($k.Key -eq 'Escape') { return $null }
        if ($k.Key -eq 'Enter') {
            $v = $buf.Trim()
            if ($validate) { $errMsg = [string](& $validate $v); if ($errMsg) { continue } }
            return $v
        }
        if ($k.Key -eq 'Backspace') { if ($buf.Length) { $buf = $buf.Substring(0, $buf.Length - 1) }; $errMsg = ''; continue }
        if ($k.Key -eq 'U' -and ($k.Modifiers -band [ConsoleModifiers]::Control)) { $buf = ''; $errMsg = ''; continue }
        if (-not [char]::IsControl($k.KeyChar)) { $buf += $k.KeyChar; $errMsg = '' }
    }
}

# ───────────────────────── capture d'une session existante ─────────────────────────
function Get-AllSessions {
    $out = [Collections.Generic.List[object]]::new()
    foreach ($pre in @(@(), @('-L', $Sock))) {
        foreach ($l in (& psmux @pre ls 2>$null)) {
            if ("$l" -match '^([^:]+):') {
                $out.Add([pscustomobject]@{ Pre = $pre; Name = $Matches[1]; Where = $(if ($pre.Count) { 'FLOW' } else { 'psmux' }) })
            }
        }
    }
    $out
}

function Detect-Pane($pn, [string]$common) {
    $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($pn.Pid)" -ErrorAction SilentlyContinue)
    $o = [ordered]@{ role = 'shell'; width = $pn.W }
    $cl  = $kids | Where-Object { $_.Name -eq 'claude.exe' -or $_.CommandLine -match '@anthropic-ai[\\/]claude-code' } | Select-Object -First 1
    $mon = $kids | Where-Object { $_.CommandLine -match 'claude-monitor' } | Select-Object -First 1
    if ($cl) {
        $o.role = 'claude'
        $a = ([string]$cl.CommandLine -replace '^\s*("[^"]*"|\S+)\s*', '')
        $a = ($a -replace '(^|\s)(--continue|-c|--resume(\s+[^-]\S*)?|-r(\s+[^-]\S*)?)(?=\s|$)', ' ').Trim()
        if ($a) { $o.args = $a }
    } elseif ($mon) {
        $o.role = 'monitor'
    }
    if ($pn.Active) { $o.focus = $true }
    if ($pn.Cwd -and $pn.Cwd -ne $common) { $o.cwd = Rel $pn.Cwd }
    [pscustomobject]$o
}

function Capture-Session($sess) {
    $fmt = '#{pane_id}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{pane_pid}|#{pane_active}|#{pane_current_path}'
    $raw = & psmux @($sess.Pre) list-panes -t $sess.Name -F $fmt 2>$null
    $panes = foreach ($l in $raw) {
        $f = "$l" -split '\|', 8
        if ($f.Count -lt 8) { continue }
        [pscustomobject]@{ Id = $f[0]; Left = [int]$f[1]; Top = [int]$f[2]; W = [int]$f[3]; H = [int]$f[4]; Pid = [int]$f[5]; Active = $f[6] -eq '1'; Cwd = $f[7].Trim() }
    }
    if (-not $panes) { throw "aucun panneau trouvé dans « $($sess.Name) »" }
    $common = ($panes | Group-Object Cwd | Sort-Object Count -Descending | Select-Object -First 1).Name
    $approx = $false
    $rows = foreach ($g in ($panes | Group-Object Top | Sort-Object { [int]$_.Name })) {
        $ps = @($g.Group | Sort-Object Left)
        if (@($ps.H | Select-Object -Unique).Count -gt 1) { $approx = $true }
        $tw = ($ps.W | Measure-Object -Sum).Sum
        $cells = @($ps | ForEach-Object { Detect-Pane $_ $common })
        foreach ($c in $cells) { $c.width = [int][Math]::Round($c.width / $tw * 100) }
        [pscustomobject]@{ height = $ps[0].H; panes = $cells }
    }
    $rows = @($rows)
    $th = ($rows.height | Measure-Object -Sum).Sum
    foreach ($row in $rows) { $row.height = [int][Math]::Round($row.height / $th * 100) }
    [pscustomobject]@{ Cwd = $common; Rows = $rows; Approx = $approx }
}

function Save-Profile([string]$name, $cap, [string]$from) {
    $file = New-ProfilePath $name
    $p = [pscustomobject][ordered]@{
        name            = $name
        description     = "Capturé depuis « $from » le $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
        order           = (Next-Order)
        session         = "flow-$([IO.Path]::GetFileNameWithoutExtension($file))"
        window          = 'claude'
        cwd             = (Rel $cap.Cwd)
        claudeConfigDir = $null
        rows            = $cap.Rows
    }
    Write-ProfileFile $p $file
    $file
}

function Invoke-Capture {
    # renvoie @{ Msg; Id } ; Id = profil créé (ou $null)
    $all = @(Get-AllSessions)
    if (-not $all.Count) { return @{ Msg = "$Warn(aucune session psmux en cours à capturer)$R" } }
    $i = Pick-Item '◆ CAPTURER UNE SESSION — laquelle ?' $all { param($x) "$($x.Name) $Dm($($x.Where))$R" } $null
    if ($i -lt 0) { return @{ Msg = "$Dm capture annulée$R" } }
    $sess = $all[$i]
    $name = Read-Line '◆ CAPTURER UNE SESSION' "Nom du nouveau profil (session « $($sess.Name) ») :" $sess.Name { param($v) if (-not $v) { 'le nom ne peut pas être vide' } }
    if ($null -eq $name) { return @{ Msg = "$Dm capture annulée$R" } }
    try {
        $cap = Capture-Session $sess
        $file = Save-Profile $name $cap $sess.Name
        $note = if ($cap.Approx) { ' (disposition approximée)' } else { '' }
        @{ Msg = "$Ok✓ profil enregistré : $(Split-Path $file -Leaf)$note$R"; Id = [IO.Path]::GetFileNameWithoutExtension($file) }
    } catch { @{ Msg = "$Err✗ $($_.Exception.Message)$R" } }
}

# ───────────────────────── gestion des profils ─────────────────────────
function Invoke-NewProfile {
    $i = Pick-Item '◆ NOUVEAU PROFIL — disposition' $Presets { param($x) "$($x.Name)  $Dm$($x.Desc)$R" } {
        param($x)
        $tmp = [pscustomobject]@{ rows = ($x.Rows | ConvertFrom-Json) }
        Preview $tmp 60 9
    }
    if ($i -lt 0) { return @{ Msg = "$Dm création annulée$R" } }
    $preset = $Presets[$i]
    $name = Read-Line '◆ NOUVEAU PROFIL' 'Nom du profil :' '' { param($v) if (-not $v) { 'le nom ne peut pas être vide' } }
    if ($null -eq $name) { return @{ Msg = "$Dm création annulée$R" } }
    $dir = Read-Line '◆ NOUVEAU PROFIL' 'Dossier de travail de Claude :' '..' {
        param($v)
        if (-not $v) { return 'indique un dossier' }
        if (-not (Test-Path -LiteralPath (Resolve-Dir $v) -PathType Container)) { "dossier introuvable : $(Resolve-Dir $v)" }
    } @("relatif au dossier FLOW ($Root) ou absolu", "« .. » = $(Resolve-Dir '..')")
    if ($null -eq $dir) { return @{ Msg = "$Dm création annulée$R" } }
    $file = New-ProfilePath $name
    $id = [IO.Path]::GetFileNameWithoutExtension($file)
    $p = [pscustomobject][ordered]@{
        name            = $name
        description     = $preset.Desc
        order           = (Next-Order)
        session         = "flow-$id"
        window          = 'claude'
        cwd             = $dir
        claudeConfigDir = $null
        rows            = ($preset.Rows | ConvertFrom-Json)
    }
    Write-ProfileFile $p $file
    @{ Msg = "$Ok✓ profil « $name » créé ($(Split-Path $file -Leaf))$R"; Id = $id }
}

function Invoke-Duplicate($p) {
    $j = Read-ProfileFile $p.File
    $name = "$($p.name) (copie)"
    $file = New-ProfilePath $name
    $id = [IO.Path]::GetFileNameWithoutExtension($file)
    $j | Add-Member -NotePropertyName name -NotePropertyValue $name -Force
    $j | Add-Member -NotePropertyName session -NotePropertyValue "flow-$id" -Force
    Write-ProfileFile $j $file
    @{ Msg = "$Ok✓ « $name » créé — F2 pour le renommer$R"; Id = $id }
}

function Invoke-Rename($p) {
    $name = Read-Line '◆ RENOMMER LE PROFIL' "Nouveau nom pour « $($p.name) » :" $p.name { param($v) if (-not $v) { 'le nom ne peut pas être vide' } } @('le fichier et la session gardent leur nom actuel')
    if ($null -eq $name -or $name -eq $p.name) { return @{ Msg = '' } }
    $j = Read-ProfileFile $p.File
    $j | Add-Member -NotePropertyName name -NotePropertyValue $name -Force
    Write-ProfileFile $j $p.File
    @{ Msg = "$Ok✓ renommé en « $name »$R"; Id = $p.Id }
}

function Remove-ProfileToTrash($p) {
    New-Item -ItemType Directory -Force $TrashDir | Out-Null
    $dest = Join-Path $TrashDir "$($p.Id)-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    Move-Item -LiteralPath $p.File -Destination $dest
    $dest
}

function Move-ProfileOrder($profiles, [int]$from, [int]$to) {
    # échange deux profils puis renumérote 10, 20, 30… (seuls les fichiers modifiés sont réécrits)
    $list = [Collections.Generic.List[object]]::new(); foreach ($x in $profiles) { $list.Add($x) }
    $tmp = $list[$from]; $list[$from] = $list[$to]; $list[$to] = $tmp
    for ($i = 0; $i -lt $list.Count; $i++) {
        $want = ($i + 1) * 10
        if ($list[$i].order -ne $want) {
            $j = Read-ProfileFile $list[$i].File
            $j | Add-Member -NotePropertyName order -NotePropertyValue $want -Force
            Write-ProfileFile $j $list[$i].File
        }
    }
}

# ───────────────────────── bibliothèques partagées ─────────────────────────
# config\sources.json : { "sources": [ { "id", "name", "type": "folder", "path" } | { "id", "name", "type": "git", "url", "subdir" } ] }
#   folder : un dossier commun (partage réseau, OneDrive, Teams…) lu et écrit directement
#   git    : un dépôt cloné dans config\sources-cache\<id> ; mis à jour au lancement et avec R, publié par commit + push
# Un profil publié est « portable » : sans dossier de travail ni réglage propre à une machine.
# Chacun choisit son dossier au premier lancement (retenu dans config\shared-local.json).
$ShColor = Rgb 168 112 255

function Git-Exe {
    $g = (Get-Command git -ErrorAction SilentlyContinue).Source
    if (-not $g -and (Test-Path "$env:ProgramFiles\Git\cmd\git.exe")) { $g = "$env:ProgramFiles\Git\cmd\git.exe" }
    $g
}

function Git-Do([string]$dir, [string[]]$gargs) {
    $g = Git-Exe
    if (-not $g) { throw 'Git est introuvable (winget install --id Git.Git -e)' }
    $id = @()
    if (-not "$(& $g -C $dir config user.email 2>$null)".Trim()) { $id = @('-c', 'user.name=FLOW', '-c', 'user.email=flow@localhost') }
    $out = & $g -C $dir @id @gargs 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = (($out | ForEach-Object { "$_" }) -join ' ').Trim() }
}

function Get-Sources {
    $j = $null
    try { $j = Get-Content -LiteralPath $SrcFile -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json } catch {}
    , @(foreach ($s in @($j.sources)) {
            if (-not $s.id) { continue }
            $type = if ([string]$s.type -eq 'git') { 'git' } else { 'folder' }
            $base = if ($type -eq 'git') { Join-Path $SrcCache ([string]$s.id) } elseif ($s.path) { Resolve-Dir ([string]$s.path) } else { '' }
            $dir = if ($base -and $s.subdir) { Join-Path $base ([string]$s.subdir) } else { $base }
            [pscustomobject]@{
                Id = [string]$s.id; Name = $(if ($s.name) { [string]$s.name } else { [string]$s.id }); Type = $type
                Url = [string]$s.url; Path = [string]$s.path; Subdir = [string]$s.subdir; Base = $base; Dir = $dir
                Ok = [bool]($dir -and (Test-Path -LiteralPath $dir -PathType Container))
            }
        })
}

function Save-Sources($list) {
    $arr = @(foreach ($s in $list) {
            $o = [ordered]@{ id = $s.Id; name = $s.Name; type = $s.Type }
            if ($s.Type -eq 'git') { $o.url = $s.Url } else { $o.path = $s.Path }
            if ($s.Subdir) { $o.subdir = $s.Subdir }
            [pscustomobject]$o
        })
    New-Item -ItemType Directory -Force (Split-Path $SrcFile) | Out-Null
    Write-JsonAtomic ([ordered]@{ sources = $arr }) $SrcFile -Depth 5 -Backup
}

function Get-SharedLocal {
    $h = @{}
    try { $j = Get-Content -LiteralPath $ShLocFile -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json; foreach ($pr in $j.PSObject.Properties) { $h[$pr.Name] = $pr.Value } } catch {}
    $h
}

function Set-SharedCwd([string]$key, [string]$cwd) {
    $h = Get-SharedLocal
    $h[$key] = [pscustomobject]@{ cwd = $cwd }
    Write-JsonAtomic $h $ShLocFile -Depth 5
}

function Get-SharedProfiles {
    $loc = Get-SharedLocal
    @(foreach ($src in $Sources) {
            if (-not $src.Ok) { continue }
            foreach ($f in (Get-ChildItem -LiteralPath $src.Dir -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
                $j = $null
                try { $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json } catch {}
                if (-not $j -or -not $j.rows) { continue }   # pas un profil FLOW
                $key = "$($src.Id)/$($f.BaseName)"
                $cwd = if ($loc[$key]) { [string]$loc[$key].cwd } else { $null }
                $props = [ordered]@{
                    Id = "sh-$($src.Id)-$($f.BaseName)"; File = $f.FullName; Shared = $src.Name; SharedSrc = $src.Id; SharedKey = $key
                    session = "flow-sh-$(Slugify $src.Id 'src')-$($f.BaseName)"; cwd = $cwd
                }
                if (-not $j.name) { $props.name = $f.BaseName }
                foreach ($kv in $props.GetEnumerator()) { $j | Add-Member -NotePropertyName $kv.Key -NotePropertyValue $kv.Value -Force }
                $j
            }
        })
}

function Sync-Source($src, [switch]$Quiet) {
    # bibliothèque Git : clone (1re fois) ou mise à jour ; renvoie '' ou un message d'erreur
    if ($src.Type -ne 'git') { return '' }
    if ($Quiet) { $env:GIT_TERMINAL_PROMPT = '0' }
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $src.Base '.git'))) {
            New-Item -ItemType Directory -Force $SrcCache | Out-Null
            $r = Git-Do $SrcCache @('clone', '-q', $src.Url, $src.Id)
            if ($r.Code -ne 0) { return "clonage de « $($src.Name) » impossible : $($r.Out)" }
        } else {
            $r = Git-Do $src.Base @('pull', '--ff-only', '-q')
            if ($r.Code -ne 0 -and $r.Out -notmatch 'no tracking information|no such ref|couldn''t find remote ref') { return "mise à jour de « $($src.Name) » impossible : $($r.Out)" }
        }
    } finally { if ($Quiet) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue } }
    ''
}

function Sync-AllSources([switch]$Quiet) {
    @(foreach ($src in $Sources) { if ($src.Type -eq 'git') { $m = Sync-Source $src -Quiet:$Quiet; if ($m) { $m } } })
}

function Start-BackgroundSync {
    # au démarrage : mise à jour des bibliothèques Git sans bloquer le sélecteur (rechargé tout seul ensuite)
    if ($script:BgSyncDone) { return }
    $script:BgSyncDone = $true
    $dirs = @($Sources | Where-Object { $_.Type -eq 'git' -and (Test-Path -LiteralPath (Join-Path $_.Base '.git')) } | ForEach-Object { $_.Base })
    $g = Git-Exe
    if (-not $dirs.Count -or -not $g) { return }
    $null = Start-Job -ScriptBlock {
        param($g, $dirs)
        $env:GIT_TERMINAL_PROMPT = '0'
        foreach ($d in $dirs) { & $g -C $d pull --ff-only -q *> $null }
    } -ArgumentList $g, $dirs
}

function Src-Publish($src, [string]$msg) {
    # bibliothèque Git : enregistre et envoie les changements ; renvoie '' ou un message d'erreur
    if ($src.Type -ne 'git') { return '' }
    $r = Git-Do $src.Base @('add', '-A')
    $r = Git-Do $src.Base @('commit', '-q', '-m', $msg)
    if ($r.Code -ne 0 -and $r.Out -notmatch 'nothing to commit|rien à valider') { return "commit impossible : $($r.Out)" }
    [void](Git-Do $src.Base @('pull', '--rebase', '-q'))   # intègre d'abord les publications des autres
    $r = Git-Do $src.Base @('push', '-q', '-u', 'origin', 'HEAD')
    if ($r.Code -ne 0) { return "envoi refusé : $($r.Out)" }
    ''
}

function Author-Name {
    $g = Git-Exe
    $n = if ($g) { "$(& $g config --global user.name 2>$null)".Trim() } else { '' }
    if ($n) { $n } else { $env:USERNAME }
}

function Export-Portable($p) {
    # copie publiable d'un profil : sans chemins absolus ni réglages propres à cette machine
    $j = Read-ProfileFile $p.File
    if ($j.cwd -and -not $p.Shared) {
        $j | Add-Member -NotePropertyName cwdHint -NotePropertyValue (Split-Path (Resolve-Dir ([string]$j.cwd)) -Leaf) -Force
    }
    foreach ($nm in 'cwd', 'session', 'claudeConfigDir', 'order') { $j.PSObject.Properties.Remove($nm) }
    foreach ($row in @($j.rows)) {
        foreach ($pn in @($row.panes)) {
            if ($pn.cwd -and [IO.Path]::IsPathRooted(([Environment]::ExpandEnvironmentVariables([string]$pn.cwd) -replace '^~', $HOME))) { $pn.PSObject.Properties.Remove('cwd') }
            $pn.PSObject.Properties.Remove('claudeConfigDir')
        }
    }
    $j | Add-Member -NotePropertyName author -NotePropertyValue (Author-Name) -Force
    $j | Add-Member -NotePropertyName published -NotePropertyValue (Get-Date -Format 'yyyy-MM-dd HH:mm') -Force
    $j
}

function Guess-Dir([string]$hint) {
    # dossier probable sur cette machine pour un profil partagé (même nom que chez l'auteur)
    if (-not $hint) { return '' }
    foreach ($c in @((Join-Path (Split-Path $Root) $hint), (Join-Path $HOME "Documents\$hint"), (Join-Path $HOME "source\repos\$hint"), (Join-Path $HOME $hint))) {
        if (Test-Path -LiteralPath $c -PathType Container) { return $c }
    }
    ''
}

function Ask-SharedCwd($p) {
    # demande (et retient) le dossier de travail d'un profil partagé ; renvoie le chemin ou $null
    $hints = @()
    if ($p.cwdHint) { $hints += "chez l'auteur : un dossier nommé « $($p.cwdHint) »" }
    $hints += 'chemin absolu (ou relatif au dossier FLOW) — retenu pour les prochains lancements (O pour le changer)'
    $def = if ($p.cwd) { [string]$p.cwd } else { Guess-Dir ([string]$p.cwdHint) }
    $v = Read-Line "◆ PROFIL PARTAGÉ — $($p.name)" 'Dossier de travail sur cette machine :' $def {
        param($v)
        if (-not $v) { return 'indique un dossier' }
        if (-not (Test-Path -LiteralPath (Resolve-Dir $v) -PathType Container)) { "dossier introuvable : $(Resolve-Dir $v)" }
    } $hints
    if ($null -eq $v) { return $null }
    $full = Resolve-Dir $v
    Set-SharedCwd $p.SharedKey $full
    $full
}

function Prepare-Launch($p) {
    # profil partagé : dossier de travail de cette machine + comptes inconnus ramenés au compte par défaut
    # renvoie @{ P = profil prêt (ou $null) ; Msg ; Asked = un écran de saisie a été affiché }
    if (-not $p.Shared) { return @{ P = $p } }
    $asked = $false
    $cwd = if ($ProjectDir) { $ProjectDir } else { [string]$p.cwd }   # avec un projet, pas de question
    if (-not $cwd -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
        $cwd = Ask-SharedCwd $p; $asked = $true
        if ($null -eq $cwd) { return @{ Msg = "$Dm lancement annulé$R"; Asked = $true } }
    }
    $q = $p | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $q | Add-Member -NotePropertyName cwd -NotePropertyValue $cwd -Force
    $q | Add-Member -NotePropertyName File -NotePropertyValue $null -Force   # Ctrl+B W ne réécrit pas la bibliothèque
    $known = { param($id) [bool]($Accounts | Where-Object { $_.Id -eq $id }) }
    if ($q.account -and -not (& $known ([string]$q.account))) { $q.PSObject.Properties.Remove('account') }
    foreach ($row in @($q.rows)) {
        foreach ($pn in @($row.panes)) { if ($pn.account -and -not (& $known ([string]$pn.account))) { $pn.PSObject.Properties.Remove('account') } }
    }
    @{ P = $q; Asked = $asked }
}

function Invoke-Publish($p) {
    $srcs = @($Sources | Where-Object { $_.Ok })
    if (-not $srcs.Count) { return @{ Msg = "$Warn aucune bibliothèque partagée — B pour en ajouter une$R" } }
    $src = $srcs[0]
    if ($srcs.Count -gt 1) {
        $i = Pick-Item "◆ PUBLIER « $($p.name) » — dans quelle bibliothèque ?" $srcs { param($x) "$ShColor⇄$R $($x.Name)  $Dm$(if ($x.Type -eq 'git') { $x.Url } else { $x.Dir })$R" } $null
        if ($i -lt 0) { return @{ Msg = "$Dm publication annulée$R" } }
        $src = $srcs[$i]
    }
    $base = if ($p.Shared) { [IO.Path]::GetFileNameWithoutExtension($p.File) } else { $p.Id }
    $dest = Join-Path $src.Dir "$base.json"
    if ((Test-Path -LiteralPath $dest) -and $dest -ne $p.File) {
        $ex = $null; try { $ex = Read-ProfileFile $dest } catch {}
        $who = if ($ex.author) { " (publié par $($ex.author)$(if ($ex.published) { " le $($ex.published)" }))" } else { '' }
        $ch = Pick-Item "◆ PUBLIER — « $base » existe déjà dans $($src.Name)$who" @('Remplacer la version partagée', 'Publier sous un autre nom', 'Annuler') { param($x) $x } $null
        if ($ch -eq 1) { $n = 2; while (Test-Path -LiteralPath (Join-Path $src.Dir "$base-$n.json")) { $n++ }; $base = "$base-$n"; $dest = Join-Path $src.Dir "$base.json" }
        elseif ($ch -ne 0) { return @{ Msg = "$Dm publication annulée$R" } }
    }
    $j = Export-Portable $p
    Write-ProfileFile $j $dest
    $pubErr = Src-Publish $src "FLOW : profil « $($p.name) » publié par $($j.author)"
    if ($pubErr) { return @{ Msg = "$Err✗ $($src.Name) : $pubErr (le fichier est prêt dans la copie locale, R pour réessayer plus tard)$R" } }
    @{ Msg = "$Ok⇄ « $($p.name) » publié dans $($src.Name) — les autres le voient au prochain R$R"; Id = "sh-$($src.Id)-$base" }
}

function Invoke-ImportShared($p) {
    # D sur un profil partagé : copie locale modifiable (dossier de travail et comptes adaptés à cette machine)
    $prep = Prepare-Launch $p
    if (-not $prep.P) { return $prep }
    $q = $prep.P
    $file = New-ProfilePath $p.name
    $id = [IO.Path]::GetFileNameWithoutExtension($file)
    $q | Add-Member -NotePropertyName order -NotePropertyValue (Next-Order) -Force
    $q | Add-Member -NotePropertyName session -NotePropertyValue "flow-$id" -Force
    $q | Add-Member -NotePropertyName from -NotePropertyValue "$($p.Shared)$(if ($p.author) { " · $($p.author)" })" -Force
    foreach ($nm in 'cwdHint', 'published', 'author') { $q.PSObject.Properties.Remove($nm) }
    Write-ProfileFile $q $file
    @{ Msg = "$Ok✓ copie locale « $($p.name) » créée — à toi de la modifier (E, F2…)$R"; Id = $id; Asked = $prep.Asked }
}

function Remove-Shared($p) {
    # Suppr ×2 sur un profil partagé : le retire de la bibliothèque (pour tout le monde)
    $src = $Sources | Where-Object { $_.Id -eq $p.SharedSrc } | Select-Object -First 1
    if ($src -and $src.Type -eq 'git') {
        Remove-Item -LiteralPath $p.File -Force
        $pubErr = Src-Publish $src "FLOW : profil « $($p.name) » retiré par $(Author-Name)"
        if ($pubErr) { return @{ Msg = "$Err✗ $($src.Name) : $pubErr$R" } }
        return @{ Msg = "$Warn✗ « $($p.name) » retiré de $($src.Name)$R" }
    }
    $dest = Remove-ProfileToTrash $p
    @{ Msg = "$Warn✗ « $($p.name) » retiré de $($p.Shared) — $B U$R$Warn pour annuler$R"; Undo = @{ From = $dest; To = $p.File; Id = $p.Id; Name = $p.name } }
}

function New-SourceId([string]$name) {
    $id = Slugify $name 'biblio'; $n = 2
    while ($Sources | Where-Object { $_.Id -eq $id }) { $id = "$(Slugify $name 'biblio')-$n"; $n++ }
    $id
}

function Add-FolderSource {
    $v = Read-Line '◆ AJOUTER UN DOSSIER PARTAGÉ' 'Dossier commun (partage réseau, OneDrive, Teams…) :' '' {
        param($v)
        if (-not $v) { return 'indique un dossier' }
        $d = Resolve-Dir $v
        if (-not (Test-Path -LiteralPath $d -PathType Container)) {
            $par = Split-Path $d
            if (-not $par -or -not (Test-Path -LiteralPath $par -PathType Container)) { "dossier introuvable : $d" }
        }
    } @('créé s''il n''existe pas (son dossier parent doit exister)', 'ex. : ~\OneDrive - Entreprise\FLOW-profils   ou   \\serveur\partage\flow')
    if ($null -eq $v) { return $null }
    $d = Resolve-Dir $v
    New-Item -ItemType Directory -Force $d | Out-Null
    $nm = Read-Line '◆ AJOUTER UN DOSSIER PARTAGÉ' 'Nom affiché de la bibliothèque :' (Split-Path $d -Leaf) { param($v) if (-not $v) { 'le nom ne peut pas être vide' } }
    if ($null -eq $nm) { return $null }
    $list = @($Sources) + [pscustomobject]@{ Id = (New-SourceId $nm); Name = $nm; Type = 'folder'; Path = $d; Url = ''; Subdir = '' }
    Save-Sources $list
    "$Ok⇄ bibliothèque « $nm » ajoutée ($d)$R"
}

function Add-GitSource {
    $url = Read-Line '◆ AJOUTER UN DÉPÔT GIT' 'Adresse du dépôt de profils :' '' { param($v) if (-not $v) { 'indique une adresse' } } @(
        'ex. : https://github.com/mon-equipe/flow-profils   (dépôt privé : l''équipe y est invitée)',
        'les profils sont lus dans profiles\ s''il existe, sinon à la racine du dépôt')
    if ($null -eq $url) { return $null }
    $leaf = (($url.TrimEnd('/', '\') -split '[/\\:]')[-1]) -replace '\.git$', ''
    $nm = Read-Line '◆ AJOUTER UN DÉPÔT GIT' 'Nom affiché de la bibliothèque :' $leaf { param($v) if (-not $v) { 'le nom ne peut pas être vide' } }
    if ($null -eq $nm) { return $null }
    $src = [pscustomobject]@{ Id = (New-SourceId $nm); Name = $nm; Type = 'git'; Url = $url; Path = ''; Subdir = ''; Base = ''; Dir = '' }
    $src.Base = Join-Path $SrcCache $src.Id
    [Console]::Write("$e[2J$e[H"); Write-Host "`n   $(Grad "◆ clonage de $url…" 0.1 0.03)`n"
    $syncErr = Sync-Source $src
    if ($syncErr) { return "$Err✗ $syncErr$R" }
    if (Test-Path -LiteralPath (Join-Path $src.Base 'profiles') -PathType Container) { $src.Subdir = 'profiles' }
    Save-Sources (@($Sources) + $src)
    "$Ok⇄ bibliothèque « $nm » ajoutée$(if ($src.Subdir) { ' (dossier profiles\)' })$R"
}

function Invoke-Sources {
    # B : gérer les bibliothèques partagées
    while ($true) {
        $script:Sources = Get-Sources
        $items = @($Sources) + @('+folder', '+git', '+sync')
        $i = Pick-Item '◆ BIBLIOTHÈQUES PARTAGÉES ⇄' $items {
            param($x)
            switch ($x) {
                '+folder' { return "$Ok+$R ajouter un dossier partagé $Dm(réseau, OneDrive, Teams…)$R" }
                '+git'    { return "$Ok+$R ajouter un dépôt Git $Dm(GitHub, GitLab…)$R" }
                '+sync'   { return "$Info↻$R tout synchroniser maintenant" }
            }
            $nb = if ($x.Ok) { @(Get-ChildItem -LiteralPath $x.Dir -Filter *.json -File -ErrorAction SilentlyContinue).Count } else { 0 }
            $st = if ($x.Ok) { "$Dm$nb fichier(s)$R" } else { "$Err✗ introuvable$R" }
            "$ShColor⇄$R $B$($x.Name)$R  $Dm$(if ($x.Type -eq 'git') { 'git' } else { 'dossier' })$R  $st"
        } {
            param($x)
            if ($x -is [string]) {
                switch ($x) {
                    '+folder' { @("$Dm Un dossier que toute l'équipe voit. Chacun l'ajoute ici avec son propre chemin.$R") }
                    '+git'    { @("$Dm Un dépôt Git commun : FLOW le clone, le met à jour (R) et y publie (commit + push).$R") }
                    '+sync'   { @("$Dm Récupère les dernières publications des bibliothèques Git.$R") }
                }
            } else {
                @("$Dm emplacement$R  $(if ($x.Type -eq 'git') { $x.Url } else { $x.Dir })",
                  "$Dm profils lus dans$R  $($x.Dir)",
                  '', "$Dm P dans la liste publie le profil sélectionné ; Suppr ×2 sur un profil partagé le retire.$R")
            }
        }
        if ($i -lt 0) { return @{ Msg = '' } }
        $it = $items[$i]
        if ($it -eq '+folder') { $m = Add-FolderSource; if ($m) { return @{ Msg = $m } }; continue }
        if ($it -eq '+git') { $m = Add-GitSource; if ($m) { return @{ Msg = $m } }; continue }
        if ($it -eq '+sync') {
            $errs = Sync-AllSources
            return @{ Msg = $(if ($errs.Count) { "$Err✗ $($errs -join ' · ')$R" } else { "$Ok↻ bibliothèques à jour$R" }) }
        }
        $acts = @('Synchroniser maintenant', 'Ouvrir le dossier', 'Retirer de la liste (les fichiers ne sont pas supprimés)', 'Retour')
        $a = Pick-Item "◆ $($it.Name)" $acts { param($x) $x } $null
        switch ($a) {
            0 { $m = Sync-Source $it; return @{ Msg = $(if ($m) { "$Err✗ $m$R" } else { "$Ok↻ « $($it.Name) » à jour$R" }) } }
            1 { if ($it.Ok) { Start-Process explorer.exe -ArgumentList "`"$($it.Dir)`"" }; return @{ Msg = "$Info↗ $($it.Dir)$R" } }
            2 {
                Save-Sources @($Sources | Where-Object { $_.Id -ne $it.Id })
                return @{ Msg = "$Warn✗ « $($it.Name) » retirée de la liste$R" }
            }
        }
    }
}

# ───────────────────────── écran des comptes ─────────────────────────
function Acct-Chips($p) {
    # pastilles des comptes utilisés par les panneaux Claude d'un profil (affichées dans la liste)
    $bad = Bad-Accounts $p
    if ($bad.Count -and -not $p.Shared) { return "  $Err✗ compte inconnu : $($bad -join ', ')$R" }
    if (-not ((Multi-Accounts) -or $p.account -or $p.claudeConfigDir -or @(Claude-Panes $p | Where-Object { $_.account }).Count)) { return '' }
    $seen = @{}
    $chips = foreach ($pn in @(Claude-Panes $p)) {
        $a = Acct-For $pn $p
        if (-not $a -and $p.Shared) { $a = Default-Acct }   # profil partagé : compte inconnu ici → compte par défaut
        if (-not $a -or $seen[$a.Id]) { continue }
        $seen[$a.Id] = $true
        "$(RgbA $a.Rgb)◆ $($a.Label)$R$(if (-not $a.Logged) { "$Warn ○$R" })"
    }
    if ($chips) { '  ' + ($chips -join ' ') } else { '' }
}

function Age([double]$sec) {
    if ($sec -lt 60) { return "à l'instant" }
    if ($sec -lt 3600) { return "il y a $([int][Math]::Floor($sec / 60)) min" }
    if ($sec -lt 86400) { return "il y a $([int][Math]::Floor($sec / 3600)) h" }
    "il y a $([int][Math]::Floor($sec / 86400)) j"
}

function Get-LiveInfo([string]$s) {
    # état en direct d'une session ouverte : âge + état de chaque Claude (écrit par le moniteur dans les panneaux)
    $txt = ''
    $c = & psmux -L $Sock display-message -t $s -p '#{session_created}' 2>$null
    if ("$c" -match '^\d+$') { $txt += " $Dm· lancée $(Age ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$c))$R" }
    foreach ($l in (& psmux -L $Sock list-panes -t $s -F '#{@flow_acct}|#{@flow_state}|#{@flow_ctx}' 2>$null)) {
        $f = "$l" -split '\|', 3
        if ($f.Count -lt 3 -or -not $f[0]) { continue }
        $a = $Accounts | Where-Object { $_.Id -eq $f[0] } | Select-Object -First 1
        $col = if ($a) { RgbA $a.Rgb } else { '' }
        $nm = if ($a) { $a.Short } else { $f[0] }
        $stTxt = switch ($f[1]) {
            'busy' { "$Warn● travaille$R" }
            'done' { "$B$(Rgb 96 232 196)✓ à toi$R" }
            'idle' { "$Dm○ en attente$R" }
            'off'  { "$Warn○ non connecté$R" }
            default { '' }
        }
        $ctx = if ("$($f[2])" -match '^\d+$') { " $Dm$($f[2])%$R" } else { '' }
        if ($stTxt -or $ctx) { $txt += "  $col◆ $nm$R $stTxt$ctx" }
    }
    $txt
}

function Read-AcctLimits($a) {
    try { $d = Get-Content -LiteralPath (Join-Path $a.Home 'monitor-status.json') -Raw | ConvertFrom-Json } catch { return $null }
    $d
}

function Invoke-Accounts($profiles) {
    $script:Accounts = Get-Accounts
    $items = @($Accounts) + @([pscustomobject]@{ Add = $true }) + @(if (@($Accounts | Where-Object { $_.Dir }).Count) { [pscustomobject]@{ Remove = $true } })
    $i = Pick-Item "◆ COMPTES CLAUDE — $($Accounts.Count) compte(s) · Entrée : connecter / ouvrir" $items {
        param($a)
        if ($a.Add) { return "$Ok＋ ajouter un compte Claude…$R" }
        if ($a.Remove) { return "$Warn－ retirer un compte…$R" }
        $st = if ($a.Logged) { "$Ok● connecté$R" } else { "$Warn○ pas encore connecté$R" }
        $off = if (-not $a.Enabled) { "  $Dm(désactivé)$R" } else { '' }
        "$(RgbA $a.Rgb)$($a.Label)$R $Dm[$($a.Id)]$R  $st$off"
    } {
        param($a)
        if ($a.Add) { return @("$Dm Autant de comptes que tu veux : chacun a son dossier, ses identifiants et ses limites.$R",
                               "$Dm Le profil Équipe répartit les tâches sur tous les comptes connectés.$R") }
        if ($a.Remove) { return @("$Dm Retire un compte de la liste de FLOW (avec ou sans le déconnecter). Le compte par défaut de Claude Code ne se retire pas.$R") }
        $lines = @("$Dm dossier$R  $($a.Home)$(if (-not $a.Dir) { "  $Dm(compte par défaut)$R" })")
        $lim = Read-AcctLimits $a
        if ($lim -and $lim.rate_limits) {
            $w = $lim.rate_limits.seven_day; $f = $lim.rate_limits.five_hour
            $lines += "$Dm limites$R  semaine $B$(if ($w) { "$([int]$w.used_percentage)%" } else { '—' })$R   session $B$(if ($f) { "$([int]$f.used_percentage)%" } else { '—' })$R  $Dm(dernière mesure)$R"
        } else { $lines += "$Dm limites$R  pas encore mesurées" }
        $used = @($profiles | Where-Object { $pp = $_; @(Claude-Panes $pp | Where-Object { (Acct-For $_ $pp).Id -eq $a.Id }).Count } | ForEach-Object { $_.name })
        $lines += "$Dm profils$R  $(if ($used) { $used -join ', ' } else { '(aucun)' })"
        $lines += ''
        $m = Acct-Mail $a
        if ($m) { $lines += "$Dm connecté en tant que$R  $m" }
        $lines += ''
        if ($a.Logged) { $lines += "$Dm Entrée ouvre une nouvelle fenêtre Claude avec ce compte (/login pour en changer, /exit pour fermer).$R" }
        else { $lines += "$Dm Entrée : se connecter ici même (lien à ouvrir dans le navigateur, puis code à coller).$R" }
        $lines += "$Dm Les comptes se modifient dans config\accounts.json.$R"
        $lines
    }
    if ($i -lt 0) { return @{ Msg = '' } }
    $a = $items[$i]
    if ($a.Remove) { return @{ Msg = (Invoke-RemoveAccount) } }
    if ($a.Add) { $a = Add-Account; if (-not $a) { return @{ Msg = "$Dm ajout annulé$R" } } }
    if (-not $a.Logged -or ($a.Dir -and (Dup-Of $a))) {
        $logged = Connect-Account $a -Relogin:$a.Logged
        return @{ Msg = $(if ($logged) { "$Ok✓ « $($a.Label) » est connecté$R" } else { "$Warn○ « $($a.Label) » n'est pas encore connecté (C pour réessayer)$R" }) }
    }
    Start-AccountLogin $a
    @{ Msg = "$Info↗ Claude ouvert avec « $($a.Label) » dans une nouvelle fenêtre — l'état se met à jour tout seul$R" }
}

# ───────────────────────── diagnostic ─────────────────────────
function Invoke-Doctor {
    $cnt = @{ bad = 0 }
    function Line([bool]$good, [string]$what, [string]$fix = '') {
        if ($good) { Write-Host "  $Ok✓$R $what" } else { $cnt.bad++; Write-Host "  $Err✗$R $what"; if ($fix) { Write-Host "      $Dm→ $fix$R" } }
    }
    Write-Host ''
    Write-Host "  $(Grad "◆ FLOW — diagnostic$(if ($FlowVersion) { " (v$FlowVersion)" })" 0.1 0.03)"
    Write-Host "  $Dm$Root$R"; Write-Host ''
    Write-Host "  $B Outils$R"
    Line ($PSVersionTable.PSVersion.Major -ge 7) "PowerShell $($PSVersionTable.PSVersion)" 'winget install --id Microsoft.PowerShell'
    $mux = Get-Command psmux -ErrorAction SilentlyContinue
    Line ([bool]$mux) $(if ($mux) { "psmux : $((& psmux -V 2>$null | Select-Object -Last 1))" } else { 'psmux' }) 'winget install psmux'
    $cl = Get-Command claude -ErrorAction SilentlyContinue
    Line ([bool]$cl) $(if ($cl) { "Claude Code $((& claude --version 2>$null | Select-Object -First 1))" } else { 'Claude Code' }) 'winget install --id Anthropic.ClaudeCode'
    $gt = Get-Command git -ErrorAction SilentlyContinue
    Line ([bool]$gt) $(if ($gt) { "Git $((& git --version 2>$null) -replace 'git version ', '')" } else { 'Git' }) 'winget install --id Git.Git'
    if ($gt) { $who = "$(& git config user.email 2>$null)".Trim(); Line ([bool]$who) $(if ($who) { "identité Git : $who" } else { 'identité Git non configurée' }) 'git config --global user.name "…" ; git config --global user.email "…" (sinon les commits de l''équipe sont signés « FLOW »)' }
    Line ([bool](Get-Command wt.exe -ErrorAction SilentlyContinue)) 'Windows Terminal' 'winget install --id Microsoft.WindowsTerminal'
    Line (Test-Path -LiteralPath (Join-Path $Root 'FLOW.exe')) 'application FLOW.exe' 'pwsh -File FLOW.ps1 -InstallShortcut'
    Write-Host ''; Write-Host "  $B Comptes Claude$R"
    foreach ($a in $Accounts) {
        $m = Acct-Mail $a
        Line $a.Logged "$($a.Label) [$($a.Id)] : $(if ($a.Logged) { "connecté$(if ($m) { " ($m)" })" } else { 'pas connecté' })" "pwsh -File FLOW.ps1 -Login $($a.Id)  (ou touche C dans le sélecteur)"
        if ($a.Logged -and -not (Test-Path -LiteralPath (Join-Path $a.Home 'skills\projet-creer'))) { Line $false "$($a.Label) : skills FLOW non installés" 'pwsh -File FLOW.ps1 -InstallSkills' }
    }
    $dupe = @($Accounts | Where-Object { $_.Logged } | ForEach-Object { Acct-Mail $_ } | Where-Object { $_ } | Group-Object | Where-Object Count -gt 1)
    if ($dupe.Count) { Line $false "deux comptes ont la même adresse ($($dupe[0].Name))" 'reconnecte l''un des deux avec une autre adresse' }
    $env_ = @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN') | Where-Object { Test-Path "Env:$_" }
    if ($env_) { Write-Host "  $Warn!$R variable(s) d'authentification présente(s) dans l'environnement : $($env_ -join ', ') $Dm(FLOW les retire dans ses panneaux)$R" }
    Write-Host ''; Write-Host "  $B Fichiers de configuration$R"
    foreach ($f in @($AcctFile, $StateFile, $ProjFile, $SrcFile)) {
        if (-not (Test-Path -LiteralPath $f)) { Write-Host "  $Dm– $(Split-Path $f -Leaf) : absent (normal s'il n'a pas encore servi)$R"; continue }
        $okj = try { [void](Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop); $true } catch { $false }
        Line $okj "$(Split-Path $f -Leaf) lisible" "fichier abîmé : une copie « $(Split-Path $f -Leaf).bak » existe peut-être à côté"
    }
    $np = @(Get-Profiles).Count; Line ($np -gt 0) "$np profil(s) lisible(s)" 'dossier profiles\ vide ou illisible'
    Write-Host ''; Write-Host "  $B Sessions$R"
    if ($mux) {
        $ss = @(& psmux -L $Sock ls 2>$null | Where-Object { $_ })
        if ($ss.Count) { Write-Host "  $Ok✓$R $($ss.Count) session(s) FLOW ouverte(s) :"; $ss | ForEach-Object { Write-Host "      $_" } } else { Write-Host "  $Dm– aucune session FLOW ouverte$R" }
    }
    if ($ProjectDir) { Write-Host "  $Dm projet courant : $ProjectDir$R" }
    Write-Host ''; Write-Host "  $B Journal$R $Dm($($global:FlowLogFile))$R"
    if (Test-Path -LiteralPath $global:FlowLogFile) { Get-Content -LiteralPath $global:FlowLogFile -Tail 12 -Encoding utf8 | ForEach-Object { Write-Host "  $Dm$_$R" } } else { Write-Host "  $Dm(vide)$R" }
    Write-Host ''
    if ($cnt.bad) { Write-Host "  $Err$($cnt.bad) point(s) à corriger.$R" } else { Write-Host "  $Ok✓ Tout est en ordre.$R" }
    Write-Host ''
}

# ───────────────────────── raccourci bureau ─────────────────────────
function Build-App {
    # compile app\FlowApp.cs → FLOW.exe (csc du .NET Framework, présent sur tout Windows 10/11)
    $src = Join-Path $Root 'app\FlowApp.cs'
    $exe = Join-Path $Root 'FLOW.exe'
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    if (-not (Test-Path -LiteralPath $src) -or -not (Test-Path -LiteralPath $csc)) { return $null }
    $ico = Join-Path $Root 'assets\flow.ico'
    $cargs = @('/nologo', '/target:winexe', '/optimize+', "/out:$exe", '/r:System.Web.Extensions.dll', '/r:System.Windows.Forms.dll', '/r:System.Drawing.dll')
    if (Test-Path -LiteralPath $ico) { $cargs += "/win32icon:$ico" }
    $out = & $csc @cargs $src 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "compilation de FLOW.exe impossible :`n$($out -join "`n")" -ForegroundColor Yellow; return $null }
    $exe
}

function Install-Shortcut {
    # raccourcis « FLOW » (bureau + menu Démarrer) vers l'application FLOW.exe.
    # Ne jamais viser wt.exe / pwsh.exe directement : ce sont des alias vers un dossier WindowsApps versionné,
    # que le raccourci fige et qui disparaît à la mise à jour suivante de Windows Terminal.
    $exe = Build-App
    $ws = New-Object -ComObject WScript.Shell
    $ico = Join-Path $Root 'assets\flow.ico'
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'FLOW.lnk'
    $paths = @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'FLOW.lnk'), $menu)
    foreach ($lnkPath in $paths) {
        $lnk = $ws.CreateShortcut($lnkPath)
        if ($exe) {
            $lnk.TargetPath = $exe
            $lnk.Arguments = ''
        } else {
            $lnk.TargetPath = Join-Path $env:WINDIR 'System32\cmd.exe'
            $lnk.Arguments = "/c `"$(Join-Path $Root 'FLOW.cmd')`""
            $lnk.WindowStyle = 7
        }
        $lnk.WorkingDirectory = $Root
        if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = "$ico,0" }
        $lnk.Description = 'FLOW — choisir un projet, puis Claude × psmux'
        $lnk.Save()
    }
    $paths -join ' · '
}

# ───────────────────────── sélecteur ─────────────────────────
$Logo = @(
    '███████╗██╗      ██████╗ ██╗    ██╗'
    '██╔════╝██║     ██╔═══██╗██║    ██║'
    '█████╗  ██║     ██║   ██║██║ █╗ ██║'
    '██╔══╝  ██║     ██║   ██║██║███╗██║'
    '██║     ███████╗╚██████╔╝╚███╔███╔╝'
    '╚═╝     ╚══════╝ ╚═════╝  ╚══╝╚══╝ '
)

function Preview($p, [int]$PW, [int]$PH) {
    $rows = @($p.rows)
    if (-not $rows.Count) { return @("$Dm(aucun panneau défini)$R") }
    $th = ($rows | ForEach-Object { [double]$(if ($_.height) { $_.height } else { 1 }) } | Measure-Object -Sum).Sum
    $out = [Collections.Generic.List[string]]::new()
    foreach ($row in $rows) {
        $h = [Math]::Max(3, [int][Math]::Round(([double]$(if ($row.height) { $row.height } else { 1 })) / $th * $PH))
        $panes = @($row.panes); if (-not $panes.Count) { $panes = @([pscustomobject]@{ role = 'shell'; width = 100 }) }
        $tw = ($panes | ForEach-Object { [double]$(if ($_.width) { $_.width } else { 1 }) } | Measure-Object -Sum).Sum
        $cells = @(); $used = 0
        for ($j = 0; $j -lt $panes.Count; $j++) {
            $w = if ($j -eq $panes.Count - 1) { $PW - $used } else { [Math]::Max(10, [int][Math]::Round(([double]$(if ($panes[$j].width) { $panes[$j].width } else { 1 })) / $tw * $PW)) }
            $used += $w
            $cells += , @($panes[$j], $w)
        }
        for ($y = 0; $y -lt $h; $y++) {
            $sb = [Text.StringBuilder]::new()
            foreach ($c in $cells) {
                $pane = $c[0]; $w = $c[1]; $ri = RoleOf $pane
                $rgb = $ri.Rgb; $lbl = $ri.Label
                if ([string]$pane.role -eq 'claude' -and ((Multi-Accounts) -or $pane.account -or $p.account)) {
                    # panneau Claude : couleur et nom court du compte
                    $ac = Acct-For $pane $p
                    if (-not $ac -and $p.Shared) { $ac = Default-Acct }
                    if ($ac) { $rgb = $ac.Rgb; $lbl = "claude $($ac.Short)" } else { $rgb = @(255, 90, 90); $lbl = 'compte ?' }
                }
                $bc = if ($pane.focus) { RgbA $rgb } else { RgbA (Mix $rgb @(30,30,40) 0.55) }
                if ($y -eq 0) { [void]$sb.Append("$bc╭$('─' * ($w - 2))╮$R") }
                elseif ($y -eq $h - 1) { [void]$sb.Append("$bc╰$('─' * ($w - 2))╯$R") }
                elseif ($y -eq [int][Math]::Floor(($h - 1) / 2)) {
                    $lab = "$($ri.Icon) $lbl$(if ($pane.focus) { ' ★' } else { '' })"
                    if ($lab.Length -gt $w - 2) { $lab = $lab.Substring(0, $w - 2) }
                    $padL = [int][Math]::Floor(($w - 2 - $lab.Length) / 2)
                    $padR = $w - 2 - $lab.Length - $padL
                    [void]$sb.Append("$bc│$R$(' ' * $padL)$B$(RgbA $rgb)$lab$R$(' ' * $padR)$bc│$R")
                } else { [void]$sb.Append("$bc│$R$(' ' * ($w - 2))$bc│$R") }
            }
            $out.Add($sb.ToString())
        }
    }
    $out
}

function HelpRow($k1, $t1, $k2, $t2) { $a = Key $k1 $t1; $a + (' ' * [Math]::Max(1, 34 - (VisLen $a))) + (Key $k2 $t2) }
$HelpLines = @(
    (HelpRow 'Entrée' 'lancer / rattacher'        '1-9' 'lancement direct')
    (HelpRow '/' 'chercher (Échap efface)'        'N' 'nouveau profil')
    (HelpRow 'D' 'dupliquer'                      'F2' 'renommer')
    (HelpRow 'E' 'éditer le JSON'                 'Suppr' 'supprimer (×2, U annule)')
    (HelpRow 'Maj+↑↓' 'déplacer (+/− pavé num.)'  'S' 'capturer une session')
    (HelpRow 'K' 'fermer la session (×2)'         'Maj+K' 'fermer toutes (×2)')
    (HelpRow 'C' 'comptes Claude / connexion'     'R' 'recharger + synchroniser')
    (HelpRow 'P' 'publier (partager le profil)'   'B' 'bibliothèques partagées')
    (HelpRow 'O' 'dossier d''un profil partagé'   'D' 'sur un partagé : copie à toi')
    (HelpRow 'J' 'changer de projet'              'Q / Échap' 'quitter')
    (Key '?' 'cette aide')
    ''
    "$Dm Dans une session :$R $(Key 'Ctrl+B D' 'ou') $(Key 'Ctrl+B F' 'revenir ici')"
    "   $(Key 'Ctrl+B T' 'Équipe : répartir une demande en tâches sur les comptes')"
    "   $(Key 'Alt+flèches' 'changer de panneau')   $(Key 'Alt+Z' 'agrandir le panneau')"
)

function Update-View($U, [string]$keepId) {
    if (-not $keepId -and $U.View.Count -and $U.Sel -lt $U.View.Count) { $keepId = $U.View[$U.Sel].Id }
    $f = $U.Filter
    $U.View = @(if ($f) {
            $U.Profiles | Where-Object { "$($_.name) $($_.description) $($_.Id)".IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
        } else { $U.Profiles })
    $U.Sel = 0
    for ($i = 0; $i -lt $U.View.Count; $i++) { if ($U.View[$i].Id -eq $keepId) { $U.Sel = $i; break } }
}

function Reload-Profiles($U, [string]$keepId) {
    $script:Accounts = Get-Accounts
    $script:Sources = Get-Sources
    $U.Profiles = @(Get-Profiles) + @(Get-SharedProfiles)   # les tiens, puis ceux des bibliothèques
    $U.Sig = Get-ProfilesSig
    Update-View $U $keepId
    $U.Refresh = $true
}

function Draw-Selector($U, $deps) {
    $W = [Math]::Max(40, (ConW) - 1)
    $H = [Math]::Max(15, (ConH))
    $tick = $U.Tick
    $L = [Collections.Generic.List[string]]::new()
    $ph = $tick * 0.01
    $compact = $H -lt 38
    $dl = ($deps.GetEnumerator() | Sort-Object Name | ForEach-Object {
            if ($_.Value) { "$Ok✓$R $Dm$($_.Name)$R" } else { "$(Rgb 255 90 90)✗ $($_.Name)$R" } }) -join '  '
    # comptes Claude : une ligne par compte, en clair (connecté ou non, adresse). Relue de temps en temps : une connexion faite
    # ailleurs apparaît d'elle-même.
    if (($U.Tick % 25) -eq 0 -or -not $script:AcctLines) {
        $script:Accounts = Get-Accounts
        $script:AcctLines = @($Accounts | Where-Object { $_.Enabled } | ForEach-Object {
                if ($_.Logged) { $mail = Acct-Mail $_; "   $(RgbA $_.Rgb)●$R $B$($_.Label)$R  $Ok✓ connecté$R$(if ($mail) { "  $Dm$mail$R" })" }
                else { "   $(RgbA $_.Rgb)○$R $B$($_.Label)$R  $Warn$B✗ PAS CONNECTÉ$R  $Dm— touche C pour le connecter$R" } })
        $dups = @($Accounts | Where-Object { $_.Enabled -and $_.Logged -and (Dup-Of $_) })
        if ($dups.Count) {
            $script:AcctLines += "   $Warn$B⚠ « $($dups[0].Label) » et « $((Dup-Of $dups[0]).Label) » sont connectés avec la MÊME adresse : cela ne fait qu'un seul compte.$R"
            $script:AcctLines += "   $Dm  Touche C, puis Entrée sur « $($dups[-1].Label) » : il se reconnecte (fenêtre privée du navigateur pour l'autre adresse).$R"
        }
    }
    # projet courant (touche J)
    $pj = if ($ProjectDir) { "$B$(PalC ($ph + 0.2))▣ $(Split-Path $ProjectDir -Leaf)$R" } else { "$Dm◇ sans projet$R" }
    $dl = "$pj $Dm(J)$R   $Dm│$R  " + $dl

    # — en-tête —
    if ($compact) {
        $L.Add('')
        $L.Add("   $B$(Grad '◆ F L O W' $ph 0.04)$R  $Dm sélecteur de profils$R   $dl")
        foreach ($x in $script:AcctLines) { $L.Add($x) }
    } else {
        $L.Add('')
        for ($li = 0; $li -lt $Logo.Count; $li++) { $L.Add('   ' + (Grad $Logo[$li] ($ph + $li * 0.035) 0.012)) }
        $wave = -join (0..33 | ForEach-Object { '▁▂▃▄▅▆▇█'[[int][Math]::Round((([Math]::Sin($_ * 0.35 + $tick * 0.25) + 1) / 2) * 7)] })
        $L.Add('   ' + (Grad $wave ($ph + 0.3) 0.015))
        $L.Add("   $Dm sélecteur de profils · Claude × psmux$(if ($FlowVersion) { " · v$FlowVersion" })$R")
        $L.Add("   $dl")
        foreach ($x in $script:AcctLines) { $L.Add($x) }
    }

    # — recherche —
    if ($U.Searching -or $U.Filter) {
        $cur = if ($U.Searching -and ($tick % 10) -lt 6) { "$(PalC $ph)▌$R" } else { ' ' }
        $L.Add("   $Warn/$R $B$($U.Filter)$R$cur  $Dm$($U.View.Count) résultat(s) · Entrée lancer · Échap effacer$R")
    } else { $L.Add('') }

    # — place disponible —
    $showPrev = $H -ge 28
    $prevH = if ($U.Help) { $HelpLines.Count + 3 } elseif ($showPrev) { 13 } else { 0 }
    $footer = 3
    $avail = $H - 1 - $L.Count - $prevH - $footer - 1
    $n = $U.View.Count
    $hasSh = [bool]($U.View | Where-Object { $_.Shared } | Select-Object -First 1)
    $cap = [Math]::Max(1, [int][Math]::Floor(($avail - [int]$hasSh) / 2))   # 1 ligne pour le titre « partagés »
    if ($U.Sel -lt $U.Top) { $U.Top = $U.Sel }
    if ($U.Sel -ge $U.Top + $cap) { $U.Top = $U.Sel - $cap + 1 }
    $U.Top = [Math]::Max(0, [Math]::Min($U.Top, [Math]::Max(0, $n - $cap)))

    # — liste —
    if (-not $U.Profiles.Count) {
        $L.Add("   $($Warn)Aucun profil — N pour en créer un, S pour capturer une session.$R"); $L.Add('')
    } elseif (-not $n) {
        $L.Add("   $Dm(aucun profil ne correspond à « $($U.Filter) »)$R"); $L.Add('')
    }
    $acc = PalC ($tick * 0.02)
    $profRows = @()
    for ($i = $U.Top; $i -lt [Math]::Min($n, $U.Top + $cap); $i++) {
        $p = $U.View[$i]
        $isSel = $i -eq $U.Sel
        $mark = if ($isSel) { "$acc$B▸$R" } else { ' ' }
        $num = if ($i -lt 9) { "$Dm[$($i + 1)]$R" } else { '   ' }
        $nm = if ($isSel) { "$B$(Grad $p.name ($ph + 0.2) 0.05)" } else { "$B$($p.name)$R" }
        $st = if ($U.Open[$p.Id]) { "$Ok● ouverte$R$(if ($U.Live[$p.Id]) { $U.Live[$p.Id] })" } else { "$Dm○$R" }
        $acct = Acct-Chips $p
        if ($p.Shared -and ($i -eq $U.Top -or -not $U.View[$i - 1].Shared)) {
            $L.Add("     $ShColor── ⇄ partagés $Dm(P publier · D copie à toi · B bibliothèques)$R $ShColor──$R")
        }
        $sh = if ($p.Shared) { "  $ShColor⇄ $($p.Shared)$R" } else { '' }
        $by = if ($p.Shared -and $p.author) { "par $($p.author)$(if ($p.description) { ' · ' })" } else { '' }
        $profRows += @{ Y = $L.Count; Idx = $i }
        $L.Add("   $mark $num $nm  $st$sh$acct")
        $L.Add("         $Dm$by$(if ($p.description) { $p.description } else { '' })$R")
    }
    $above = $U.Top; $below = [Math]::Max(0, $n - ($U.Top + $cap))
    $ind = @()
    if ($above) { $ind += "▲ $above au-dessus" }
    if ($below) { $ind += "▼ $below en dessous" }
    $L.Add($(if ($ind) { "     $Dm$($ind -join ' · ')$R" } else { '' }))

    # — aperçu ou aide —
    $bc = Rgb 70 74 96
    $pw = [Math]::Min(70, $W - 8)
    if ($U.Help) {
        $L.Add("   $bc╭─ $R$B$(PalC ($ph + 0.5))?$R$B AIDE$R $bc$('─' * [Math]::Max(0, $pw - 9))╮$R")
        foreach ($hl in $HelpLines) { $L.Add("   $bc│$R $(Fit $hl ($pw - 2)) $bc│$R") }
        $L.Add("   $bc╰$('─' * $pw)╯$R")
    } elseif ($showPrev -and $n) {
        $p = $U.View[$U.Sel]
        $L.Add("   $bc╭─ $R$B$(PalC ($ph + 0.5))◈$R$B APERÇU$R $bc$('─' * [Math]::Max(0, $pw - 11))╮$R")
        foreach ($pl in (Preview $p ($pw - 2) 9)) { $L.Add("   $bc│$R $(Fit $pl ($pw - 2)) $bc│$R") }
        $L.Add("   $bc╰$('─' * $pw)╯$R")
        $dirTxt = if ($ProjectDir) { "$ProjectDir $Dm(projet · J pour changer)$R" } elseif (-not $p.Shared) { Resolve-Dir $p.cwd } elseif ($p.cwd) { "$($p.cwd) $Dm(O pour changer)$R" } else { "$Warn à choisir au premier lancement$R$(if ($p.cwdHint) { " $Dm(chez l'auteur : « $($p.cwdHint) »)$R" })" }
        $L.Add("   $Dm dossier$R $dirTxt   $Dm session$R $(SessionName $p)")
    }

    # — pied —
    $L.Add('')
    if ($U.Searching) {
        $L.Add('   ' + ((Key 'tape' 'pour filtrer'), (Key '↑↓' 'choisir'), (Key 'Entrée' 'lancer'), (Key 'Échap' 'effacer') -join '   '))
    } else {
        $L.Add('   ' + ((Key '↑↓' 'choisir'), (Key 'Entrée' 'lancer'), (Key '/' 'chercher'), (Key 'J' 'projet'), (Key 'N' 'nouveau'), (Key 'P' 'partager'), (Key '?' $(if ($U.Help) { 'masquer l''aide' } else { 'toutes les touches' })), (Key 'Q' 'quitter') -join '   '))
    }
    if ($U.Msg) { $L.Add("   $($U.Msg)") }

    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append("$e[H")
    for ($i = 0; $i -lt $H - 1; $i++) {
        $line = if ($i -lt $L.Count) { $L[$i] } else { '' }
        [void]$sb.Append((Fit $line $W)).Append($R).Append("$e[K`n")
    }
    [Console]::Write($sb.ToString())
    # zones cliquables : chaque profil (ses 2 lignes) et les aides du bas
    Clear-Zones; Hint-Zones $L
    foreach ($pr in $profRows) { Add-Zone $pr.Y ($pr.Y + 1) 0 999 @{ Profile = $pr.Idx } }
}

function Show-Selector([string]$msg, [string]$selectId) {
    $U = @{
        Profiles = @(); View = @(); Sel = 0; Top = 0; Filter = ''; Searching = $false; Help = $false
        Msg = $msg; Armed = ''; Tick = 0; Open = @{}; Live = @{}; Sig = ''; Refresh = $true; Undo = $null
    }
    Reload-Profiles $U $selectId
    $deps = @{
        psmux    = [bool](Get-Command psmux -ErrorAction SilentlyContinue)
        claude   = [bool](Get-Command claude -ErrorAction SilentlyContinue)
        terminal = [bool](Get-Command wt.exe -ErrorAction SilentlyContinue)
    }
    $lastW = 0; $lastH = 0
    $redraw = { [Console]::Write("$e[?25l$e[2J") }
    & $redraw
    Enable-Mouse   # clics sur les profils et les aides (coupée avant d'entrer dans une session)

    # lancer le profil sélectionné : renvoie le profil, ou $null (avec message) si impossible
    $launch = {
        param($p)
        if (-not $p) { return $null }
        if (((Uses-Role $p 'claude') -or (Uses-Role $p 'team')) -and -not $deps.claude) {
            $U.Msg = "$Err✗ Claude Code est introuvable (commande « claude ») : installe-le avant de lancer ce profil$R"
            return $null
        }
        # la fenêtre Équipe travaille sur UN projet : sans projet choisi, elle s'ouvrirait sur le dossier qui les contient tous
        if ((Uses-Role $p 'team') -and -not $ProjectDir) {
            [void](Invoke-ProjectPick); & $redraw
            if (-not $ProjectDir) { $U.Msg = "$Warn le profil « $($p.name) » a besoin d'un projet : choisis-en un avec J$R"; return $null }
        }
        # profil partagé : dossier de travail de cette machine (demandé la 1re fois) + comptes adaptés
        $prep = Prepare-Launch $p
        if ($prep.Asked) { & $redraw }
        if (-not $prep.P) { $U.Msg = $prep.Msg; return $null }
        # plusieurs comptes : connecter ceux qui manquent avant de construire la session
        $gate = Invoke-AccountGate $prep.P
        if ($gate.Shown) { & $redraw; $U.Refresh = $true }
        if (-not $gate.Go) { $U.Msg = "$Dm lancement annulé$R"; return $null }
        $prep.P
    }
    $sharedOnly = "$Dm(profil partagé : D pour en faire ta copie modifiable, P pour republier)$R"
    Start-BackgroundSync

    while ($true) {
        if ($U.Refresh -or ($U.Tick % 25) -eq 0) {
            $U.Open = @{}; $U.Live = @{}
            foreach ($p in $U.Profiles) {
                $s = SessionName $p
                $U.Open[$p.Id] = Test-Session $s
                if ($U.Open[$p.Id]) { $U.Live[$p.Id] = Get-LiveInfo $s }
            }
            $U.Refresh = $false
        }
        if (($U.Tick % 15) -eq 7) {
            $sig = Get-ProfilesSig
            if ($sig -ne $U.Sig) { Reload-Profiles $U $null; if (-not $U.Msg) { $U.Msg = "$Info↻ profils mis à jour$R" } }
        }

        while ($act = Read-Action) {
            if ($act.Click) {
                # clic sur un profil : le choisir ; 2e clic ou double-clic : le lancer
                $pi = $act.Click.Profile
                if ($null -eq $pi) { continue }
                if ($pi -eq $U.Sel -or $act.Double) { $U.Sel = $pi; $k = Fake-Key 'Enter' }
                else { $U.Sel = $pi; $U.Msg = ''; continue }
            } else { $k = $act.K }
            $n = $U.View.Count
            $cur = if ($n) { $U.View[$U.Sel] } else { $null }
            $raw = "$($k.KeyChar)"
            $ch = $raw.ToLower()
            $shift = [bool]($k.Modifiers -band [ConsoleModifiers]::Shift)
            $digit = if ("$($k.Key)" -match '^(D|NumPad)([1-9])$' -and -not ($k.Modifiers -band [ConsoleModifiers]::Alt)) { [int]$Matches[2] } else { 0 }
            try {
                # — mode recherche : les lettres servent au filtre —
                if ($U.Searching) {
                    switch ($k.Key) {
                        'Escape'    { $U.Filter = ''; $U.Searching = $false; Update-View $U $null }
                        'Enter'     { $go = & $launch $cur; if ($go) { return $go } }
                        'UpArrow'   { if ($n) { $U.Sel = ($U.Sel - 1 + $n) % $n } }
                        'DownArrow' { if ($n) { $U.Sel = ($U.Sel + 1) % $n } }
                        'Backspace' {
                            if ($U.Filter.Length) { $U.Filter = $U.Filter.Substring(0, $U.Filter.Length - 1) } else { $U.Searching = $false }
                            Update-View $U $null
                        }
                        default {
                            if (-not [char]::IsControl($k.KeyChar)) { $U.Filter += $raw; Update-View $U $null; $U.Sel = 0 }
                        }
                    }
                    continue
                }

                $armedBefore = $U.Armed; $U.Armed = ''
                $isSh = [bool]($cur -and $cur.Shared)
                # réordonner : seulement entre profils locaux (les partagés restent groupés en bas)
                $canMove = { param($to) -not $U.Filter -and $n -and -not $isSh -and $to -ge 0 -and $to -lt $n -and -not $U.View[$to].Shared }
                if ($k.Key -eq 'UpArrow' -and $shift) {
                    if ($U.Filter) { $U.Msg = "$Dm(efface la recherche pour réordonner)$R" }
                    elseif ($isSh) { $U.Msg = $sharedOnly }
                    elseif (& $canMove ($U.Sel - 1)) { Move-ProfileOrder @($U.View | Where-Object { -not $_.Shared }) $U.Sel ($U.Sel - 1); Reload-Profiles $U $cur.Id; $U.Msg = '' }
                }
                elseif ($k.Key -eq 'DownArrow' -and $shift) {
                    if ($U.Filter) { $U.Msg = "$Dm(efface la recherche pour réordonner)$R" }
                    elseif ($isSh) { $U.Msg = $sharedOnly }
                    elseif (& $canMove ($U.Sel + 1)) { Move-ProfileOrder @($U.View | Where-Object { -not $_.Shared }) $U.Sel ($U.Sel + 1); Reload-Profiles $U $cur.Id; $U.Msg = '' }
                }
                elseif ($k.Key -eq 'UpArrow' -and $n) { $U.Sel = ($U.Sel - 1 + $n) % $n; $U.Msg = '' }
                elseif ($k.Key -eq 'DownArrow' -and $n) { $U.Sel = ($U.Sel + 1) % $n; $U.Msg = '' }
                elseif ($k.Key -eq 'PageUp' -and $n) { $U.Sel = [Math]::Max(0, $U.Sel - 5) }
                elseif ($k.Key -eq 'PageDown' -and $n) { $U.Sel = [Math]::Min($n - 1, $U.Sel + 5) }
                elseif ($k.Key -eq 'Home' -and $n) { $U.Sel = 0 }
                elseif ($k.Key -eq 'End' -and $n) { $U.Sel = $n - 1 }
                elseif ($k.Key -eq 'Enter' -and $n) { $go = & $launch $cur; if ($go) { return $go } }
                elseif ($digit) { if ($digit -le $n) { $go = & $launch $U.View[$digit - 1]; if ($go) { return $go } } }
                elseif ($k.Key -eq 'Escape') { if ($U.Filter) { $U.Filter = ''; Update-View $U $null } elseif ($U.Help) { $U.Help = $false } else { return $null } }
                elseif ($ch -eq 'q') { return $null }
                elseif ($raw -eq '/') { $U.Searching = $true; $U.Help = $false; $U.Msg = '' }
                elseif ($raw -eq '?') { $U.Help = -not $U.Help }
                elseif (($raw -eq '+' -or $k.Key -eq 'Add') -and $n) {
                    if (& $canMove ($U.Sel - 1)) { Move-ProfileOrder @($U.View | Where-Object { -not $_.Shared }) $U.Sel ($U.Sel - 1); Reload-Profiles $U $cur.Id }
                }
                elseif (($raw -eq '-' -or $k.Key -eq 'Subtract') -and $n) {
                    if (& $canMove ($U.Sel + 1)) { Move-ProfileOrder @($U.View | Where-Object { -not $_.Shared }) $U.Sel ($U.Sel + 1); Reload-Profiles $U $cur.Id }
                }
                elseif ($ch -eq 'r') {
                    $script:Sources = Get-Sources
                    $errs = Sync-AllSources -Quiet
                    Reload-Profiles $U $null
                    $U.Msg = if ($errs.Count) { "$Err✗ $($errs -join ' · ')$R" } else { "$Info↻ profils rechargés$(if (@($Sources | Where-Object { $_.Type -eq 'git' }).Count) { ' · bibliothèques synchronisées' })$R" }
                }
                elseif ($ch -eq 'p' -and $n) {
                    $res = Invoke-Publish $cur; & $redraw
                    Reload-Profiles $U $(if ($res.Id) { $res.Id } else { $cur.Id }); $U.Msg = $res.Msg
                }
                elseif ($ch -eq 'j') {
                    $m = Invoke-ProjectPick; & $redraw
                    Reload-Profiles $U $(if ($n) { $cur.Id } else { $null }); $U.Msg = $m
                }
                elseif ($ch -eq 'b') {
                    $res = Invoke-Sources; & $redraw
                    Reload-Profiles $U $null; $U.Msg = $res.Msg
                }
                elseif ($ch -eq 'o' -and $n) {
                    if (-not $isSh) { $U.Msg = "$Dm(O sert aux profils partagés ; pour les tiens, E pour éditer « cwd »)$R" }
                    else {
                        $d = Ask-SharedCwd $cur; & $redraw
                        Reload-Profiles $U $cur.Id
                        $U.Msg = if ($d) { "$Ok✓ dossier de « $($cur.name) » : $d$R" } else { '' }
                    }
                }
                elseif ($isSh -and (($ch -eq 'e') -or ($k.Key -eq 'F2'))) { $U.Msg = $sharedOnly }
                elseif ($ch -eq 'e' -and $n) {
                    Start-Process notepad.exe -ArgumentList "`"$($cur.File)`""
                    $U.Msg = "$Info✎ édition de $(Split-Path $cur.File -Leaf) — rechargé automatiquement à l'enregistrement$R"
                }
                elseif ($ch -eq 'n') {
                    $res = Invoke-NewProfile; & $redraw
                    Reload-Profiles $U $res.Id; $U.Msg = $res.Msg
                }
                elseif ($ch -eq 'd' -and $n) {
                    $res = if ($isSh) { Invoke-ImportShared $cur } else { Invoke-Duplicate $cur }
                    if ($res.Asked) { & $redraw }
                    Reload-Profiles $U $(if ($res.Id) { $res.Id } else { $cur.Id }); $U.Msg = $res.Msg
                }
                elseif ($k.Key -eq 'F2' -and $n) {
                    $res = Invoke-Rename $cur; & $redraw
                    Reload-Profiles $U $cur.Id; $U.Msg = $res.Msg
                }
                elseif ($k.Key -eq 'Delete' -and $n) {
                    if ($armedBefore -ne "del:$($cur.Id)") {
                        $U.Armed = "del:$($cur.Id)"
                        $U.Msg = if ($isSh) { "$Err⚠ appuie encore sur Suppr pour retirer « $($cur.name) » de $($cur.Shared) (pour tout le monde)$R" }
                                 else { "$Err⚠ appuie encore sur Suppr pour supprimer « $($cur.name) » (déplacé dans profiles\.corbeille)$R" }
                    } elseif ($isSh) {
                        $nb = if ($U.Sel + 1 -lt $n) { $U.View[$U.Sel + 1].Id } elseif ($U.Sel -gt 0) { $U.View[$U.Sel - 1].Id } else { $null }
                        $res = Remove-Shared $cur
                        if ($res.Undo) { $U.Undo = $res.Undo }
                        Reload-Profiles $U $nb; $U.Msg = $res.Msg
                    } else {
                        $nb = if ($U.Sel + 1 -lt $n) { $U.View[$U.Sel + 1].Id } elseif ($U.Sel -gt 0) { $U.View[$U.Sel - 1].Id } else { $null }
                        $dest = Remove-ProfileToTrash $cur
                        $U.Undo = @{ From = $dest; To = $cur.File; Id = $cur.Id; Name = $cur.name }
                        Reload-Profiles $U $nb
                        $U.Msg = "$Warn✗ « $($cur.name) » supprimé — $B U$R$Warn pour annuler$R"
                    }
                }
                elseif ($ch -eq 's') {
                    $res = Invoke-Capture; & $redraw
                    Reload-Profiles $U $res.Id; $U.Msg = $res.Msg
                }
                elseif ($ch -eq 'u') {
                    $un = $U.Undo
                    if (-not $un) { $U.Msg = "$Dm(rien à annuler)$R" }
                    elseif (Test-Path -LiteralPath $un.To) { $U.Msg = "$Err✗ impossible de restaurer : $(Split-Path $un.To -Leaf) existe déjà$R" }
                    else {
                        Move-Item -LiteralPath $un.From -Destination $un.To
                        $U.Undo = $null
                        Reload-Profiles $U $un.Id
                        $U.Msg = "$Ok↶ « $($un.Name) » restauré$R"
                    }
                }
                elseif ($ch -eq 'c') {
                    $res = Invoke-Accounts $U.Profiles; & $redraw
                    Reload-Profiles $U $null; $U.Msg = $res.Msg
                }
                elseif ($raw -ceq 'K') {
                    $openCount = @($U.Open.Values | Where-Object { $_ }).Count
                    if (-not $openCount) { $U.Msg = "$Dm(aucune session FLOW ouverte)$R" }
                    elseif ($armedBefore -ne 'killall') {
                        $U.Armed = 'killall'
                        $U.Msg = "$Err⚠ appuie encore sur Maj+K pour fermer les $openCount session(s) FLOW (Claude compris)$R"
                    } else {
                        & psmux -L $Sock kill-server *> $null
                        $U.Refresh = $true; $U.Msg = "$Warn✗ toutes les sessions FLOW sont fermées$R"
                    }
                }
                elseif ($ch -eq 'k' -and $n) {
                    $s = SessionName $cur
                    if (-not (Test-Session $s)) { $U.Msg = "$Dm(la session $s n'est pas ouverte)$R" }
                    elseif ($armedBefore -ne "kill:$s") { $U.Armed = "kill:$s"; $U.Msg = "$Err⚠ appuie encore sur K pour fermer « $s » (Claude compris)$R" }
                    else { & psmux -L $Sock kill-session -t $s *> $null; $U.Refresh = $true; $U.Msg = "$Warn✗ session $s fermée$R" }
                }
            } catch {
                & $redraw
                $U.Msg = "$Err✗ $($_.Exception.Message)$R"
            }
        }
        if ((ConW) -ne $lastW -or (ConH) -ne $lastH) { [Console]::Write("$e[2J"); $lastW = ConW; $lastH = ConH }
        Draw-Selector $U $deps
        $U.Tick++
        Start-Sleep -Milliseconds 70
    }
}

# ───────────────────────── main ─────────────────────────
if ($LoadOnly) { return }   # tests : les fonctions sont chargées, l'écran n'est pas lancé
if ($InstallShortcut) { "Raccourci : $(Install-Shortcut)"; return }

$Accounts = Get-Accounts
if ($Doctor) { Invoke-Doctor; return }
if ($InstallSkills) { "Skills FLOW installés dans $(Install-AllSkills) compte(s) : $((Get-ChildItem -LiteralPath (Join-Path $Root 'skills') -Directory).Name -join ', ')"; return }
if ($Login) {
    $a = $Accounts | Where-Object { $_.Id -eq $Login -or $_.Label -eq $Login } | Select-Object -First 1
    if (-not $a) { Write-Host "compte « $Login » introuvable dans $AcctFile (comptes : $(($Accounts.Id) -join ', '))" -ForegroundColor Red; return }
    Start-AccountLogin $a -Inline
    return
}

if (-not (Get-Command psmux -ErrorAction SilentlyContinue)) {
    Write-Host "psmux est introuvable. Installe-le avec :  winget install marlocarlo.psmux" -ForegroundColor Red
    Read-Host 'Entrée pour quitter' | Out-Null
    return
}

if ($Project) {
    try { Set-Project $Project } catch { Write-Host "$($_.Exception.Message) — FLOW démarre sans projet (J pour en choisir un)" -ForegroundColor Yellow; Start-Sleep 2 }
}

try {
    if ($Team) {
        # profil Équipe (profiles\equipe.json) appliqué à un autre dossier
        $dir = [IO.Path]::GetFullPath(([Environment]::ExpandEnvironmentVariables($Team.Trim('"')) -replace '^~', $HOME))
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "dossier introuvable : $dir" }
        $tpl = Get-Profiles | Where-Object { $_.Id -eq 'equipe' } | Select-Object -First 1
        $p = if ($tpl) { $tpl | ConvertTo-Json -Depth 20 | ConvertFrom-Json }
             else { '{"window":"dispatch","rows":[{"height":66,"panes":[{"role":"team","width":38,"focus":true},{"role":"claude","width":37},{"role":"monitor","width":25}]},{"height":34,"panes":[{"role":"office","width":100}]}]}' | ConvertFrom-Json }
        $slug = ((Split-Path $dir -Leaf).ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
        foreach ($kv in @(@('cwd', $dir), @('session', "flow-equipe-$slug"), @('name', "Équipe — $(Split-Path $dir -Leaf)"), @('Id', "equipe-$slug"), @('File', $null))) {
            $p | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1] -Force
        }
        if (-not $NoAttach -and -not (Invoke-AccountGate $p).Go) { return }
        $s = Start-FlowProfile $p
        if ($NoAttach) { "session prête : $s  (psmux -L $Sock attach -t $s)"; return }
        Enter-Flow $s
        return
    }
    if ($Open) {
        $Sources = Get-Sources
        $p = @(Get-Profiles) + @(Get-SharedProfiles) | Where-Object { $_.Id -eq $Open -or $_.name -eq $Open } | Select-Object -First 1
        if (-not $p) { throw "profil « $Open » introuvable dans $ProfDir ni dans les bibliothèques partagées" }
        $p = (Prepare-Launch $p).P
        if (-not $p) { return }
        if (-not $NoAttach -and -not (Invoke-AccountGate $p).Go) { return }
        $s = Start-FlowProfile $p
        Save-LastUsed $p.Id
        if ($NoAttach) { "session prête : $s  (psmux -L $Sock attach -t $s)"; return }
        Enter-Flow $s
        return
    }
    $msg = ''
    # projet choisi (FLOW.exe ou -Project) : on s'assure tout de suite que les comptes sont connectés, avant même le choix du profil
    if ($ProjectDir) { Enable-Mouse; [void](Invoke-AccountGate $null -ForProject); Offer-ClaudeMd; [Console]::Write("$R$e[2J$e[H") }
    $last = (Get-State).last
    while ($true) {
        $p = Show-Selector $msg $last
        if (-not $p) { break }
        $last = $p.Id
        Save-LastUsed $p.Id
        [Console]::Write("$R$e[2J$e[H")
        Write-Host "`n   $(Grad "◆ lancement de « $($p.name) »…" 0.1 0.03)`n"
        try {
            $s = Start-FlowProfile $p
            Enter-Flow $s
            $msg = "$Dm↩ détaché de $s (elle tourne toujours : Entrée pour y revenir)$R"
        } catch {
            $msg = "$Err✗ $($_.Exception.Message)$R"
        }
    }
} finally {
    Disable-Mouse
    [Console]::Write("$R$e[?25h")
}

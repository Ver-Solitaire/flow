<#
  claude-monitor.ps1 — tableau de bord animé d'une session Claude Code (panneau latéral psmux).
  Lit ~/.claude/projects/*/<session>.jsonl de façon incrémentale.

  Usage:
    pwsh -File claude-monitor.ps1                # suit la prochaine session créée après le lancement
    pwsh -File claude-monitor.ps1 -Latest        # suit la session la plus récemment écrite
    pwsh -File claude-monitor.ps1 -Latest -Cwd C:\mon\projet   # ne suit que les sessions lancées dans ce dossier
    pwsh -File claude-monitor.ps1 -ContextWindow 1000000       # force la taille (sinon détectée automatiquement)
    pwsh -File claude-monitor.ps1 -Refresh 0.2   # moins d'images/s si le terminal rame
    pwsh -File claude-monitor.ps1 -ClaudeDir D:\compte2   # autre compte Claude (sinon $env:CLAUDE_CONFIG_DIR ou ~/.claude)

  Plusieurs comptes dans un seul moniteur (utilisé par FLOW) :
    pwsh -File claude-monitor.ps1 -Latest -Watch 'Compte 1|ff8a5c||C:\proj|principal|C1;Compte 2|54baff|C:\Users\moi\.claude-compte2|C:\proj|second|C2'
    une entrée par compte, séparées par « ; » :
      libellé | couleur | dossier du compte (vide = ~/.claude) | dossier de travail | identifiant | nom court
    (dossier de travail vide = on n'affiche que les limites de ce compte)
    Avec -Sock / -Session (passés par FLOW), le moniteur écrit aussi l'état de chaque Claude dans la bordure
    de son panneau (panneaux marqués @flow_acct = identifiant) et les limites dans la barre d'état psmux.
    Touches : Tab = choisir le compte détaillé · A = choix automatique (le dernier actif)
#>
param(
    [int]$ContextWindow = 200000,
    [double]$Refresh = 0.12,
    [double]$IdleRefresh = 0.5,   # rafraîchissement quand Claude ne travaille pas (économise le CPU)
    [switch]$Latest,
    [string]$Cwd,                 # dossier de travail de Claude : limite le suivi à ce projet
    [string]$ClaudeDir = $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }),
    [string]$Watch,               # plusieurs comptes (voir ci-dessus) ; remplace -ClaudeDir / -Cwd
    [string]$Sock,                # serveur psmux (FLOW) : permet de mettre à jour bordures et barre d'état
    [string]$Session,             # session psmux FLOW du moniteur
    [int]$NotifyAfter = 20,       # notification Windows quand Claude finit un tour de plus de N s (-1 = jamais)
    [int]$Frames = 0          # >0 : s'arrête après N images (test)
)
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'flow-sprites.ps1')     # personnages animés (partagés avec le Bureau)
. (Join-Path $PSScriptRoot 'flow-input.ps1')       # clavier + souris (clics)
$MonFlash = ''; $MonFlashUntil = [datetime]::MinValue
$MascotX = -1; $MascotAccts = @()                  # position des personnages de l'en-tête (zones cliquables)
$e = [char]27
$C = @{ R="$e[0m"; Dim="$e[2m"; B="$e[1m"; Cy="$e[36m"; Gr="$e[32m"; Ye="$e[33m"; Re="$e[31m"; Ma="$e[35m"; Bl="$e[34m" }
$ansiRx = "$e\[[0-9;]*m"
$startTime = (Get-Date).AddSeconds(-3)
$launch = Get-Date
$spin = '⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏'
$spin2 = '◐','◓','◑','◒'
$tick = 0
$S = $null          # état de la session en cours de lecture / affichée
$Lim = $null        # limites du compte affiché
$Fr = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
$CtxForced = $PSBoundParameters.ContainsKey('ContextWindow')

# flux d'activité commun à tous les comptes
$Feed = [System.Collections.Generic.List[string]]::new()
$NewTick = 0
$CurA = $null       # compte en cours de lecture
$Pinned = -1        # compte choisi avec Tab (-1 = automatique)
$AnyBusy = $false; $AnyS = $false

# ───────────────────────── comptes suivis ─────────────────────────
function ProjKeyOf([string]$dir) {
    # dossier projet Claude : chaque caractère non alphanumérique du chemin devient « - »
    if ($dir) { ([IO.Path]::GetFullPath($dir).TrimEnd('\', '/')) -replace '[^a-zA-Z0-9]', '-' }
}
function HexRgb([string]$h) {
    $h = "$h".TrimStart('#')
    if ($h -notmatch '^[0-9a-fA-F]{6}$') { return @(255,138,92) }
    @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}
function New-Acct([string]$label, $rgb, [string]$dir, [string]$cwd, [bool]$track, [string]$id = '', [string]$short = '') {
    [pscustomobject]@{
        Label = $label; Rgb = $rgb; Dir = $dir; Root = (Join-Path $dir 'projects')
        ProjKey = (ProjKeyOf $cwd); Track = $track
        Id = $id; Short = $(if ($short) { $short } elseif ($label) { $label } else { 'Claude' })
        S = $null; Lim = $null; LimStamp = [datetime]::MinValue
        StatusFile = (Join-Path $dir 'monitor-status.json')   # écrit par tools/statusline.ps1
        LastAct = [datetime]::MinValue; Logged = $true
        Primed = $false; WasBusy = $false; Done = $false       # détection de fin de tour
        PaneSig = ''; Alerted = @{}                            # bordure psmux déjà à jour / alertes de limites déjà émises
    }
}
$Accts = [System.Collections.Generic.List[object]]::new()
if ($Watch) {
    foreach ($ent in ($Watch -split ';')) {
        if (-not $ent.Trim()) { continue }
        $f = $ent -split '\|', 6
        $dir = if ($f.Count -gt 2 -and $f[2].Trim()) { $f[2].Trim() } else { Join-Path $HOME '.claude' }
        $cw = if ($f.Count -gt 3) { $f[3].Trim() } else { '' }
        $id = if ($f.Count -gt 4) { $f[4].Trim() } else { '' }
        $sh = if ($f.Count -gt 5) { $f[5].Trim() } else { '' }
        $Accts.Add((New-Acct $f[0].Trim() (HexRgb $(if ($f.Count -gt 1) { $f[1] } else { '' })) $dir $cw ([bool]$cw) $id $sh))
    }
}
if (-not $Accts.Count) { $Accts.Add((New-Acct '' @(255,138,92) $ClaudeDir $Cwd $true)) }

# ───────────────────────── intégration psmux & notifications ─────────────────────────
$Psmux = $Sock -and $Session -and (Get-Command psmux -ErrorAction SilentlyContinue)
$PaneMap = @{}          # identifiant de compte → @( @{ T = cible ; Base = titre de base } )
$LastStatus = $null

function Q1([string]$s) { "'" + ($s -replace "'", "''") + "'" }

function Notify([string]$title, [string]$text) {
    # bulle de notification Windows, dans un processus caché pour ne pas bloquer l'affichage
    if ($NotifyAfter -lt 0) { return }
    $ico = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\assets\flow.ico'))
    $cmd = "Add-Type -AssemblyName System.Windows.Forms, System.Drawing; " +
        "`$n = [System.Windows.Forms.NotifyIcon]::new(); " +
        "`$n.Icon = if (Test-Path -LiteralPath $(Q1 $ico)) { [System.Drawing.Icon]::new($(Q1 $ico)) } else { [System.Drawing.SystemIcons]::Information }; " +
        "`$n.Text = 'FLOW'; `$n.Visible = `$true; " +
        "`$n.ShowBalloonTip(6000, $(Q1 $title), $(Q1 $text), [System.Windows.Forms.ToolTipIcon]::Info); " +
        "Start-Sleep -Seconds 8; `$n.Dispose()"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    try { Start-Process pwsh -WindowStyle Hidden -ArgumentList @('-NoProfile', '-EncodedCommand', $enc) } catch {}
}

function Refresh-PaneMap {
    # retrouve les panneaux Claude de la session grâce à l'option @flow_acct posée par FLOW
    if (-not $Psmux) { return }
    $m = @{}
    foreach ($l in (& psmux -L $Sock list-panes -t $Session -F '#{pane_index}|#{@flow_acct}|#{@flow_base}' 2>$null)) {
        $f = "$l" -split '\|', 3
        if ($f.Count -lt 3 -or -not $f[1]) { continue }
        if (-not $m.ContainsKey($f[1])) { $m[$f[1]] = @() }
        $m[$f[1]] += @{ T = "${Session}:.$($f[0])"; Base = $f[2] }
    }
    $script:PaneMap = $m
}

function Acct-State($a) {
    if (-not $a.Logged) { return 'off' }
    if (-not $a.S) { return 'none' }
    if ($a.S.Busy) { return 'busy' }
    if ($a.Done) { return 'done' }
    'idle'
}

function Sync-Panes {
    # bordure de chaque panneau Claude : « ✦ claude · Compte 2 · ● travaille · ctx 45% » (mise à jour seulement si ça change)
    if (-not $Psmux) { return }
    foreach ($a in $Accts) {
        if (-not $a.Id -or -not $PaneMap.ContainsKey($a.Id)) { continue }
        $st = Acct-State $a
        $ctx = if ($a.S) { [int][Math]::Round($a.S.Ctx / (CtxSize $a) * 100) } else { -1 }
        $sig = "$st|$ctx"
        if ($sig -eq $a.PaneSig) { continue }
        $a.PaneSig = $sig
        $txt = switch ($st) { 'busy' { '● travaille' } 'done' { '✓ à toi' } 'idle' { '○ en attente' } 'off' { '○ non connecté' } 'none' { '○ prêt (aucun message)' } default { '' } }
        foreach ($pn in $PaneMap[$a.Id]) {
            $title = $pn.Base
            if ($txt) { $title += " · $txt" }
            if ($ctx -ge 0) { $title += " · ctx $ctx%" }
            & psmux -L $Sock set -p -t $pn.T '@flow_role' $title *> $null
            & psmux -L $Sock set -p -t $pn.T '@flow_state' $st *> $null
            & psmux -L $Sock set -p -t $pn.T '@flow_ctx' "$ctx" *> $null
        }
    }
}

function Sync-Status {
    # barre d'état psmux : « C1 sem 97% 5h 40% │ C2 sem 12% 5h 5% »
    if (-not $Psmux) { return }
    $parts = foreach ($a in $Accts) {
        if (-not $a.Logged) { "$($a.Short) ○"; continue }
        $rl = $a.Lim.rate_limits
        if (-not $rl) { "$($a.Short) —"; continue }
        $w = if ($rl.seven_day) { [int]$rl.seven_day.used_percentage } else { $null }
        $h = if ($rl.five_hour) { [int]$rl.five_hour.used_percentage } else { $null }
        $warn = if ($w -ge 90 -or $h -ge 90) { '⚠ ' } else { '' }
        "$warn$($a.Short) sem $(if ($null -ne $w) { "$w%" } else { '—' }) 5h $(if ($null -ne $h) { "$h%" } else { '—' })"
    }
    $txt = @($parts) -join ' │ '
    if ($txt -eq $script:LastStatus) { return }
    $script:LastStatus = $txt
    & psmux -L $Sock set -t $Session '@flow_status' $txt *> $null
}

function Check-TurnEnd($a) {
    # appelé après chaque lecture : repère la fin d'un tour de Claude (travaille → en attente)
    if (-not $a.S) { return }
    if (-not $a.Primed) { $a.Primed = $true; $a.WasBusy = $a.S.Busy; return }   # rattrapage de l'historique : pas d'alerte
    if ($a.S.Busy) { $a.Done = $false }
    elseif ($a.WasBusy) {
        $a.Done = $true
        $dur = ((Get-Date) - $a.S.BusySince).TotalSeconds
        if ($NotifyAfter -ge 0 -and $dur -ge $NotifyAfter) {
            $who = if ($a.Label) { $a.Label } else { 'Claude' }
            $what = if ($a.S.Title) { $a.S.Title } else { 'tour terminé' }
            Notify "✓ $who a terminé" "$what — $([int]$dur) s"
        }
    }
    $a.WasBusy = $a.S.Busy
}

function Limit-Worst($a) {
    # renvoie @{ Key; Name; Pct } de la limite la plus remplie du compte
    $rl = $a.Lim.rate_limits
    if (-not $rl) { return $null }
    $c = @()
    if ($rl.seven_day) { $c += @{ Key = '7d'; Name = 'semaine'; Pct = [double]$rl.seven_day.used_percentage; Reset = [double]$rl.seven_day.resets_at } }
    if ($rl.five_hour) { $c += @{ Key = '5h'; Name = 'session'; Pct = [double]$rl.five_hour.used_percentage; Reset = [double]$rl.five_hour.resets_at } }
    $c | Sort-Object { $_.Pct } -Descending | Select-Object -First 1
}

function Best-Other($a) {
    # autre compte connecté dont les deux limites sont sous 80 %
    $best = $null; $bp = 999
    foreach ($o in $Accts) {
        if ($o -eq $a -or -not $o.Logged) { continue }
        $w = Limit-Worst $o
        if (-not $w -or $w.Pct -ge 80) { continue }
        if ($w.Pct -lt $bp) { $best = $o; $bp = $w.Pct }
    }
    if ($best) { @{ A = $best; Pct = $bp } }
}

function Check-LimitAlerts($a) {
    # notification une seule fois quand une limite passe 90 % (réarmée sous 80 %) ; pas au démarrage
    foreach ($k in @(@('7d', 'seven_day', 'semaine'), @('5h', 'five_hour', 'session'))) {
        $win = $a.Lim.rate_limits.($k[1])
        if (-not $win) { continue }
        $p = [double]$win.used_percentage
        $prev = $a.Alerted[$k[0]]
        if ($p -ge 90 -and -not $prev) {
            $a.Alerted[$k[0]] = $true
            if ($null -ne $prev) {
                $alt = Best-Other $a
                $tip = if ($alt) { "Passe sur $($alt.A.Label) ($([int]$alt.Pct) %)." } else { 'Aucun autre compte disponible sous 80 %.' }
                Notify "⚠ $($a.Label) : $($k[2]) à $([int]$p) %" $tip
            }
        } elseif ($p -lt 80) { $a.Alerted[$k[0]] = $false }
        elseif ($null -eq $prev) { $a.Alerted[$k[0]] = $false }
    }
}
$Multi = $Accts.Count -gt 1

# ───────────────────────── couleurs ─────────────────────────
$Pal = @(@(255,138,92), @(255,94,158), @(168,112,255), @(84,186,255), @(96,232,196))
$BorderRgb = @(70,74,96)

function Rgb([int]$r, [int]$g, [int]$b) { "$e[38;2;$r;$g;$($b)m" }
function Mix($a, $b, [double]$f) {
    $f = [Math]::Max(0.0, [Math]::Min(1.0, $f))
    @([int]($a[0] + ($b[0] - $a[0]) * $f), [int]($a[1] + ($b[1] - $a[1]) * $f), [int]($a[2] + ($b[2] - $a[2]) * $f))
}
function RgbA($c) { Rgb $c[0] $c[1] $c[2] }
function PalAt([double]$t) {
    $t -= [Math]::Floor($t)
    $x = $t * $Pal.Count
    $i = [int][Math]::Floor($x) % $Pal.Count
    Mix $Pal[$i] $Pal[($i + 1) % $Pal.Count] ($x - [Math]::Floor($x))
}
function PalC([double]$t) { RgbA (PalAt $t) }
function Grad([string]$s, [double]$phase, [double]$spread = 0.035) {
    $sb = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt $s.Length; $i++) {
        $ch = $s[$i]
        if ($ch -eq ' ') { [void]$sb.Append(' '); continue }
        [void]$sb.Append((PalC ($phase + $i * $spread))).Append($ch)
    }
    [void]$sb.Append($C.R); $sb.ToString()
}
function Heat([double]$f) {
    if ($f -lt 0.6) { Mix @(80,220,130) @(245,200,80) ($f / 0.6) } else { Mix @(245,200,80) @(255,85,85) (($f - 0.6) / 0.4) }
}

# ───────────────────────── état ─────────────────────────
function New-State($file) {
    [pscustomobject]@{
        File = $file; Pos = [long]0; Model = '-'; Title = ''; Prompt = ''
        Ctx = 0; In = 0; CacheR = 0; CacheW = 0; OutById = @{}
        Tools = 0; ToolCounts = @{}; Pending = [ordered]@{}; Agents = [ordered]@{}
        CtxHist = [System.Collections.Generic.List[int]]::new()
        Busy = $false; BusySince = Get-Date; Turns = 0; Errors = 0
        Act = 'idle'; ActDetail = ''      # activité en cours (personnage animé)
    }
}

function Fmt([double]$n) {
    if ($n -ge 1e6) { '{0:N2}M' -f ($n / 1e6) } elseif ($n -ge 1e3) { '{0:N1}k' -f ($n / 1e3) } else { "$([int]$n)" }
}

function Summ($name, $inp) {
    foreach ($k in 'description', 'file_path', 'pattern', 'command', 'url', 'query', 'prompt', 'skill') {
        if ($inp.$k) { return [string]$inp.$k }
    }
    ''
}

function ToolName($n) {
    if ($n -match '^mcp__(.+?)__(.+)$') { return "$($Matches[1] -replace '^claude_ai_', '')·$($Matches[2])" }
    $n
}

function ToolIcon($n) {
    switch -regex ($n) {
        '^(Read|NotebookRead)$'                 { return "$(Rgb 120 190 255)◫" }
        '^(Edit|Write|NotebookEdit|MultiEdit)$' { return "$(Rgb 255 200 90)✎" }
        '^(Grep|Glob)$'                         { return "$(Rgb 120 230 200)⌕" }
        '^(Bash|PowerShell)$'                   { return "$(Rgb 180 255 120)»" }
        '^Web'                                  { return "$(Rgb 120 160 255)◍" }
        '^Skill$'                               { return "$(Rgb 255 150 220)✦" }
        '^mcp__'                                { return "$(Rgb 200 160 255)⬡" }
    }
    "$(Rgb 100 220 255)▶"
}

function Add-Feed($line) {
    # plusieurs comptes : chaque entrée commence par une barre à la couleur du compte
    if ($Multi -and $CurA) { $line = "$(RgbA $CurA.Rgb)┃$($C.R)$line" }
    $Feed.Add($line)
    $script:NewTick = $script:tick
    if ($Feed.Count -gt 300) { $Feed.RemoveRange(0, $Feed.Count - 300) }
}

function TsDate($o) { try { ([datetime]$o.timestamp).ToLocalTime() } catch { Get-Date } }
function Ts($o) { "$(Rgb 95 98 120)$((TsDate $o).ToString('HH:mm:ss'))$($C.R)" }

function Set-Busy($o) {
    if (-not $S.Busy) { $S.BusySince = TsDate $o }
    $S.Busy = $true
}

function Process-Line($line) {
    $o = $line | ConvertFrom-Json -Depth 64
    if (-not $o) { return }
    if ($CurA -and $o.type -in 'assistant', 'user' -and $o.timestamp) {
        $t0 = TsDate $o
        if ($t0 -gt $CurA.LastAct) { $CurA.LastAct = $t0 }
    }
    switch ($o.type) {
        'ai-title' { if ($o.aiTitle) { $S.Title = $o.aiTitle } }
        'assistant' {
            if ($o.isSidechain) { return }
            $m = $o.message
            if ($m.model -and $m.model -ne '<synthetic>') { $S.Model = $m.model }
            $u = $m.usage
            if ($u) {
                $S.In = [int]$u.input_tokens
                $S.CacheR = [int]$u.cache_read_input_tokens
                $S.CacheW = [int]$u.cache_creation_input_tokens
                $S.Ctx = $S.In + $S.CacheR + $S.CacheW + [int]$u.output_tokens
                $S.OutById[$m.id] = [int]$u.output_tokens
                $S.CtxHist.Add($S.Ctx)
                if ($S.CtxHist.Count -gt 300) { $S.CtxHist.RemoveAt(0) }
            }
            $t = Ts $o
            foreach ($it in $m.content) {
                if ($it.type -eq 'tool_use') {
                    $S.Tools++
                    $S.ToolCounts[$it.name] = 1 + [int]$S.ToolCounts[$it.name]
                    $S.Pending[$it.id] = $it.name
                    $S.Act = Act-OfTool $it.name; $S.ActDetail = Tool-Detail $it.name $it.input
                    if ($it.name -in 'Agent', 'Task') {
                        $type = if ($it.input.subagent_type) { $it.input.subagent_type } else { 'general' }
                        $S.Agents[$it.id] = [pscustomobject]@{ Type = $type; Desc = $it.input.description; Status = 'run'; Start = Get-Date }
                        Add-Feed "$t $(Rgb 200 140 255)◆ Agent$($C.R) $(Rgb 150 110 220)[$type]$($C.R) $(Summ $it.name $it.input)"
                    } else {
                        Add-Feed "$t $(ToolIcon $it.name) $(ToolName $it.name)$($C.R) $($C.Dim)$(Summ $it.name $it.input)$($C.R)"
                    }
                } elseif ($it.type -eq 'text' -and $it.text.Trim()) {
                    Add-Feed "$t $(Rgb 120 230 140)✎$($C.R) $($it.text)"
                } elseif ($it.type -eq 'thinking') {
                    $S.Act = 'think'; $S.ActDetail = ''
                    Add-Feed "$t $(Rgb 150 130 200)∴ réflexion…$($C.R)"
                }
            }
            if ($m.stop_reason -eq 'end_turn') { $S.Busy = $false; $S.Act = 'wait'; $S.ActDetail = '' } else { Set-Busy $o }
        }
        'user' {
            if ($o.isSidechain) { return }
            $content = $o.message.content
            if ($content -is [string]) {
                if ($content -notmatch '^\s*<') {
                    $S.Prompt = $content; Set-Busy $o; $S.Turns++; $S.Act = 'think'; $S.ActDetail = ''
                    Add-Feed "$(Ts $o) $($C.B)$(Rgb 255 210 110)❯ $content$($C.R)"
                }
            } else {
                foreach ($it in $content) {
                    if ($it.type -eq 'tool_result') {
                        $name = $S.Pending[$it.tool_use_id]
                        $S.Pending.Remove($it.tool_use_id)
                        $S.Act = if ($it.is_error) { 'error' } else { 'think' }; $S.ActDetail = ''
                        if ($S.Agents.Contains($it.tool_use_id)) {
                            $S.Agents[$it.tool_use_id].Status = if ($it.is_error) { 'err' } else { 'ok' }
                        }
                        if ($it.is_error) {
                            $S.Errors++
                            Add-Feed "$(Ts $o) $(Rgb 255 90 90)✗ $(ToolName $name) échec$($C.R)"
                        }
                    } elseif ($it.type -eq 'text' -and $it.text -notmatch '^\s*<') {
                        $S.Prompt = $it.text; Set-Busy $o; $S.Turns++; $S.Act = 'think'; $S.ActDetail = ''
                        Add-Feed "$(Ts $o) $($C.B)$(Rgb 255 210 110)❯ $($it.text)$($C.R)"
                    }
                }
            }
        }
    }
}

function Read-New {
    $fs = [IO.File]::Open($S.File, 'Open', 'Read', 'ReadWrite')
    try {
        $len = $fs.Length - $S.Pos
        if ($len -le 0) { return }
        $buf = New-Object byte[] $len
        [void]$fs.Seek($S.Pos, 'Begin')
        $read = $fs.Read($buf, 0, $len)
        $last = [Array]::LastIndexOf($buf, [byte]10, $read - 1)
        if ($last -lt 0) { return }
        $text = [Text.Encoding]::UTF8.GetString($buf, 0, $last + 1)
        $S.Pos += $last + 1
        # une ligne illisible (écriture en cours, fichier abîmé) est ignorée sans arrêter le moniteur
        foreach ($l in $text -split "`n") { if ($l.Trim()) { try { Process-Line $l } catch {} } }
    } finally { $fs.Dispose() }
}

function Find-Session($a) {
    $key = $a.ProjKey; $root = $a.Root
    if ($key) {
        # noms très longs : Claude tronque puis ajoute un suffixe → comparaison sur le début
        $pre = $key.Substring(0, [Math]::Min(200, $key.Length))
        $dirs = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object {
                $_.Name -eq $key -or ($key.Length -gt 200 -and $_.Name.StartsWith($pre, 'OrdinalIgnoreCase')) })
        $files = @(foreach ($d in $dirs) { Get-ChildItem -LiteralPath $d.FullName -Filter *.jsonl -File })
    } else {
        $files = Get-ChildItem (Join-Path $root '*\*.jsonl') -File
    }
    if (-not $Latest) { $files = $files | Where-Object { $_.CreationTime -ge $startTime } }
    ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

# ───────────────────────── widgets ─────────────────────────
# largeur d'affichage : emojis / CJK = 2 colonnes, accents combinants = 0
$WideRx = [regex]'[ᄀ-ᅟ⌚⌛⏩-⏬⏰⏳◽◾☔☕♈-♓♿⚓⚡⚪⚫⚽⚾⛄⛅⛎⛔⛪⛲⛳⛵⛺⛽✅✊✋✨❌❎❓-❕❗➕-➗➰➿⬛⬜⭐⭕⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]'
$ZeroRx = [regex]'[̀-ͯ​-‍︀-️]'
$SpecRx = [regex]"$WideRx|$ZeroRx|[\uD800-\uDFFF]"
$WrapCache = [hashtable]::new([StringComparer]::Ordinal)

function CharW([string]$s, [int]$i) {
    $c = $s[$i]
    if ([char]::IsLowSurrogate($c)) { return 0 }
    if ([char]::IsHighSurrogate($c)) { return 2 }
    $t = [string]$c
    if ($ZeroRx.IsMatch($t)) { return 0 }
    if ($WideRx.IsMatch($t)) { return 2 }
    1
}

function DispW([string]$plain) {
    if (-not $SpecRx.IsMatch($plain)) { return $plain.Length }
    $n = 0
    for ($i = 0; $i -lt $plain.Length; $i++) { $n += CharW $plain $i }
    $n
}

function VisLen($s) { DispW ($s -replace $ansiRx, '') }

function Fit([string]$s, [int]$w, [switch]$Cut) {
    # tronque selon la largeur visible en gardant les codes ANSI ; complète avec des espaces
    $vw = VisLen $s
    if ($vw -le $w) { return $s + (' ' * ($w - $vw)) }
    $sb = [Text.StringBuilder]::new()
    $lim = if ($Cut) { $w } else { $w - 1 }
    $vis = 0; $i = 0
    while ($i -lt $s.Length) {
        if ($s[$i] -eq $e) { $j = $s.IndexOf('m', $i); [void]$sb.Append($s.Substring($i, $j - $i + 1)); $i = $j + 1; continue }
        $cw = CharW $s $i
        if ($vis + $cw -gt $lim) { break }
        [void]$sb.Append($s[$i]); $vis += $cw; $i++
    }
    if (-not $Cut) { [void]$sb.Append('…'); $vis++ }
    [void]$sb.Append($C.R).Append(' ' * [Math]::Max(0, $w - $vis)); $sb.ToString()
}

function Wrap([string]$s, [int]$w, [int]$indent = 0) {
    # coupe en plusieurs lignes de largeur <= $w (de préférence sur un espace),
    # en conservant la couleur active ; les lignes suivantes sont indentées de $indent
    $out = [System.Collections.Generic.List[string]]::new()
    $sb = [Text.StringBuilder]::new()
    $vis = 0; $style = ''
    $sp = -1; $spVis = 0; $spStyle = ''
    $i = 0
    while ($i -lt $s.Length) {
        $ch = $s[$i]
        if ($ch -eq $e) {
            $j = $s.IndexOf('m', $i); $code = $s.Substring($i, $j - $i + 1)
            if ($code -eq "$e[0m") { $style = '' } else { $style += $code }
            [void]$sb.Append($code); $i = $j + 1; continue
        }
        $cw = CharW $s $i
        if ($vis + $cw -gt $w) {
            if ($sp -ge 0 -and $spVis -gt [Math]::Max($indent, $w / 3)) {
                $str = $sb.ToString()
                $out.Add($str.Substring(0, $sp) + $C.R)
                $rest = $str.Substring($sp + 1)
                $sb = [Text.StringBuilder]::new()
                [void]$sb.Append(' ' * $indent).Append($spStyle).Append($rest)
                $vis = $indent + (VisLen $rest)
                $sp = -1
            } else {
                $out.Add($sb.ToString() + $C.R)
                $sb = [Text.StringBuilder]::new()
                [void]$sb.Append(' ' * $indent).Append($style)
                $vis = $indent
                $sp = -1
                if ($ch -eq ' ') { $i++; continue }   # pas d'espace en début de ligne
            }
        }
        if ($ch -eq ' ') { $sp = $sb.Length; $spVis = $vis; $spStyle = $style }
        [void]$sb.Append($ch); $vis += $cw; $i++
    }
    $out.Add($sb.ToString() + $C.R)
    $out.ToArray()
}

function WrapC([string]$s, [int]$w, [int]$indent = 0) {
    if ((VisLen $s) -le $w) { return $s }
    $k = "$w|$indent|$s"
    $v = $WrapCache[$k]
    if ($null -eq $v) {
        if ($WrapCache.Count -gt 1500) { $WrapCache.Clear() }
        $v = @(Wrap $s $w $indent); $WrapCache[$k] = $v
    }
    $v
}

function Bar([double]$pct, [int]$w, [bool]$busy) {
    $parts = ' ▏▎▍▌▋▊▉█'
    $exact = [Math]::Min(1.0, [Math]::Max(0.0, $pct)) * $w
    $full = [int][Math]::Floor($exact)
    $rem = [int][Math]::Round(($exact - $full) * 8)
    $band = if ($busy) { ($tick * 0.9) % ($full + 12) - 4 } else { -100 }
    $sb = [Text.StringBuilder]::new()
    for ($k = 0; $k -lt $full; $k++) {
        $col = Heat ($k / [Math]::Max(1, $w - 1))
        $d = [Math]::Abs($k - $band)
        if ($d -lt 3) { $col = Mix $col @(255,255,255) (0.65 * (1 - $d / 3)) }
        [void]$sb.Append((RgbA $col)).Append('█')
    }
    $empty = $w - $full
    if ($full -lt $w -and $rem -gt 0) {
        [void]$sb.Append((RgbA (Heat ($full / [Math]::Max(1, $w - 1))))).Append($parts[$rem]); $empty--
    }
    [void]$sb.Append((Rgb 55 58 75)).Append('░' * [Math]::Max(0, $empty)).Append($C.R)
    $sb.ToString()
}

function Spark($vals, [int]$w, [double]$max) {
    $ch = '▁▂▃▄▅▆▇█'
    $v = @($vals | Select-Object -Last $w)
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append((Rgb 55 58 75)).Append('·' * ($w - $v.Count))
    foreach ($x in $v) {
        $f = [Math]::Min(1.0, $x / $max)
        [void]$sb.Append((RgbA (Heat $f))).Append($ch[[int][Math]::Round($f * 7)])
    }
    [void]$sb.Append($C.R); $sb.ToString()
}

function Wave([int]$w) {
    $sb = [Text.StringBuilder]::new()
    if ($AnyBusy) {
        # égaliseur ondulant
        $ch = '▁▂▃▄▅▆▇█'
        for ($x = 0; $x -lt $w; $x++) {
            $v = ([Math]::Sin($x * 0.28 + $tick * 0.45) + 0.8 * [Math]::Sin($x * 0.11 - $tick * 0.27)) / 1.8
            $lvl = [int][Math]::Round(($v + 1) / 2 * 7)
            [void]$sb.Append((PalC ($x / $w * 0.5 + $tick * 0.015))).Append($ch[$lvl])
        }
    } elseif (-not $AnyS) {
        # scanner aller-retour
        $period = [Math]::Max(2, 2 * ($w - 1))
        $p = ($tick * 1.3) % $period
        $pos = if ($p -lt $w) { $p } else { $period - $p }
        for ($x = 0; $x -lt $w; $x++) {
            $d = [Math]::Abs($x - $pos)
            if ($d -lt 7) { [void]$sb.Append((RgbA (Mix @(255,138,92) @(50,52,68) ($d / 7)))).Append('━') }
            else { [void]$sb.Append((Rgb 50 52 68)).Append('─') }
        }
    } else {
        # respiration calme
        $g = [int](55 + 35 * (1 + [Math]::Sin($tick * 0.12)) / 2)
        [void]$sb.Append((Rgb $g $g ([int]($g * 1.3)))).Append('─' * $w)
    }
    [void]$sb.Append($C.R); $sb.ToString()
}

$Logo = @{
    C = '█▀▀', '█  ', '▀▀▀'
    L = '█  ', '█  ', '▀▀▀'
    A = '▄▀█', '█▀█', '▀ ▀'
    U = '█ █', '█ █', '▀▀▀'
    D = '█▀▄', '█ █', '▀▀ '
    E = '█▀▀', '█▀▀', '▀▀▀'
}
$LogoRows = foreach ($r in 0..2) { (('C', 'L', 'A', 'U', 'D', 'E') | ForEach-Object { $Logo[$_][$r] }) -join ' ' }

function Acct-Act($a) {
    # ce que fait le Claude de ce compte, pour son personnage (voir tools\flow-sprites.ps1)
    if (-not $a.S) { return 'look' }
    if (-not $a.Logged) { return 'idle' }
    if ($a.S.Busy) { if ($a.S.Act -in 'wait', 'idle', '') { return 'think' }; return $a.S.Act }
    # tour fini récemment : Claude attend une réponse (comme dans le Bureau)
    if ($a.Done -or ($a.S.Act -eq 'wait' -and ((Get-Date) - $a.LastAct).TotalMinutes -lt 30)) { return 'wait' }
    'idle'
}

function Act-Text($a) {
    # « lit facture.ts », « exécute npm test »… (vide quand Claude ne travaille pas)
    if (-not $a.S -or -not $a.S.Busy) { return '' }
    $act = Acct-Act $a
    $det = if ($a.S.ActDetail -and $act -notin 'think') { " $($C.Dim)$($a.S.ActDetail)$($C.R)" } else { '' }
    " $($C.Dim)·$($C.R) $(SpRgb $SpActs[$act].Rgb)$(Sprite-Label $act)$($C.R)$det"
}

function Mascot([int]$maxW) {
    # un personnage animé par Claude suivi : il lit, écrit, cherche, exécute… selon son outil en cours
    $list = @($Accts | Where-Object { $_.Track })
    if (-not $list.Count) { $list = @($Accts[0]) }
    $list = @($list | Select-Object -First ([Math]::Max(1, [int][Math]::Floor(($maxW + 2) / 11))))
    $script:MascotAccts = $list
    $rows = @('', '', '')
    $k = 0
    foreach ($a in $list) {
        $sp = Sprite (Acct-Act $a) $tick $a.Rgb $k
        for ($i = 0; $i -lt 3; $i++) { $rows[$i] += $(if ($k) { '  ' } else { '' }) + $sp[$i] }
        $k++
    }
    $rows
}

function Add-Header($L, [int]$W) {
    $ph = $tick * 0.012
    $script:MascotX = -1
    if ($W - 27 -ge 9) {
        $m = Mascot ($W - 27)
        $script:MascotX = 1 + (VisLen $LogoRows[0]) + 3
        for ($r = 0; $r -lt 3; $r++) {
            $L.Add(' ' + (Grad $LogoRows[$r] ($ph + $r * 0.04) 0.018) + '   ' + $m[$r])
        }
    } elseif ($W -ge 12) {
        # panneau étroit : les personnages passent avant le logo
        $script:MascotX = 1
        foreach ($row in (Mascot ($W - 2))) { $L.Add(' ' + $row) }
    } else {
        $L.Add(' ' + (Grad 'CLAUDE' $ph 0.05))
    }
    $up = ((Get-Date) - $launch).ToString('hh\:mm\:ss')
    $dim = Rgb 95 98 120
    $L.Add(" $(Grad '░▒▓' ($ph + 0.2) 0.05) $($C.B)$(Grad 'M O N I T O R' ($ph + 0.3) 0.02) $(Grad '▓▒░' ($ph + 0.5) 0.05)  $dim$(Get-Date -Format 'HH:mm:ss') · up $up$($C.R)")
    $L.Add(' ' + (Wave ($W - 2)))
    if ($MonFlash -and (Get-Date) -lt $MonFlashUntil) { $L.Add(" $MonFlash") }
}

# ───────────────────────── souris : changer de modèle, choisir le compte détaillé ─────────────────────────
function Set-MonFlash([string]$s) { $script:MonFlash = $s; $script:MonFlashUntil = (Get-Date).AddSeconds(6) }

function Change-Model($a) {
    # clic sur le modèle d'un compte : modèle suivant (opus → sonnet → haiku → opus), envoyé à son Claude
    $cur = if ($a.PendingModel) { [string]$a.PendingModel } else { [string]$a.S.Model }
    $fam = if ($cur -match 'opus') { 'opus' } elseif ($cur -match 'sonnet') { 'sonnet' } elseif ($cur -match 'haiku') { 'haiku' } else { 'opus' }
    $order = 'opus', 'sonnet', 'haiku'
    $next = $order[([array]::IndexOf($order, $fam) + 1) % $order.Count]
    if (-not $Psmux -or -not $a.Id -or -not $PaneMap.ContainsKey($a.Id)) {
        Set-MonFlash "$(Rgb 255 110 90)✗ aucun panneau Claude trouvé pour $($a.Label) : tape « /model $next » dans son panneau$($C.R)"
        return
    }
    foreach ($pn in $PaneMap[$a.Id]) {
        & psmux -L $Sock send-keys -t $pn.T -l "/model $next" *> $null
        & psmux -L $Sock send-keys -t $pn.T Enter *> $null
    }
    $a | Add-Member -NotePropertyName PendingModel -NotePropertyValue $next -Force
    Set-MonFlash "$(Rgb 120 230 140)✓ /model $next envoyé à $($a.Label)$($C.R) $($C.Dim)(pris en compte par Claude ; reclique pour le suivant)$($C.R)"
}

function Monitor-Zones($L) {
    # zones cliquables de l'image : personnages de l'en-tête, blocs des comptes, modèle de chaque compte
    Clear-Zones
    if ($MascotX -ge 0) {
        for ($k = 0; $k -lt $MascotAccts.Count; $k++) {
            $x1 = $MascotX + $k * 11
            Add-Zone 0 2 $x1 ($x1 + 8) @{ Acct = $MascotAccts[$k]; What = 'focus' }
        }
    }
    $plain = @($L | ForEach-Object { ([string]$_) -replace $ansiRx, '' })
    if ($Multi) {
        # panneau COMPTES : chaque compte commence par « ┃ Libellé »
        $starts = @()
        foreach ($a in $Accts) {
            for ($y = 0; $y -lt $plain.Count; $y++) { if ($plain[$y] -match "┃ $([regex]::Escape($a.Label))( |$)") { $starts += @{ A = $a; Y = $y }; break } }
        }
        $starts = @($starts | Sort-Object { $_.Y })
        for ($q = 0; $q -lt $starts.Count; $q++) {
            $y1 = $starts[$q].Y
            $y2 = if ($q + 1 -lt $starts.Count) { $starts[$q + 1].Y - 1 } else { $y1 + 3 }
            Add-Zone $y1 $y2 0 999 @{ Acct = $starts[$q].A; What = 'focus' }
            $a = $starts[$q].A
            if ($a.S -and $a.S.Model) {
                $mt = "$($a.S.Model)" -replace '^claude-', ''
                foreach ($yy in $y1, ($y1 + 1)) {
                    if ($yy -ge $plain.Count) { continue }
                    $ix = $plain[$yy].IndexOf($mt)
                    if ($ix -ge 0) { Add-Zone $yy $yy $ix ($ix + $mt.Length - 1) @{ Acct = $a; What = 'model' }; break }
                }
            }
        }
    } elseif ($Accts[0].S -and $Accts[0].S.Model) {
        # un seul compte : « modèle claude-… » dans le panneau SESSION
        for ($y = 0; $y -lt $plain.Count; $y++) {
            $ix = $plain[$y].IndexOf("modèle $($Accts[0].S.Model)")
            if ($ix -ge 0) { Add-Zone $y $y ($ix + 7) ($ix + 6 + "$($Accts[0].S.Model)".Length) @{ Acct = $Accts[0]; What = 'model' }; break }
        }
    }
}

function Panel($L, [string]$title, $lines, [int]$W, [switch]$Comet) {
    $bc = RgbA $BorderRgb
    $inner = $W - 4
    $fill = [Math]::Max(0, $W - 5 - (VisLen $title))
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append("$bc╭─ $($C.R)$($C.B)$title$($C.R) $bc")
    if ($Comet -and $AnyBusy) {
        $p = ($tick * 2) % ($fill + 10)
        $head = PalAt ($tick * 0.01)
        for ($k = 0; $k -lt $fill; $k++) {
            $d = $p - $k
            if ($d -ge 0 -and $d -lt 8) {
                [void]$sb.Append((RgbA (Mix $head $BorderRgb ($d / 8)))).Append($(if ($d -lt 2) { '━' } else { '─' }))
            } else { [void]$sb.Append($bc).Append('─') }
        }
        [void]$sb.Append($bc)
    } else { [void]$sb.Append('─' * $fill) }
    [void]$sb.Append("╮$($C.R)")
    $L.Add($sb.ToString())
    foreach ($ln in $lines) {
        foreach ($wl in @(WrapC $ln $inner 2)) { $L.Add("$bc│$($C.R) $(Fit $wl $inner)$($C.R) $bc│$($C.R)") }
    }
    $L.Add("$bc╰$('─' * ($W - 2))╯$($C.R)")
}

function Read-Limits($a) {
    $fi = Get-Item -LiteralPath $a.StatusFile
    if (-not $fi -or $fi.LastWriteTimeUtc -eq $a.LimStamp) { return }
    $d = Get-Content -LiteralPath $a.StatusFile -Raw | ConvertFrom-Json
    if ($d) { $a.Lim = $d; $a.LimStamp = $fi.LastWriteTimeUtc }
}

function Dur([double]$sec) {
    if ($sec -le 0) { return 'maintenant' }
    $t = [TimeSpan]::FromSeconds($sec)
    if ($t.TotalDays -ge 1) { return '{0}j {1:00}h' -f [int][Math]::Floor($t.TotalDays), $t.Hours }
    if ($t.TotalHours -ge 1) { return '{0}h {1:00}m' -f [int][Math]::Floor($t.TotalHours), $t.Minutes }
    '{0}m' -f [int][Math]::Ceiling($t.TotalMinutes)
}

function LimBar([double]$pct, [int]$w, [double]$pace) {
    # barre colorée + reflet qui glisse + repère ┃ du « rythme régulier »
    $parts = ' ▏▎▍▌▋▊▉█'
    $exact = [Math]::Min(1.0, [Math]::Max(0.0, $pct)) * $w
    $full = [int][Math]::Floor($exact)
    $rem = [int][Math]::Round(($exact - $full) * 8)
    $mark = if ($pace -ge 0) { [Math]::Min($w - 1, [int][Math]::Round($pace * ($w - 1))) } else { -1 }
    $band = ($tick * 0.5) % ($full + 16) - 4
    $sb = [Text.StringBuilder]::new()
    for ($k = 0; $k -lt $w; $k++) {
        if ($k -eq $mark) { [void]$sb.Append("$($C.B)$(Rgb 255 255 255)┃$($C.R)"); continue }
        if ($k -lt $full) {
            $col = Heat ($k / [Math]::Max(1, $w - 1))
            $d = [Math]::Abs($k - $band)
            if ($d -lt 3) { $col = Mix $col @(255,255,255) (0.5 * (1 - $d / 3)) }
            [void]$sb.Append((RgbA $col)).Append('█')
        } elseif ($k -eq $full -and $rem -gt 0) {
            [void]$sb.Append((RgbA (Heat ($k / [Math]::Max(1, $w - 1))))).Append($parts[$rem])
        } else {
            [void]$sb.Append((Rgb 55 58 75)).Append('░')
        }
    }
    [void]$sb.Append($C.R); $sb.ToString()
}

function LimLines([string]$label, $win, [double]$period, [int]$inner, [double]$ph) {
    $lab = "$($C.B)$(Grad $label ($tick * 0.01 + $ph) 0.04)$($C.R)"
    $padL = ' ' * [Math]::Max(0, 8 - $label.Length)
    if (-not $win) { return @("$lab$padL$($C.Dim)— pas de données pour l'instant$($C.R)") }
    $p = [double]$win.used_percentage
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $left = [double]$win.resets_at - $now
    $pace = [Math]::Min(1.0, [Math]::Max(0.0, 1 - $left / $period))
    $pc = RgbA (Heat ([Math]::Min(1.0, $p / 100)))
    $bw = [Math]::Max(10, $inner - 8 - 6)
    $l1 = "$lab$padL$(LimBar ($p / 100) $bw $pace) $($C.B)$pc$('{0,4:N0}%' -f $p)$($C.R)"
    $when = ([DateTimeOffset]::FromUnixTimeSeconds([long]$win.resets_at)).LocalDateTime.ToString('ddd HH:mm', $Fr)
    $diff = $p - $pace * 100
    $verdict = if ($diff -gt 5) { "$(Rgb 255 110 90)▲ $('{0:N0}' -f $diff) pts au-dessus du rythme$($C.R)" }
               elseif ($diff -lt -5) { "$(Rgb 120 230 140)▼ $('{0:N0}' -f -$diff) pts sous le rythme$($C.R)" }
               else { "$(Rgb 245 200 80)● dans le rythme$($C.R)" }
    $l2 = "        $($C.Dim)reset dans$($C.R) $($C.B)$(Rgb 120 200 255)$(Dur $left)$($C.R) $($C.Dim)($when)$($C.R)  $verdict"
    @($l1, $l2)
}

function Add-Limits($L, [int]$W) {
    $inner = $W - 4
    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not $Lim) {
        $lines.Add("$($C.Dim)en attente des limites… (mises à jour à chaque réponse de Claude)$($C.R)")
    } else {
        $rl = $Lim.rate_limits
        foreach ($x in @(LimLines 'Semaine' $rl.seven_day (7 * 86400) $inner 0.0)) { $lines.Add($x) }
        foreach ($x in @(LimLines 'Session' $rl.five_hour (5 * 3600) $inner 0.5)) { $lines.Add($x) }
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$Lim.updated
        $lines.Add("$($C.Dim)┃ = rythme régulier · maj il y a $(Dur $age)$($C.R)")
    }
    Panel $L (Ttl '◷' 'LIMITES' 0.8) $lines $W
}

function CtxSize($a) {
    # priorité : -ContextWindow explicite > taille transmise par la barre de statut > 200k / 1M selon l'usage
    if ($CtxForced) { return $ContextWindow }
    if ($a.S -and $a.Lim -and $a.Lim.ctx_sizes) {
        $sid = [IO.Path]::GetFileNameWithoutExtension($a.S.File)
        $v = $a.Lim.ctx_sizes.$sid
        if ($v -gt 0) { return [long]$v }
    }
    if ($a.S -and $a.S.Ctx -gt $ContextWindow) { return 1000000 }
    $ContextWindow
}

# ───────────────────────── multi-comptes ─────────────────────────
function Focus-Acct {
    # compte détaillé : celui choisi avec Tab, sinon celui qui travaille / a été actif en dernier
    if ($Pinned -ge 0 -and $Pinned -lt $Accts.Count) { return $Accts[$Pinned] }
    $c = @($Accts | Where-Object { $_.S })
    if (-not $c.Count) { return $Accts[0] }
    $b = @($c | Where-Object { $_.S.Busy })
    if ($b.Count) { $c = $b }
    $c | Sort-Object LastAct -Descending | Select-Object -First 1
}

function LimMini([string]$label, $win, [double]$period, [int]$inner, [string]$bar) {
    # une ligne : libellé, barre (avec repère de rythme), %, temps avant le reset
    $lab = "$($C.Dim)$label$($C.R)$(' ' * [Math]::Max(0, 8 - $label.Length))"
    if (-not $win) { return "$bar   $lab$($C.Dim)—$($C.R)" }
    $p = [double]$win.used_percentage
    $left = [double]$win.resets_at - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $pace = [Math]::Min(1.0, [Math]::Max(0.0, 1 - $left / $period))
    $pc = RgbA (Heat ([Math]::Min(1.0, $p / 100)))
    $diff = $p - $pace * 100
    $trend = if ($diff -gt 5) { "$(Rgb 255 110 90)▲$($C.R)" } elseif ($diff -lt -5) { "$(Rgb 120 230 140)▼$($C.R)" } else { "$(Rgb 245 200 80)●$($C.R)" }
    $bw = [Math]::Max(8, $inner - 33)
    "$bar   $lab$(LimBar ($p / 100) $bw $pace) $($C.B)$pc$('{0,3:N0}%' -f $p)$($C.R) $trend $($C.Dim)↺$($C.R) $(Rgb 120 200 255)$(Dur $left)$($C.R)"
}

function Add-Accounts($L, [int]$W, $focus) {
    $inner = $W - 4
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $Accts) {
        $bar = "$(RgbA $a.Rgb)┃$($C.R)"
        $name = "$($C.B)$(RgbA $a.Rgb)$($a.Label)$($C.R)"
        $foc = if ($a -eq $focus) { " $(RgbA $a.Rgb)◂$($C.R)$($C.Dim)$(if ($Pinned -ge 0) { ' épinglé' } else { '' })$($C.R)" } else { '' }
        if (-not $a.Logged) {
            $lines.Add("$bar $name  $(Rgb 255 210 110)○ non connecté$($C.R) $($C.Dim)(FLOW : C)$($C.R)")
            continue
        }
        if ($a.S) {
            if ($a.S.Busy) {
                $pulse = Mix @(80,230,140) @(220,255,230) ((1 + [Math]::Sin($tick * 0.35)) / 2 * 0.6)
                $el = ((Get-Date) - $a.S.BusySince)
                $elS = if ($el.TotalHours -ge 1) { $el.ToString('h\:mm\:ss') } else { $el.ToString('mm\:ss') }
                $state = "$(RgbA $pulse)● travaille$($C.R) $($C.Dim)$elS$($C.R)$(Act-Text $a)"
            } elseif ($a.Done) { $state = "$($C.B)$(Rgb 96 232 196)✓ à toi$($C.R)" }
            else { $state = "$(Rgb 120 120 150)○ en attente$($C.R)" }
            $pct = $a.S.Ctx / (CtxSize $a)
            $ctx = "$($C.Dim)ctx$($C.R) $($C.B)$(RgbA (Heat ([Math]::Min(1.0, $pct))))$('{0:N0}%' -f ($pct * 100))$($C.R)"
            $model = "$($a.S.Model)" -replace '^claude-', ''
            $lines.Add("$bar $name$foc  $state  $ctx  $($C.Dim)$model$($C.R)")
        } elseif ($a.Track) {
            $lines.Add("$bar $name$foc  $($C.Dim)en attente d'une session…$($C.R)")
        } else {
            $lines.Add("$bar $name  $($C.Dim)(limites seulement)$($C.R)")
        }
        if (-not $a.Lim) {
            $lines.Add("$bar   $($C.Dim)limites : en attente d'une réponse de Claude$($C.R)")
        } else {
            $lines.Add((LimMini 'semaine' $a.Lim.rate_limits.seven_day (7 * 86400) $inner $bar))
            $lines.Add((LimMini 'session' $a.Lim.rate_limits.five_hour (5 * 3600) $inner $bar))
            # alerte : limite presque atteinte → proposer l'autre compte
            $wst = Limit-Worst $a
            if ($wst -and $wst.Pct -ge 90) {
                $alt = Best-Other $a
                $left = $wst.Reset - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $msg = if ($alt) { "→ passe sur $($C.B)$(RgbA $alt.A.Rgb)$($alt.A.Label)$($C.R)$(Rgb 255 210 110) ($([int]$alt.Pct) %)" }
                       else { "reset dans $(Dur $left)" }
                $lines.Add("$bar   $(Rgb 255 110 90)⚠ $($wst.Name) à $([int]$wst.Pct) %$($C.R) $(Rgb 255 210 110)$msg$($C.R)")
            }
        }
    }
    $lines.Add("$($C.Dim)┃ = rythme · clic sur un compte : détail · sur son modèle : le changer · A : auto$($C.R)")
    Panel $L (Ttl '◷' 'COMPTES' 0.8) $lines $W
}

function Ttl([string]$icon, [string]$name, [double]$ph) { "$(PalC ($tick * 0.008 + $ph))$icon$($C.R)$($C.B) $name" }

# ───────────────────────── rendu ─────────────────────────
function ConW { try { $w = [Console]::WindowWidth; if ($w -gt 0) { return $w } } catch {}; 60 }
function ConH { try { $h = [Console]::WindowHeight; if ($h -gt 0) { return $h } } catch {}; 42 }

function Render {
    $W = [Math]::Max(30, (ConW) - 1)
    $H = [Math]::Max(5, (ConH))
    $inner = $W - 4
    $L = [System.Collections.Generic.List[string]]::new()
    Add-Header $L $W
    $acc = PalC ($tick * 0.02)

    # compte affiché en détail (un seul compte : toujours lui)
    $fa = Focus-Acct
    $script:S = $fa.S; $script:Lim = $fa.Lim
    if ($Multi) { Add-Accounts $L $W $fa }

    if (-not $S) {
        if (-not $Multi) {
            $dots = '.' * ([int][Math]::Floor($tick / 4) % 4)
            Panel $L (Ttl '◈' 'STATUT' 0) @(
                ''
                "  $acc$($spin[$tick % 10])$($C.R) $(Rgb 255 210 110)En attente d'une session Claude$dots$($C.R)"
                "    $($C.Dim)(envoie un premier message à Claude)$($C.R)"
                ''
            ) $W
            Add-Limits $L $W
        }
    } else {
        # — session —
        $sid = [IO.Path]::GetFileNameWithoutExtension($S.File); if ($sid.Length -gt 8) { $sid = $sid.Substring(0, 8) }
        $title = if ($S.Title) { $S.Title } else { $sid }
        $err = if ($S.Errors) { "  $(Rgb 255 90 90)✗ $($S.Errors)$($C.R)" } else { '' }
        $tag = if ($Multi) { " $(RgbA $fa.Rgb)· $($fa.Label)" } else { '' }
        if (-not $Multi) {
            if ($S.Busy) {
                $pulse = Mix @(80,230,140) @(220,255,230) ((1 + [Math]::Sin($tick * 0.35)) / 2 * 0.6)
                $el = ((Get-Date) - $S.BusySince)
                $elS = if ($el.TotalHours -ge 1) { $el.ToString('h\:mm\:ss') } else { $el.ToString('mm\:ss') }
                $state = "$(RgbA $pulse)● travaille$($C.R) $acc$($spin[$tick % 10])$($C.R) $($C.Dim)$elS$($C.R)$(Act-Text $fa)"
            } elseif ($fa.Done) {
                $state = "$($C.B)$(Rgb 96 232 196)✓ à toi$($C.R) $($C.Dim)— Claude a terminé$($C.R)"
            } else {
                $state = "$(Rgb 120 120 150)○ en attente$($C.R)"
            }
            Panel $L (Ttl '◈' 'SESSION' 0) @(
                "$($C.B)$title$($C.R) $($C.Dim)($sid)$($C.R)"
                "$($C.Dim)modèle$($C.R) $($C.B)$(Grad $S.Model ($tick * 0.01 + 0.4) 0.02)$($C.R)   $($C.Dim)tours$($C.R) $($C.B)$($S.Turns)$($C.R)$err"
                $state
            ) $W
            Add-Limits $L $W
        }

        # — contexte —
        $cw = CtxSize $fa
        $pct = $S.Ctx / $cw
        $pctS = '{0,3:N0}%' -f ($pct * 100)
        $left = [Math]::Max(0, $cw - $S.Ctx)
        $outTot = ($S.OutById.Values | Measure-Object -Sum).Sum
        $pc = RgbA (Heat ([Math]::Min(1.0, $pct)))
        $cl = [System.Collections.Generic.List[string]]::new()
        if ($Multi) { $cl.Add("$($C.B)$title$($C.R) $($C.Dim)($sid) · tours$($C.R) $($C.B)$($S.Turns)$($C.R)$err") }
        $cl.Add("$(Bar $pct ($inner - 5) $S.Busy) $($C.B)$pc$pctS$($C.R)")
        $cl.Add("$($C.Dim)utilisé$($C.R) $($C.B)$(Fmt $S.Ctx)$($C.R)$($C.Dim)/$(Fmt $cw)$($C.R)  $($C.Dim)restant$($C.R) $($C.B)$(Rgb 120 230 140)$(Fmt $left)$($C.R)")
        $cl.Add("$($C.Dim)cache lu$($C.R) $(Fmt $S.CacheR)  $($C.Dim)écrit$($C.R) $(Fmt $S.CacheW)  $($C.Dim)sortie$($C.R) $(Fmt $outTot)")
        $cl.Add("$($C.Dim)histo$($C.R) $(Spark $S.CtxHist ($inner - 6) $cw)")
        Panel $L (Ttl '◉' "CONTEXTE$tag" 0.2) $cl $W

        # — outils & agents —
        $tl = [System.Collections.Generic.List[string]]::new()
        $chips = ($S.ToolCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6 |
            ForEach-Object { "$(ToolIcon $_.Key) $($C.R)$(ToolName $_.Key)$(Rgb 95 98 120)·$($C.R)$($C.B)$($_.Value)$($C.R)" }) -join '  '
        $tl.Add("$($C.B)$($S.Tools)$($C.R) $($C.Dim)appels$($C.R)  $chips")
        if ($S.Pending.Count) {
            $names = ($S.Pending.Values | Select-Object -Unique | ForEach-Object { ToolName $_ }) -join ', '
            $tl.Add("$acc$($spin[$tick % 10])$($C.R) $(Rgb 255 210 110)en cours: $names$($C.R)")
        }
        if ($S.Agents.Count) {
            $tl.Add("$(Rgb 200 140 255)◆$($C.R) $($C.B)$($S.Agents.Count)$($C.R) $($C.Dim)agents$($C.R)")
            foreach ($a in @($S.Agents.Values) | Select-Object -Last 4) {
                $ico = switch ($a.Status) {
                    'run' { "$(PalC ($tick * 0.03))$($spin2[[int][Math]::Floor($tick / 2) % 4])$($C.R)" }
                    'ok'  { "$(Rgb 120 230 140)✓$($C.R)" }
                    default { "$(Rgb 255 90 90)✗$($C.R)" }
                }
                $el = if ($a.Status -eq 'run') { ' ' + ((Get-Date) - $a.Start).ToString('mm\:ss') } else { '' }
                $tl.Add("  $ico $(Rgb 200 140 255)$($a.Type)$($C.R) $($a.Desc)$($C.Dim)$el$($C.R)")
            }
        }
        Panel $L (Ttl '⚙' "OUTILS$tag" 0.4) $tl $W
    }

    # — flux d'activité (commun à tous les comptes) —
    if ($S -or ($Multi -and $Feed.Count)) {
        $room = $H - 1 - $L.Count - 2
        if ($room -gt 0) {
            # du plus récent au plus ancien, chaque entrée repliée sur plusieurs lignes
            $fw = $inner - 1
            $maxLines = 6
            $fl = [System.Collections.Generic.List[string]]::new()
            $last = $Feed.Count - 1
            for ($i = $last; $i -ge 0 -and $fl.Count -lt $room; $i--) {
                $f = $Feed[$i] -replace '\s+', ' '
                if ($i -eq $last) {
                    # effet machine à écrire sur la dernière entrée
                    $rev = 14 + ($tick - $NewTick) * 8
                    if ((VisLen $f) -gt $rev) {
                        $cur = if (($tick % 4) -lt 2) { '▌' } else { ' ' }
                        $f = (Fit $f $rev -Cut).TrimEnd() + "$acc$cur$($C.R)"
                    }
                    $wl = @(Wrap $f $fw 9)
                } else {
                    $wl = @(WrapC $f $fw 9)
                }
                if ($wl.Count -gt $maxLines) {
                    $wl = $wl[0..($maxLines - 1)]
                    $wl[-1] = (Fit $wl[-1] ($fw - 2) -Cut) + " $($C.Dim)…$($C.R)"
                }
                $mark = if ($i -eq $last) { "$acc▸$($C.R)" } else { ' ' }
                $block = @("$mark$($wl[0])") + @($wl | Select-Object -Skip 1 | ForEach-Object { " $_" })
                $fl.InsertRange(0, [string[]]$block)
            }
            if ($fl.Count -gt $room) { $fl.RemoveRange(0, $fl.Count - $room) }
            while ($fl.Count -lt $room) { $fl.Add('') }
            Panel $L (Ttl '≋' 'FLUX' 0.6) $fl $W -Comet
        }
    }

    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append("$e[H")
    for ($i = 0; $i -lt $H - 1; $i++) {
        $line = if ($i -lt $L.Count) { $L[$i] } else { '' }
        [void]$sb.Append((Fit $line $W)).Append($C.R).Append("$e[K`n")
    }
    [Console]::Write($sb.ToString())
    try { Monitor-Zones $L } catch {}
}

[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Console]::Write("$e[?25l$e[2J")
Enable-Mouse
try {
    $lastW = 0; $lastH = 0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $nextScan = 0.0
    while ($true) {
        # recherche de session et lecture des limites : toutes les ~2 s (indépendant de la cadence d'affichage)
        $now = $clock.Elapsed.TotalSeconds
        $scan = $now -ge $nextScan
        foreach ($a in $Accts) {
            try {
                if ($scan) {
                    if ($a.Track) {
                        $f = Find-Session $a
                        if ($f -and (-not $a.S -or $a.S.File -ne $f)) {
                            $a.S = New-State $f
                            $a.Primed = $false; $a.Done = $false
                            if (-not $Multi) { $Feed.Clear() }
                        }
                    }
                    Read-Limits $a
                    Check-LimitAlerts $a
                    $a.Logged = Test-Path -LiteralPath (Join-Path $a.Dir '.credentials.json')
                }
                if ($a.S) { $script:S = $a.S; $script:CurA = $a; Read-New; Check-TurnEnd $a }
            } catch {}   # un compte en erreur (fichier verrouillé, dossier absent…) n'arrête pas les autres
        }
        $script:CurA = $null
        if ($scan) {
            try { Refresh-PaneMap } catch {}
            $nextScan = $now + $(if (@($Accts | Where-Object { $_.S }).Count) { 2.0 } else { 1.0 })
        }
        try { Sync-Panes; Sync-Status } catch {}
        $AnyS = [bool]@($Accts | Where-Object { $_.S }).Count
        $AnyBusy = [bool]@($Accts | Where-Object { $_.S -and $_.S.Busy }).Count

        # Tab : compte détaillé suivant (… → automatique) · A : automatique
        # clic sur un compte ou son personnage : le détailler ; clic sur son modèle : changer de modèle
        try {
            while ($ev = Read-Event) {
                if ($ev.Kind -eq 'click') {
                    $z = Find-Zone $ev.X $ev.Y
                    if (-not $z) { continue }
                    if ($z.What -eq 'model') { Change-Model $z.Acct }
                    elseif ($z.What -eq 'focus' -and $Multi) { $Pinned = [array]::IndexOf(@($Accts), $z.Acct); Set-MonFlash "$($C.Dim)détail : $($z.Acct.Label) (A pour revenir en automatique)$($C.R)" }
                    continue
                }
                if ($ev.Kind -ne 'key') { continue }
                $k = $ev.K
                if ($k.Key -eq 'Tab' -and $Multi) { $Pinned = if ($Pinned + 1 -ge $Accts.Count) { -1 } else { $Pinned + 1 } }
                elseif ("$($k.KeyChar)" -eq 'a') { $Pinned = -1 }
            }
        } catch {}

        if ((ConW) -ne $lastW -or (ConH) -ne $lastH) {
            [Console]::Write("$e[2J"); $lastW = ConW; $lastH = ConH
        }
        # une erreur d'affichage ponctuelle ne doit jamais fermer le moniteur
        try { Render } catch { [Console]::Write("$e[H$($C.R)$(Rgb 255 110 90) ✗ $($_.Exception.Message)$($C.R)$e[K") }
        $tick++
        if ($Frames -gt 0 -and $tick -ge $Frames) { break }
        # animation fluide quand Claude travaille ou qu'une entrée vient d'arriver, sinon cadence réduite
        $active = $AnyBusy -or ($AnyS -and ($tick - $NewTick) -lt 40)
        $delay = if ($active) { $Refresh } else { [Math]::Max($Refresh, $IdleRefresh) }
        Start-Sleep -Milliseconds ([int]($delay * 1000))
    }
} finally {
    Disable-Mouse
    [Console]::Write("$($C.R)$e[?25h")
}

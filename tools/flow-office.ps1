<#
  flow-office.ps1 — le « Bureau » de FLOW : un petit personnage animé par Claude au travail.

    Bureau principal   un personnage par Claude suivi (un par compte), animé selon ce qu'il fait
    Agents · Compte 1  une pièce par Claude qui a lancé des sous-agents (outil Agent / Task)
    Workflow · nom     une pièce par workflow lancé (outil Workflow), un personnage par agent
    Équipe · résumé    une pièce par équipe FLOW en cours (tools\flow-team.ps1), un personnage par tâche

  Lancé par FLOW (rôle de panneau « office ») avec le même -Watch que le moniteur :
    libellé | couleur | dossier du compte | dossier de travail | identifiant | nom court ; …
#>
param(
    [string]$Watch,
    [string]$Sock,                # serveur psmux de FLOW : permet d'aller au panneau d'un personnage et de lui écrire
    [string]$Session,             # session psmux du Bureau
    [double]$Refresh = 0.15,
    [int]$Frames = 0
)
# Touches : Tab / ← → choisir un personnage · ↑ ↓ changer de pièce · Entrée aller à son panneau
#           M lui écrire · Échap annuler
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'flow-sprites.ps1')
. (Join-Path $PSScriptRoot 'flow-input.ps1')     # clavier + souris (clics)

$e = [char]27; $R = "$e[0m"; $B = "$e[1m"; $Dm = "$e[2m"
$ansiRx = "$e\[[0-9;]*m"
function Rgb($c) { "$e[38;2;$($c[0]);$($c[1]);$($c[2])m" }
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
function Cut([string]$s, [int]$w) { if ($s.Length -le $w) { $s } else { $s.Substring(0, $w - 1) + '…' } }
function ConW { try { $w = [Console]::WindowWidth; if ($w -gt 0) { return $w } } catch {}; 100 }
function ConH { try { $h = [Console]::WindowHeight; if ($h -gt 0) { return $h } } catch {}; 18 }
function HexRgb([string]$h) {
    $h = "$h".TrimStart('#')
    if ($h -notmatch '^[0-9a-fA-F]{6}$') { return @(255, 138, 92) }
    @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}
function Proj-Key([string]$p) { ([IO.Path]::GetFullPath($p).TrimEnd('\', '/')) -replace '[^a-zA-Z0-9]', '-' }
$AgentPal = @(@(255, 94, 158), @(168, 112, 255), @(84, 186, 255), @(96, 232, 196), @(255, 210, 110), @(255, 138, 92))

# ───────────────────────── comptes suivis ─────────────────────────
$Accts = @(foreach ($ent in ("$Watch" -split ';')) {
        if (-not $ent.Trim()) { continue }
        $f = $ent -split '\|', 6
        $dir = if ($f.Count -gt 2 -and $f[2].Trim()) { $f[2].Trim() } else { Join-Path $HOME '.claude' }
        [pscustomobject]@{
            Label = $f[0].Trim(); Rgb = (HexRgb $(if ($f.Count -gt 1) { $f[1] })); Home = $dir
            Cwd = $(if ($f.Count -gt 3) { $f[3].Trim() } else { '' })
            Id = $(if ($f.Count -gt 4) { $f[4].Trim() } else { '' })
            Short = $(if ($f.Count -gt 5 -and $f[5].Trim()) { $f[5].Trim() } else { $f[0].Trim() })
        }
    })
if (-not $Accts.Count) { $Accts = @([pscustomobject]@{ Label = 'Claude'; Rgb = @(255, 138, 92); Home = (Join-Path $HOME '.claude'); Cwd = (Get-Location).Path; Id = ''; Short = 'C' }) }

function Latest-Session($a, [string]$cwd) {
    $pd = Join-Path (Join-Path $a.Home 'projects') (Proj-Key $cwd)
    (Get-ChildItem -LiteralPath $pd -Filter *.jsonl -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

# ───────────────────────── délégations (agents, workflows) d'une conversation ─────────────────────────
function Text-Of($content) {
    if ($content -is [string]) { return $content }
    (@($content) | ForEach-Object { if ($_.type -eq 'text') { $_.text } elseif ($_.type -eq 'tool_result') { if ($_.content -is [string]) { $_.content } else { @($_.content | ForEach-Object { $_.text }) -join ' ' } } }) -join ' '
}

function Scan-Delegations([string]$file) {
    # appels Agent/Task/Workflow de la conversation, avec leur état (en cours / fini)
    $calls = [ordered]@{}
    foreach ($ln in (Read-Tail $file 1572864)) {
        $o = $null; try { $o = $ln | ConvertFrom-Json -Depth 64 -ErrorAction Stop } catch { continue }
        if ($o.isSidechain -or $o.type -notin 'assistant', 'user') { continue }
        $ts = try { ([datetime]$o.timestamp).ToLocalTime() } catch { Get-Date }
        if ($o.type -eq 'assistant') {
            foreach ($c in @($o.message.content)) {
                if ($c.type -ne 'tool_use') { continue }
                if ($c.name -in 'Agent', 'Task') {
                    $nm = if ($c.input.name) { $c.input.name } elseif ($c.input.description) { $c.input.description } elseif ($c.input.subagent_type) { $c.input.subagent_type } else { 'agent' }
                    $calls[$c.id] = [pscustomobject]@{ Kind = 'agent'; Name = [string]$nm; Type = [string]$c.input.subagent_type; Prompt = [string]$c.input.prompt
                        Bg = [bool]$c.input.run_in_background; Start = $ts; End = $null; RunId = ''; Labels = @() }
                } elseif ($c.name -eq 'Workflow') {
                    $scr = [string]$c.input.script
                    $nm = if ($scr -match "name:\s*['""]([^'""]+)") { $Matches[1] } elseif ($c.input.name) { [string]$c.input.name } else { 'workflow' }
                    # agents du workflow : agent('consigne…', { label: 'nom' }) → nom + consigne (sur quoi il travaille)
                    $labels = @([regex]::Matches($scr, "agent\(\s*([``'""])(.*?)\1\s*,\s*\{[^}]*?label:\s*[``'""]([^``'""$]+)", 'Singleline') | ForEach-Object {
                            [pscustomobject]@{ Label = $_.Groups[3].Value.TrimEnd(':', '-', ' '); Prompt = (($_.Groups[2].Value -replace '\$\{[^}]*\}', '…') -replace '\s+', ' ').Trim() } })
                    if (-not $labels.Count) {
                        $labels = @([regex]::Matches($scr, "label:\s*[``'""]([^``'""$]+)") | ForEach-Object { [pscustomobject]@{ Label = $_.Groups[1].Value.TrimEnd(':', '-', ' '); Prompt = '' } })
                    }
                    $seen = @{}   # sans doublons, dans l'ordre du script
                    $labels = @($labels | Where-Object { $_.Label -and -not $seen.ContainsKey($_.Label) } | ForEach-Object { $seen[$_.Label] = 1; $_ })
                    $calls[$c.id] = [pscustomobject]@{ Kind = 'wf'; Name = $nm; Type = ''; Prompt = ''; Bg = $true; Start = $ts; End = $null; RunId = ''; Labels = $labels }
                }
            }
        } else {
            $content = $o.message.content
            foreach ($c in @($content)) {
                if ($c.type -eq 'tool_result' -and $calls.Contains($c.tool_use_id)) {
                    $call = $calls[$c.tool_use_id]
                    $txt = Text-Of @($c)
                    # identifiant de la tâche de fond (contient au moins un chiffre), cité plus tard dans sa notification de fin
                    if ($call.Bg -and $txt -match '\b(wf_[a-z0-9-]{6,}|[a-z]*[0-9][a-z0-9]{6,})\b') { $call.RunId = $Matches[1] }
                    if (-not $call.Bg) { $call.End = $ts }
                }
            }
            # fin d'une tâche de fond : notification qui cite son identifiant
            $txt = Text-Of $content
            if ($txt -match 'task-notification') {
                foreach ($call in $calls.Values) { if ($call.Bg -and -not $call.End -and $call.RunId -and $txt.Contains($call.RunId)) { $call.End = $ts } }
            }
        }
    }
    @($calls.Values)
}

function Subagent-Files([string]$file) {
    # historiques séparés des sous-agents (selon la version de Claude Code) : <session>\subagents\*.jsonl
    $dir = Join-Path (Split-Path $file) ([IO.Path]::GetFileNameWithoutExtension($file))
    @(Get-ChildItem -LiteralPath $dir -Recurse -Filter *.jsonl -File | Sort-Object CreationTime)
}

function Agent-Activity([string]$file) {
    # historique d'un sous-agent : ses lignes peuvent être marquées « isSidechain » ou non selon la version
    $g = Get-Activity $file -Sidechain
    if ($g.Act -eq 'idle' -and -not $g.Thought) { $g = Get-Activity $file }
    $g
}

function First-Prompt([string]$file) {
    try {
        foreach ($ln in [IO.File]::ReadLines($file)) {
            $o = $ln | ConvertFrom-Json -Depth 32 -ErrorAction Stop
            if ($o.type -eq 'user') { return (Text-Of $o.message.content) }
        }
    } catch {}
    ''
}

# ───────────────────────── équipes FLOW ─────────────────────────
$RecentFile = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\config\team-projects.json'))
function Team-Projects {
    # équipes du (des) projet(s) de CETTE session : le Bureau d'un projet n'affiche pas les équipes des autres projets (ni d'une démo oubliée).
    # La liste des projets récents ne sert que si la session n'a aucun dossier de projet.
    $lst = @($Accts | Where-Object { $_.Cwd } | ForEach-Object { $_.Cwd })
    if (-not $lst.Count) { try { $lst += @(Get-Content -LiteralPath $RecentFile -Raw | ConvertFrom-Json) } catch {} }
    @($lst | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique)
}

# ───────────────────────── collecte ─────────────────────────
$Seed = @{}
function SeedOf([string]$k) { if (-not $Seed.ContainsKey($k)) { $Seed[$k] = $Seed.Count }; $Seed[$k] }
$SubCache = @{}   # fichier de sous-agent → premier prompt

function Collect {
    $rooms = [Collections.Generic.List[object]]::new()
    $main = [pscustomobject]@{ Title = '⌂ Bureau'; Rgb = @(84, 186, 255); Members = [Collections.Generic.List[object]]::new() }
    $rooms.Add($main)
    foreach ($a in $Accts) {
        if (-not $a.Cwd) { continue }
        $file = Latest-Session $a $a.Cwd
        $logged = Test-Path -LiteralPath (Join-Path $a.Home '.credentials.json')
        $act = if (-not $logged) { [pscustomobject]@{ Act = 'idle'; Detail = 'non connecté'; Thought = '' } } else { Get-Activity $file }
        $main.Members.Add([pscustomobject]@{ Name = $a.Label; Rgb = $a.Rgb; Act = $act.Act; Detail = $act.Detail; Thought = $act.Thought; Task = ''; Seed = (SeedOf "main:$($a.Label)"); Key = "main:$($a.Label)"; Kind = 'main'; AcctId = $a.Id; Parent = ''; Worktree = ''; Model = $act.Model })
        if (-not $file) { continue }

        # sous-agents et workflows lancés par ce Claude
        $calls = Scan-Delegations $file
        $files = Subagent-Files $file
        foreach ($sf in $files) { if (-not $SubCache.ContainsKey($sf.FullName)) { $SubCache[$sf.FullName] = ((First-Prompt $sf.FullName) -replace '\s+', ' ').Trim() } }
        $agentPrompts = @($calls | Where-Object { $_.Kind -eq 'agent' -and $_.Prompt } | ForEach-Object { $p = ($_.Prompt -replace '\s+', ' ').Trim(); $p.Substring(0, [Math]::Min(80, $p.Length)) })
        # en cours (une tâche de fond sans nouvelles depuis 2 h est considérée finie), ou finie il y a moins de 20 s
        $recent = { param($c) if ($c.End) { ((Get-Date) - $c.End).TotalSeconds -lt 20 } else { ((Get-Date) - $c.Start).TotalHours -lt $(if ($c.Bg) { 2 } else { 6 }) } }
        $agents = @($calls | Where-Object { $_.Kind -eq 'agent' -and (& $recent $_) -and ((Get-Date) - $_.Start).TotalHours -lt 6 })
        if ($agents.Count) {
            $side = $null
            $room = [pscustomobject]@{ Title = "◆ Agents · $($a.Label)"; Rgb = @(200, 140, 255); Members = [Collections.Generic.List[object]]::new() }
            $k = 0
            foreach ($ag in $agents) {
                $act = 'work'; $det = $ag.Type; $th = ''
                if ($ag.End) { $act = 'done'; $det = '' }
                else {
                    $p80 = ($ag.Prompt -replace '\s+', ' ').Trim(); if ($p80.Length -gt 80) { $p80 = $p80.Substring(0, 80) }
                    $match = $files | Where-Object { $p80 -and $SubCache[$_.FullName].StartsWith($p80) } | Select-Object -First 1
                    if ($match) { $g = Agent-Activity $match.FullName; $act = $g.Act; $det = $g.Detail; $th = $g.Thought }
                    elseif (-not $files.Count) {
                        # ancien format : activité des sous-agents dans la conversation principale
                        if ($null -eq $side) { $side = Get-Activity $file -Sidechain }
                        if ($side.Act -notin 'idle', 'look') { $act = $side.Act; $det = $side.Detail; $th = $side.Thought }
                    }
                }
                $room.Members.Add([pscustomobject]@{ Name = $ag.Name; Rgb = $AgentPal[$k % $AgentPal.Count]; Act = $act; Detail = $det; Thought = $th; Task = $ag.Prompt; Seed = (SeedOf "ag:$($ag.Start.Ticks):$k"); Key = "ag:$($ag.Start.Ticks):$k"; Kind = 'agent'; AcctId = ''; Parent = $a.Id; ParentLabel = $a.Label; Worktree = ''; Model = $ag.Type })
                $k++
            }
            $rooms.Add($room)
        }
        foreach ($wf in @($calls | Where-Object { $_.Kind -eq 'wf' -and (& $recent $_) -and ((Get-Date) - $_.Start).TotalHours -lt 6 })) {
            $room = [pscustomobject]@{ Title = "⚙ Workflow · $($wf.Name) · lancé par $($a.Label)"; Rgb = @(96, 232, 196); Members = [Collections.Generic.List[object]]::new() }
            $wfAgents = if ($wf.Labels.Count) { @($wf.Labels) } else { @(1..3 | ForEach-Object { [pscustomobject]@{ Label = "agent $_"; Prompt = '' } }) }
            # historiques des agents du workflow : sous-agents qui ne viennent pas d'un appel Agent, créés pendant le workflow
            $cand = [Collections.Generic.List[object]]::new()
            foreach ($sf in $files) {
                $fp = $SubCache[$sf.FullName]
                if (@($agentPrompts | Where-Object { $_ -and $fp.StartsWith($_) }).Count) { continue }
                if ($sf.CreationTime -lt $wf.Start.AddSeconds(-5)) { continue }
                if ($wf.End -and $sf.CreationTime -gt $wf.End) { continue }
                $cand.Add($sf)
            }
            $k = 0
            foreach ($wa in $wfAgents | Select-Object -First 8) {
                # d'abord le fichier dont la consigne correspond, sinon le suivant dans l'ordre de création
                $p40 = if ($wa.Prompt) { $wa.Prompt.Substring(0, [Math]::Min(40, $wa.Prompt.Length)).TrimEnd('…') } else { '' }
                $sf = $cand | Where-Object { $p40 -and $SubCache[$_.FullName].StartsWith($p40) } | Select-Object -First 1
                if (-not $sf -and $cand.Count) { $sf = $cand[0] }
                $act = if ($wf.End) { 'done' } else { 'work' }; $det = ''; $th = ''
                if ($sf) {
                    [void]$cand.Remove($sf)
                    $g = Agent-Activity $sf.FullName
                    if (-not $wf.End -or $g.Act -ne 'idle') { $act = $g.Act; $det = $g.Detail; $th = $g.Thought }
                    if ($wf.End) { $act = 'done' }
                }
                $room.Members.Add([pscustomobject]@{ Name = $wa.Label; Rgb = $AgentPal[$k % $AgentPal.Count]; Act = $act; Detail = $det; Thought = $th; Task = $wa.Prompt; Seed = (SeedOf "wf:$($wf.Start.Ticks):$k"); Key = "wf:$($wf.Start.Ticks):$k"; Kind = 'wf'; AcctId = ''; Parent = $a.Id; ParentLabel = $a.Label; Worktree = ''; Model = ''; Workflow = $wf.Name })
                $k++
            }
            $rooms.Add($room)
        }
    }

    # équipes FLOW en cours
    foreach ($proj in Team-Projects) {
        foreach ($sf in @(Get-ChildItem -LiteralPath (Join-Path $proj '.flow\runs') -Directory | ForEach-Object { Join-Path $_.FullName 'state.json' } | Where-Object { Test-Path -LiteralPath $_ })) {
            $st = $null; try { $st = Get-Content -LiteralPath $sf -Raw -Encoding utf8 | ConvertFrom-Json } catch {}
            if (-not $st -or $st.status -notin 'running', 'integrating', 'review') { continue }
            $room = [pscustomobject]@{ Title = "⚑ Équipe · $($st.summary)"; Rgb = @(255, 138, 92); Members = [Collections.Generic.List[object]]::new() }
            foreach ($t in @($st.tasks)) {
                $acc = $Accts | Where-Object { $_.Id -eq $t.account } | Select-Object -First 1
                $rgb = if ($acc) { $acc.Rgb } else { @(255, 138, 92) }
                $act = 'idle'; $det = ''; $th = ''
                switch ($t.status) {
                    'done'    { $act = 'done' }
                    'failed'  { $act = 'error'; $det = $t.error }
                    'pending' { $act = 'queue'; $det = "$((@($t.depends)) -join ',')" }
                    default {
                        $home_ = if ($acc) { $acc.Home } else { Join-Path $HOME '.claude' }
                        if ($t.worktree) { $g = Get-Activity (Latest-Session ([pscustomobject]@{ Home = $home_ }) $t.worktree); $act = $g.Act; $det = $g.Detail; $th = $g.Thought }
                        if ($act -eq 'look') { $act = 'work' }
                    }
                }
                if ($st.status -eq 'integrating' -and $t.status -eq 'done') { $act = 'delegate'; $det = 'intégration' }
                $nm = "$($t.id) · $($t.title)"
                $task = if ($t.goal) { [string]$t.goal } else { [string]$t.title }
                $room.Members.Add([pscustomobject]@{ Name = $nm; Rgb = $rgb; Act = $act; Detail = $det; Thought = $th; Task = $task; Seed = (SeedOf "team:$($st.id):$($t.id)"); Key = "team:$($st.id):$($t.id)"; Kind = 'team'; AcctId = [string]$t.account; Parent = ''; Worktree = [string]$t.worktree; TaskId = [string]$t.id; Model = [string]$t.model; Stuck = ($t.advisor -eq 'running') })
                if ($t.advisor -eq 'running') {
                    # le conseiller de cette tâche réfléchit (Claude en arrière-plan, plus puissant)
                    $room.Members.Add([pscustomobject]@{ Name = "conseiller $($t.id)"; Rgb = @(200, 140, 255); Act = 'think'; Detail = [string]$t.advisorModel
                        Thought = "J'étudie le blocage de $($t.id) pour lui proposer un plan…"; Task = ''; Seed = (SeedOf "adv:$($st.id):$($t.id)"); Key = "adv:$($st.id):$($t.id)"
                        Kind = 'advisor'; AcctId = ''; Parent = ''; Worktree = ''; Model = [string]$t.advisorModel })
                }
            }
            $rooms.Add($room)
        }
    }
    if (-not $main.Members.Count) { $main.Members.Add([pscustomobject]@{ Name = 'personne'; Rgb = @(255, 210, 110); Act = 'look'; Detail = 'en attente'; Thought = ''; Task = ''; Seed = 0; Key = 'none'; Kind = 'none'; AcctId = ''; Parent = ''; Worktree = ''; Model = '' }) }
    , $rooms
}

# ───────────────────────── interaction : choisir un personnage, aller à son panneau, lui écrire ─────────────────────────
$Psmux = $Sock -and (Get-Command psmux -ErrorAction SilentlyContinue)
$SelKey = ''          # personnage choisi
$Typing = $null       # message en cours de saisie (chaîne) ou $null
$Flash = ''; $FlashUntil = [datetime]::MinValue
$Flat = @(); $RoomOf = @{}

function Say-Flash([string]$s) { $script:Flash = $s; $script:FlashUntil = (Get-Date).AddSeconds(5) }
function Norm([string]$p) { if (-not $p) { return '' }; try { [IO.Path]::GetFullPath($p).TrimEnd('\').ToLower() } catch { $p.ToLower() } }

function Pane-List {
    if (-not $Psmux) { return @() }
    @(& psmux -L $Sock list-panes -a -F '#{session_name}|#{window_index}|#{pane_index}|#{@flow_acct}|#{@flow_task}|#{pane_current_path}' 2>$null | ForEach-Object {
            $f = "$_" -split '\|', 6
            if ($f.Count -eq 6) { [pscustomobject]@{ S = $f[0]; Win = $f[1]; P = $f[2]; Acct = $f[3]; Task = $f[4]; Path = $f[5] } }
        })
}

function Target-Pane($m) {
    # panneau du personnage ; pour un sous-agent ou un agent de workflow : celui du Claude qui l'a lancé
    $all = Pane-List
    if ($m.Kind -eq 'team') {
        $hit = $all | Where-Object { $_.Task -eq $m.TaskId -and (Norm $_.Path) -eq (Norm $m.Worktree) } | Select-Object -First 1
        if (-not $hit) { $hit = $all | Where-Object { $_.Task -eq $m.TaskId } | Select-Object -First 1 }
        return $hit
    }
    if ($m.Kind -in 'main', 'agent', 'wf') {
        $acct = if ($m.Kind -eq 'main') { $m.AcctId } else { $m.Parent }
        $cand = @($all | Where-Object { $_.Acct -eq $acct })
        $hit = $cand | Where-Object { $_.S -eq $Session } | Select-Object -First 1
        if (-not $hit) { $hit = $cand | Select-Object -First 1 }
        return $hit
    }
    $null
}

function Kind-Text($m) {
    switch ($m.Kind) {
        'main'    { "Claude principal$(if ($m.Model) { " · $($m.Model -replace '^claude-', '')" })" }
        'agent'   { "sous-agent de $($m.ParentLabel) (message relayé par lui)" }
        'wf'      { "agent du workflow $($m.Workflow), lancé par $($m.ParentLabel) (message relayé)" }
        'team'    { "ouvrier de l'équipe$(if ($m.Model) { " · modèle $($m.Model)" })" }
        'advisor' { "conseiller$(if ($m.Model) { " $($m.Model)" }) (en arrière-plan)" }
        default   { '' }
    }
}

function Focus-Member($m) {
    if (-not $Psmux) { return "$Dm(panneaux indisponibles hors de FLOW)$R" }
    $p = Target-Pane $m
    if (-not $p) { return "$(SpRgb @(255,110,90))✗ aucun panneau trouvé pour $($m.Name)$R" }
    if ($p.S -ne $Session) { & psmux -L $Sock switch-client -t $p.S *> $null }
    & psmux -L $Sock select-window -t "$($p.S):$($p.Win)" *> $null
    & psmux -L $Sock select-pane -t "$($p.S):$($p.Win).$($p.P)" *> $null
    "$(SpRgb @(120,200,255))→ panneau de $($m.Name)$R"
}

function Send-Member($m, [string]$text) {
    if ($m.Kind -eq 'advisor') { return "$Dm le conseiller travaille en arrière-plan : écris plutôt à l'ouvrier$R" }
    if ($m.Kind -eq 'none' -or -not $Psmux) { return "$Dm(personne à qui écrire)$R" }
    $p = Target-Pane $m
    if (-not $p) { return "$(SpRgb @(255,110,90))✗ aucun panneau trouvé pour $($m.Name)$R" }
    $msg = switch ($m.Kind) {
        'agent' { "[FLOW] Message de l'utilisateur pour ton sous-agent « $($m.Name) » : $text — transmets-le-lui (SendMessage) s'il travaille encore, sinon tiens-en compte toi-même." }
        'wf'    { "[FLOW] Message de l'utilisateur pour l'agent « $($m.Name) » du workflow $($m.Workflow) : $text — transmets-le si c'est possible, sinon tiens-en compte pour la suite." }
        default { $text }
    }
    $tgt = "$($p.S):$($p.Win).$($p.P)"
    & psmux -L $Sock send-keys -t $tgt -l ($msg -replace "`r?`n", ' ') *> $null
    & psmux -L $Sock send-keys -t $tgt Enter *> $null
    "$(SpRgb @(120,230,140))✓ message envoyé à $($m.Name)$(if ($m.Kind -in 'agent', 'wf') { " (via $($m.ParentLabel))" })$R"
}

function Handle-Keys {
    # clavier et souris : un clic choisit un personnage, un 2e clic (ou double-clic) ouvre son panneau
    while ($true) {
        $ev = $null
        try { $ev = Read-Event } catch { return }
        if (-not $ev) { return }
        if ($ev.Kind -eq 'click') {
            $z = Find-Zone $ev.X $ev.Y
            # retour visible : le clic est bien arrivé, même s'il ne touche aucun personnage
            if (-not $z) { Say-Flash "$Dm clic reçu ($($ev.X), $($ev.Y)) — aucun personnage ici : clique sur sa tête, sa bulle ou son nom$R"; continue }
            if ($z.Member -and $z.Member.Key) {
                $script:Typing = $null
                if ($z.Member.Key -eq $SelKey -or $ev.Double) { $script:SelKey = $z.Member.Key; Say-Flash (Focus-Member $z.Member) }
                else { $script:SelKey = $z.Member.Key }
            } elseif ($z.Hint) { Process-Key (Fake-Key $z.Hint) }
            continue
        }
        if ($ev.Kind -eq 'key') { Process-Key $ev.K }
    }
}

function Process-Key($k) {
    $m = $Flat | Where-Object { $_.Key -eq $SelKey } | Select-Object -First 1
    if ($null -ne $script:Typing) {
        switch ($k.Key) {
            'Escape'    { $script:Typing = $null }
            'Enter'     { if ($m -and $script:Typing.Trim()) { Say-Flash (Send-Member $m $script:Typing.Trim()) }; $script:Typing = $null }
            'Backspace' { if ($script:Typing.Length) { $script:Typing = $script:Typing.Substring(0, $script:Typing.Length - 1) } }
            default     { if (-not [char]::IsControl($k.KeyChar)) { $script:Typing += $k.KeyChar } }
        }
        return
    }
    if (-not $Flat.Count) { return }
    $i = -1; for ($j = 0; $j -lt $Flat.Count; $j++) { if ($Flat[$j].Key -eq $SelKey) { $i = $j; break } }
    $shift = [bool]($k.Modifiers -band [ConsoleModifiers]::Shift)
    $ri = if ($i -ge 0) { $RoomOf[$SelKey] } else { -1 }
    switch ($k.Key) {
        { $_ -eq 'RightArrow' -or ($_ -eq 'Tab' -and -not $shift) } { $script:SelKey = $Flat[($i + 1) % $Flat.Count].Key }
        { $_ -eq 'LeftArrow' -or ($_ -eq 'Tab' -and $shift) } { $script:SelKey = $Flat[($i - 1 + $Flat.Count) % $Flat.Count].Key }
        'DownArrow' { $nx = $Flat | Where-Object { $RoomOf[$_.Key] -gt $ri } | Select-Object -First 1; if (-not $nx) { $nx = $Flat[0] }; $script:SelKey = $nx.Key }
        'UpArrow'   { $pv = @($Flat | Where-Object { $RoomOf[$_.Key] -lt $ri }); $nx = if ($pv.Count) { $pv | Where-Object { $RoomOf[$_.Key] -eq $RoomOf[$pv[-1].Key] } | Select-Object -First 1 } else { $Flat[-1] }; $script:SelKey = $nx.Key }
        'Enter'     { if ($m) { Say-Flash (Focus-Member $m) } }
        'Escape'    { $script:SelKey = '' }
        default     { if ("$($k.KeyChar)".ToLower() -eq 'm' -and $m) { $script:Typing = '' } }
    }
}

function Footer-Lines([int]$W, [int]$tick) {
    # bas du Bureau : personnage choisi (qui il est, sur quoi il travaille, ce qu'il pense) ou aide
    $m = $Flat | Where-Object { $_.Key -eq $SelKey } | Select-Object -First 1
    $kc = SpRgb @(255, 210, 110)
    $out = @()
    if ($m) {
        $pgx = $Progress[(Progress-Of $m)]
        $out += " $B$(SpRgb @(40,255,120))▶ $(SpRgb $m.Rgb)$($m.Name)$R  $(SpRgb $pgx.Rgb)● $($pgx.Label)$R  $Dm$(Kind-Text $m)$R$(if ($m.Task) { "  $Dm· tâche :$R $(Cut ([string]$m.Task) ([Math]::Max(10, $W - 70)))" })"
        $out += "   $Dm« $(Bubble-Text $m.Act ([string]$m.Detail) ([string]$m.Thought) ([string]$m.Task)) »$R"
        if ($null -ne $Typing) {
            $cur = if (($tick % 6) -lt 4) { '▌' } else { ' ' }
            $out += " $kc✉ à $($m.Name) :$R $B$Typing$R$kc$cur$R   $Dm Entrée envoyer · Échap annuler$R"
        } else {
            $out += " $Dm$kc Tab/←→$R$Dm choisir · $kc↑↓$R$Dm pièce · $kc Entrée$R$Dm aller à son panneau · $kc M$R$Dm lui écrire · $kc Échap$R$Dm fermer$R   $(Legend)"
        }
    } else {
        $out += " $(Legend)   $Dm│ $kc Tab$R$Dm : choisir un personnage (aller à son panneau, lui écrire)$R"
    }
    if ($Flash -and (Get-Date) -lt $FlashUntil) { $out[-1] = " $Flash" }
    $out
}

# ───────────────────────── rendu ─────────────────────────
$CellW = 30
$RoomH = 14   # bordure, cadre de sélection, bulle (5), personnage (3), nom, activité, cadre, bordure

# couleur d'avancement de chaque personnage (tête, pastille, légende)
$Progress = [ordered]@{
    todo    = @{ Tag = 'À FAIRE';  Label = 'à faire';    Rgb = @(150, 150, 170) }
    doing   = @{ Tag = 'EN COURS'; Label = 'en cours';   Rgb = @(245, 200, 80) }
    waiting = @{ Tag = 'À TOI';    Label = 'attend une réponse'; Rgb = @(255, 94, 158) }
    stuck   = @{ Tag = 'BLOQUÉ';   Label = 'bloqué';     Rgb = @(255, 90, 90) }
    done    = @{ Tag = 'FINI';     Label = 'fini';       Rgb = @(120, 230, 140) }
}
function Progress-Of($m) {
    if ($m.Act -eq 'done') { return 'done' }
    if ($m.Act -eq 'error' -or $m.Stuck) { return 'stuck' }
    if ($m.Act -eq 'wait') { return 'waiting' }
    if ($m.Act -in 'queue', 'idle', 'look') { return 'todo' }
    'doing'
}
function Legend { ($Progress.GetEnumerator() | ForEach-Object { "$(SpRgb $_.Value.Rgb)●$R $Dm$($_.Value.Label)$R" }) -join '  ' }

function Room-Lines($room, [int]$maxW, [int]$tick) {
    # $RoomH lignes de même largeur visible : bordure titrée, bulles, personnages, noms, activités, bordure
    $bc = Rgb (@($room.Rgb | ForEach-Object { [int]($_ * 0.6) }))
    $tc = Rgb $room.Rgb
    $cap = [Math]::Max(1, [int][Math]::Floor(($maxW - 2) / $CellW))
    $mem = @($room.Members)
    $show = if ($mem.Count -gt $cap) { @($mem | Select-Object -First ($cap - 1)) } else { $mem }
    $more = $mem.Count - $show.Count
    $script:LastShown = $show   # personnages réellement dessinés (pour les zones cliquables)
    $cells = $show.Count + $(if ($more) { 1 } else { 0 })
    $title = Cut $room.Title ($maxW - 6)
    $inner = [Math]::Min($maxW - 2, [Math]::Max($title.Length + 4, $cells * $CellW))
    $rows = @(1..12 | ForEach-Object { '' })
    $in = $CellW - 2
    foreach ($m in $show) {
        $isSel = $m.Key -and $m.Key -eq $SelKey
        $pg = $Progress[(Progress-Of $m)]
        # cadre vert épais autour du personnage choisi ; sinon une simple marge
        $fc = SpRgb @(40, 255, 120)
        $lb = if ($isSel) { "$B$fc┃$R" } else { ' ' }
        $cell = @()
        $cell += if ($isSel) { "$B$fc┏$('━' * $in)┓$R" } else { ' ' * $CellW }
        foreach ($bl in (Bubble (Bubble-Text $m.Act ([string]$m.Detail) ([string]$m.Thought) ([string]$m.Task)) $in $tick $m.Seed $pg.Rgb)) { $cell += "$lb$bl$lb" }
        # tête du personnage à la couleur de son avancement
        foreach ($sl in (Sprite $m.Act $tick $pg.Rgb $m.Seed)) { $cell += $lb + (Fit (' ' + $sl) $in) + $lb }
        $nameTxt = if ($isSel) { "$B$fc▶ $(Rgb $m.Rgb)$(Cut $m.Name ($in - 2))$R" } else { "$B$(Rgb $m.Rgb)$(Cut $m.Name $in)$R" }
        $cell += $lb + (Fit $nameTxt $in) + $lb
        $act = if ($SpActs.ContainsKey($m.Act)) { $m.Act } else { 'work' }
        $lab = Sprite-Label $act
        # état d'avancement écrit en couleur (■ EN COURS…), puis l'action en cours
        $tag = "■ $($pg.Tag)"
        if ($act -in 'wait', 'done', 'queue', 'idle', 'look') { $lab = '' }   # déjà dit par l'état
        $det = if ($m.Detail -and $tag.Length + $lab.Length + 4 -lt $in) { " $(Cut ([string]$m.Detail) ($in - 4 - $tag.Length - $lab.Length))" } else { '' }
        $cell += $lb + (Fit "$B$(SpRgb $pg.Rgb)$tag$R $(SpRgb $SpActs[$act].Rgb)$lab$R$Dm$det$R" $in) + $lb
        $cell += if ($isSel) { "$B$fc┗$('━' * $in)┛$R" } else { ' ' * $CellW }
        for ($i = 0; $i -lt 12; $i++) { $rows[$i] += $cell[$i] }
    }
    if ($more) {
        for ($i = 0; $i -lt 12; $i++) { $rows[$i] += Fit $(if ($i -eq 6) { "   $Dm+$more autres$R" } else { '' }) $CellW }
    }
    $out = @("$bc╭─ $R$B$tc$title$R $bc$('─' * [Math]::Max(0, $inner - $title.Length - 3))╮$R")
    foreach ($row in $rows) { $out += "$bc│$R$(Fit $row $inner)$bc│$R" }
    $out += "$bc╰$('─' * $inner)╯$R"
    $out
}

function Render($rooms, [int]$tick) {
    $W = [Math]::Max(20, (ConW) - 1); $Hfull = [Math]::Max(3, (ConH))
    $foot = @(Footer-Lines $W $tick)
    if ($Hfull -lt 8) { $foot = @($foot | Select-Object -Last 1) }    # tout petit panneau : une seule ligne d'aide
    $H = [Math]::Max(2, $Hfull - $foot.Count)
    $L = [Collections.Generic.List[string]]::new()
    $n = ($rooms | ForEach-Object { @($_.Members).Count } | Measure-Object -Sum).Sum
    $busy = @($rooms | ForEach-Object { $_.Members } | Where-Object { $_.Act -notin 'idle', 'wait', 'done', 'look' }).Count
    $L.Add(" $B$(SpRgb @(84, 186, 255))⌂ BUREAU$R  $Dm$n personnage(s) · $busy au travail · $(@($rooms).Count) pièce(s)   $(Get-Date -Format 'HH:mm:ss')$R")
    Clear-Zones
    # pièces rangées de gauche à droite, puis ligne suivante
    $line = @(); $lineW = 0; $hidden = 0; $rowRooms = @()
    $flush = {
        # exécuté avec « . » : modifie les variables de Render
        if ($line.Count) {
            $top = $L.Count
            for ($i = 0; $i -lt $RoomH; $i++) { $L.Add((@($line | ForEach-Object { $_[$i] }) -join ' ')) }
            # zones cliquables : chaque personnage (sa case entière), et le titre de la pièce (1er personnage)
            foreach ($rr in $rowRooms) {
                for ($q = 0; $q -lt $rr.Shown.Count; $q++) {
                    $x1 = $rr.X + 1 + $q * $CellW
                    Add-Zone ($top + 1) ($top + 12) $x1 ($x1 + $CellW - 1) @{ Member = $rr.Shown[$q] }
                }
                if ($rr.Shown.Count) { Add-Zone $top $top $rr.X ($rr.X + $rr.W - 1) @{ Member = $rr.Shown[0] } }
            }
        }
        $line = @(); $lineW = 0; $rowRooms = @()
    }
    $mini = [Collections.Generic.List[object]]::new()   # pièces sans la place d'être dessinées : une ligne chacune
    foreach ($room in $rooms) {
        $rl = Room-Lines $room $W $tick
        $shown = @($LastShown)
        $rw = VisLen $rl[0]
        if ($lineW -and $lineW + 1 + $rw -gt $W) { . $flush }
        # nouvelle rangée sans la place d'une pièce → cette pièce et les suivantes passent en version compacte
        $startsRow = -not $line.Count
        if ($mini.Count -or ($startsRow -and $L.Count + $RoomH -gt $H - 1)) { $mini.Add($room); continue }
        $x = $lineW + $(if ($lineW) { 1 } else { 0 })
        $rowRooms += [pscustomobject]@{ X = $x; W = $rw; Shown = $shown }
        $line += , $rl; $lineW = $x + $rw
    }
    . $flush
    foreach ($room in $mini) {
        if ($L.Count -ge $H - 1) { $hidden++; continue }
        $head = " $B$(Rgb $room.Rgb)$($room.Title)$R  "
        $acc = $head; $sep = '   '
        foreach ($m in @($room.Members)) {
            $ad = $SpActs[$(if ($SpActs.ContainsKey($m.Act)) { $m.Act } else { 'work' })]
            $say = Bubble-Text $m.Act ([string]$m.Detail) ([string]$m.Thought) ([string]$m.Task)
            $nm = if ($m.Key -and $m.Key -eq $SelKey) { "$e[1;38;2;0;0;0;48;2;40;255;120m▶ $(Cut $m.Name 14) $R" } else { "$B$(Cut $m.Name 14)$R" }
            $part = "$(SpRgb $Progress[(Progress-Of $m)].Rgb)●$R $nm $(SpRgb $ad.Rgb)$($ad.Icon) $($ad.Label)$R$(if ($m.Detail) { " $Dm$(Cut ([string]$m.Detail) 16)$R" }) $Dm« $(Cut $say 60) »$R"
            if ($acc -ne $head) { $acc += $sep }
            $x1 = VisLen $acc
            $acc += $part
            Add-Zone $L.Count $L.Count $x1 ((VisLen $acc) - 1) @{ Member = $m }
        }
        $L.Add($acc)
    }
    if ($hidden) {
        # toujours visible : remplace la dernière ligne si l'écran est plein
        if ($L.Count -ge $H - 1) { $hidden++; $L[$L.Count - 1] = " $Dm+ $hidden pièce(s) de plus (Alt+Z pour agrandir le panneau)$R" }
        else { $L.Add(" $Dm+ $hidden pièce(s) de plus (Alt+Z pour agrandir le panneau)$R") }
    }
    while ($L.Count -lt $H - 1) { $L.Add('') }
    foreach ($fl in $foot) { $L.Add($fl) }
    # aides du bas cliquables
    Add-HintZones $L @{ 'Entrée aller à son panneau' = 'Enter'; 'M lui écrire' = 'm'; 'Échap fermer' = 'Escape'
        'Tab/←→ choisir' = 'Tab'; 'Entrée envoyer' = 'Enter'; 'Échap annuler' = 'Escape'; 'Tab : choisir un personnage' = 'Tab' }
    $sb = [Text.StringBuilder]::new(); [void]$sb.Append("$e[H")
    for ($i = 0; $i -lt $Hfull - 1; $i++) {
        $s = if ($i -lt $L.Count) { $L[$i] } else { '' }
        [void]$sb.Append((Fit $s $W)).Append($R).Append("$e[K`n")
    }
    [Console]::Write($sb.ToString())
    $busy
}

[Console]::Write("$e[?25l$e[2J")
Enable-Mouse
try {
    $tick = 0; $rooms = $null; $next = [datetime]::MinValue; $lastW = 0; $lastH = 0
    while ($true) {
        if ((Get-Date) -ge $next) {
            try {
                $rooms = Collect
                # liste à plat des personnages (ordre d'affichage) pour la navigation au clavier
                $script:Flat = @(); $script:RoomOf = @{}
                for ($ri = 0; $ri -lt $rooms.Count; $ri++) { foreach ($mm in @($rooms[$ri].Members)) { if ($mm.Key) { $script:Flat += $mm; $script:RoomOf[$mm.Key] = $ri } } }
                if ($SelKey -and -not $RoomOf.ContainsKey($SelKey)) { $script:SelKey = '' }   # personnage parti
            } catch {}
            $next = (Get-Date).AddSeconds(1.5)
        }
        try { Handle-Keys } catch {}
        if ((ConW) -ne $lastW -or (ConH) -ne $lastH) { [Console]::Write("$e[2J"); $lastW = ConW; $lastH = ConH }
        $busy = 0
        try { $busy = Render $rooms $tick } catch { [Console]::Write("$e[H ✗ $($_.Exception.Message)$e[K") }
        $tick++
        if ($Frames -gt 0 -and $tick -ge $Frames) { break }
        $delay = if ($busy -or $SelKey -or $null -ne $Typing) { $Refresh } else { [Math]::Max($Refresh, 0.4) }
        Start-Sleep -Milliseconds ([int]($delay * 1000))
    }
} finally { Disable-Mouse; [Console]::Write("$R$e[?25h") }

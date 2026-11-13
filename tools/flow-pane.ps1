<#
  flow-pane.ps1 — réorganiser les panneaux d'une session FLOW (appelé par les raccourcis psmux).

    -Move L|R|U|D   échange le panneau avec son voisin de gauche / droite / haut / bas (il garde le focus)
    -Save           enregistre la disposition actuelle dans le profil FLOW de la session
                    (au prochain lancement, les panneaux reviennent dans cet ordre)

  Raccourcis (posés par FLOW au lancement d'un profil) :
    Alt+Maj+flèches     déplacer le panneau actif
    Ctrl+B puis W       enregistrer la disposition dans le profil
    Ctrl+B puis G       menu « Agencer » (aussi au clic droit sur un panneau)
    Ctrl+B puis T       fenêtre Équipe : une demande découpée en tâches, réparties sur les comptes Claude

    -Team           ouvre (ou rejoint) la fenêtre Équipe de la session
#>
param(
    [string]$Sock = 'flow',
    [string]$Target,            # « session:fenêtre.panneau » du panneau actif (fourni par psmux)
    [ValidateSet('L', 'R', 'U', 'D', '')][string]$Move = '',
    [switch]$Save,
    [switch]$Team,
    [string]$AddClaude = ''     # identifiant d'un compte : ajoute un Claude de ce compte dans la fenêtre courante
)
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'flow-common.ps1')
function Say([string]$s) { & psmux -L $Sock display-message $s *> $null }

if (-not $Target) { $Target = (& psmux -L $Sock display-message -p '#{session_name}:#{window_index}.#{pane_index}' | Select-Object -First 1) }
$sess = $Target.Split(':')[0]
$win = $Target.Substring(0, $Target.LastIndexOf('.'))
$cur = [int]$Target.Substring($Target.LastIndexOf('.') + 1)

function Panes {
    @(& psmux -L $Sock list-panes -t $win -F '#{pane_index}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{pane_active}|#{@flow_spec}' | ForEach-Object {
            $f = "$_" -split '\|', 7
            if ($f.Count -ge 6) {
                [pscustomobject]@{ I = [int]$f[0]; X = [int]$f[1]; Y = [int]$f[2]; W = [int]$f[3]; H = [int]$f[4]; Active = $f[5] -eq '1'; Spec = $(if ($f.Count -ge 7) { $f[6] } else { '' }) }
            }
        })
}

if ($Team) {
    # un panneau Équipe existe déjà dans la session (profil Équipe, ou Ctrl+B T déjà fait) : y aller
    foreach ($ln in (& psmux -L $Sock list-panes -s -t $sess -F '#{window_index}.#{pane_index}|#{@flow_spec}')) {
        $f = "$ln" -split '\|', 2
        if ($f.Count -eq 2 -and $f[1] -match '"role"\s*:\s*"team"') {
            & psmux -L $Sock select-window -t "${sess}:$($f[0].Split('.')[0])" *> $null
            & psmux -L $Sock select-pane -t "${sess}:$($f[0])" *> $null
            return
        }
    }
    $cwd = (& psmux -L $Sock display-message -t $sess -p '#{@flow_cwd}' | Select-Object -First 1)
    $accs = (& psmux -L $Sock display-message -t $sess -p '#{@flow_accounts}' | Select-Object -First 1)
    if (-not $cwd -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { Say 'FLOW : dossier du projet inconnu pour cette session (relance le profil)'; return }
    $q = { param($x) "'" + ("$x" -replace "'", "''") + "'" }
    & psmux -L $Sock new-window -t $sess -n dispatch -c $cwd *> $null
    $tgt = "${sess}:dispatch.0"
    for ($k = 0; $k -lt 60; $k++) {
        if (((& psmux -L $Sock capture-pane -p -t $tgt 2>$null) -join '').Trim()) { break }
        Start-Sleep -Milliseconds 100
    }
    & psmux -L $Sock set -p -t $tgt '@flow_role' '⚑ équipe' *> $null
    & psmux -L $Sock set -p -t $tgt '@flow_base' '⚑ équipe' *> $null
    & psmux -L $Sock set -p -t $tgt '@flow_spec' '{"role":"team"}' *> $null
    $cmd = "Clear-Host; pwsh -NoProfile -File $(& $q (Join-Path $PSScriptRoot 'flow-team.ps1')) -Repo $(& $q $cwd) -Sock $Sock -Session $(& $q $sess) -Accounts $(& $q $accs)"
    & psmux -L $Sock send-keys -t $tgt -l $cmd *> $null
    & psmux -L $Sock send-keys -t $tgt Enter *> $null
    return
}

if ($AddClaude) {
    # un Claude de plus, sur le compte choisi, à côté du panneau actif
    $cwd = (& psmux -L $Sock display-message -t $sess -p '#{@flow_cwd}' | Select-Object -First 1)
    $accs = (& psmux -L $Sock display-message -t $sess -p '#{@flow_accounts}' | Select-Object -First 1)
    $ac = $null
    foreach ($ent in ("$accs" -split ';')) {
        $f = $ent -split '\|', 5
        if ($f.Count -ge 4 -and $f[0].Trim() -eq $AddClaude) { $ac = [pscustomobject]@{ Id = $f[0].Trim(); Label = $f[1].Trim(); Dir = $f[3].Trim() } }
    }
    if (-not $ac) { Say "FLOW : compte « $AddClaude » inconnu pour cette session (relance le profil)"; return }
    if (-not $cwd -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { $cwd = (& psmux -L $Sock display-message -t $Target -p '#{pane_current_path}' | Select-Object -First 1) }
    & psmux -L $Sock split-window -h -t $win -c $cwd *> $null
    Start-Sleep -Milliseconds 300
    $idx = (& psmux -L $Sock display-message -t $win -p '#{pane_index}' | Select-Object -First 1)
    $tgt = "$win.$idx"
    for ($k = 0; $k -lt 60; $k++) {
        if (((& psmux -L $Sock capture-pane -p -t $tgt 2>$null) -join '').Trim()) { break }
        Start-Sleep -Milliseconds 100
    }
    $title = "✦ claude · $($ac.Label)"
    & psmux -L $Sock set -p -t $tgt '@flow_role' $title *> $null
    & psmux -L $Sock set -p -t $tgt '@flow_base' $title *> $null
    & psmux -L $Sock set -p -t $tgt '@flow_acct' $ac.Id *> $null
    & psmux -L $Sock set -p -t $tgt '@flow_spec' (ConvertTo-Json -Compress ([pscustomobject]@{ role = 'claude'; account = $ac.Id })) *> $null
    $acctEnv = if ($ac.Dir) { "`$env:CLAUDE_CONFIG_DIR = $(Q $ac.Dir); " } else { 'Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue; ' }
    # dans une session d'équipe, le nouveau Claude a lui aussi toutes les permissions d'avance (comme les autres)
    $team = @(& psmux -L $Sock list-panes -s -t $sess -F '#{@flow_spec}' | Where-Object { $_ -match '"role"\s*:\s*"team"' }).Count -gt 0
    $perm = if ($team) { ' --permission-mode bypassPermissions' } else { '' }
    $cmd = "Set-Location -LiteralPath $(Q $cwd); $(Auth-Strip)${acctEnv}Clear-Host; claude$perm"
    & psmux -L $Sock send-keys -t $tgt -l $cmd *> $null
    & psmux -L $Sock send-keys -t $tgt Enter *> $null
    Say "FLOW : Claude « $($ac.Label) » ajouté"
    return
}

if ($Move) {
    $all = Panes
    $a = $all | Where-Object { $_.I -eq $cur } | Select-Object -First 1
    if (-not $a) { return }
    $ovV = { param($p) [Math]::Min($a.Y + $a.H, $p.Y + $p.H) - [Math]::Max($a.Y, $p.Y) }   # chevauchement vertical
    $ovH = { param($p) [Math]::Min($a.X + $a.W, $p.X + $p.W) - [Math]::Max($a.X, $p.X) }   # chevauchement horizontal
    $cand = switch ($Move) {
        'L' { $all | Where-Object { $_.X + $_.W -le $a.X -and (& $ovV $_) -gt 0 } | Sort-Object @{ e = { $_.X + $_.W }; Descending = $true }, @{ e = { & $ovV $_ }; Descending = $true } }
        'R' { $all | Where-Object { $_.X -ge $a.X + $a.W -and (& $ovV $_) -gt 0 } | Sort-Object @{ e = { $_.X } }, @{ e = { & $ovV $_ }; Descending = $true } }
        'U' { $all | Where-Object { $_.Y + $_.H -le $a.Y -and (& $ovH $_) -gt 0 } | Sort-Object @{ e = { $_.Y + $_.H }; Descending = $true }, @{ e = { & $ovH $_ }; Descending = $true } }
        'D' { $all | Where-Object { $_.Y -ge $a.Y + $a.H -and (& $ovH $_) -gt 0 } | Sort-Object @{ e = { $_.Y } }, @{ e = { & $ovH $_ }; Descending = $true } }
    }
    $n = @($cand) | Select-Object -First 1
    $dirTxt = @{ L = 'à gauche'; R = 'à droite'; U = 'au-dessus'; D = 'en dessous' }[$Move]
    if (-not $n) { Say "FLOW : aucun panneau $dirTxt"; return }
    & psmux -L $Sock swap-pane -s "$win.$($a.I)" -t "$win.$($n.I)" *> $null
    & psmux -L $Sock select-pane -t "$win.$($n.I)" *> $null          # le panneau déplacé garde le focus
    Say "FLOW : panneau déplacé $dirTxt — Ctrl+B puis W pour garder cette disposition"
    return
}

if ($Save) {
    $file = (& psmux -L $Sock display-message -t $sess -p '#{@flow_profile}' | Select-Object -First 1)
    if (-not $file -or -not (Test-Path -LiteralPath $file)) { Say 'FLOW : cette session n''a pas de fichier de profil (lancée avec -Team ?) : rien à enregistrer'; return }
    $all = Panes
    if (-not $all.Count) { return }
    # lignes = panneaux qui commencent à la même hauteur ; largeurs et hauteurs en %
    $rows = foreach ($g in ($all | Group-Object Y | Sort-Object { [int]$_.Name })) {
        $ps = @($g.Group | Sort-Object X)
        $tw = ($ps.W | Measure-Object -Sum).Sum
        $cells = foreach ($p in $ps) {
            $spec = $null
            if ($p.Spec) { try { $spec = $p.Spec | ConvertFrom-Json -ErrorAction Stop } catch {} }
            if (-not $spec) { $spec = [pscustomobject]@{ role = 'shell' } }      # panneau ajouté à la main
            $spec | Add-Member -NotePropertyName width -NotePropertyValue ([int][Math]::Round($p.W / $tw * 100)) -Force
            if ($p.Active) { $spec | Add-Member -NotePropertyName focus -NotePropertyValue $true -Force }
            elseif ($spec.PSObject.Properties['focus']) { $spec.PSObject.Properties.Remove('focus') }
            $spec
        }
        # les panneaux ajoutés automatiquement (un par compte) se réenregistrent en UN seul panneau « perAccount »
        $merged = [Collections.Generic.List[object]]::new()
        foreach ($c in @($cells)) {
            $prev = $merged | Where-Object { $_.perAccount -and $c.perAccount -and $_.role -eq $c.role } | Select-Object -First 1
            if ($prev) { $prev.width = [int]$prev.width + [int]$c.width; continue }
            $merged.Add($c)
        }
        [pscustomobject]@{ height = $ps[0].H; panes = @($merged) }
    }
    $rows = @($rows)
    $th = ($rows.height | Measure-Object -Sum).Sum
    foreach ($r in $rows) { $r.height = [int][Math]::Round($r.height / $th * 100) }
    try {
        $prof = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
        Copy-Item -LiteralPath $file -Destination "$file.bak" -Force          # sauvegarde de l'ancienne disposition
        $prof | Add-Member -NotePropertyName rows -NotePropertyValue $rows -Force
        Write-JsonAtomic $prof $file -Depth 20
        Say "FLOW : disposition enregistrée dans $(Split-Path $file -Leaf) (ancienne version : .bak)"
    } catch { Say "FLOW : impossible d'enregistrer ($($_.Exception.Message))" }
}

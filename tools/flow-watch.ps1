# flow-watch.ps1 - SURVEILLANCE des ouvriers : rien ne doit rester bloqué sans que ce soit visible (chargé avec « . » par flow-team.ps1).
#
# Un ouvrier (un Claude dans un panneau) peut s'arrêter sans bruit : question posée à l'utilisateur, demande de permission,
# « faire confiance à ce dossier ? », limite d'usage atteinte, compte déconnecté, ou simple silence prolongé.
# Toutes les 2 secondes, FLOW lit l'écran de chaque ouvrier et reconnaît ces situations :
#   - ce que FLOW peut régler sans risque seul (confiance dans SA copie de travail) : il le fait et le note ;
#   - tout le reste : un bloc « À TRAITER » en haut de l'écran de travail (bannière animée, alerte avec son, rappel),
#     la ligne de l'ouvrier passe en rouge avec la cause, et le blocage est consigné dans .flow\runs\<équipe>\attentes.md.

$script:Blockers = @{}      # id de tâche → @{ Kind; Text; Since }
$script:WatchSeen = @{}     # id de tâche → @{ Hash; Since } (détection du silence)
$script:SilentMin = 8       # minutes sans le moindre changement d'écran = « silence suspect »

function Classify-Screen([string]$txt) {
    # reconnaît ce que dit l'écran d'un Claude ; $null = rien de bloquant. Kind : confiance | question | permission | limite | connexion
    if (-not $txt) { return $null }
    $flat = (($txt -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' ')
    if ($flat -match 'trust this folder' -and $flat -match 'Accessing workspace') { return @{ Kind = 'confiance'; Text = 'Claude demande s''il peut faire confiance au dossier de travail' } }
    if ($flat -match 'Please run /login|Invalid API key|authentication_error|OAuth token has expired|Not logged in') { return @{ Kind = 'connexion'; Text = 'le compte de cet ouvrier n''est plus connecté (/login)' } }
    if ($flat -match '(usage|rate) limit (reached|exceeded)|You''ve hit your (usage )?limit|limit will reset|Claude usage limit') { return @{ Kind = 'limite'; Text = 'limite d''usage du compte atteinte : l''ouvrier est à l''arrêt jusqu''à la réinitialisation' } }
    if ($flat -match 'Do you want to (proceed|make this edit|create|run|allow)' -and $flat -match '(1\. Yes|❯ 1\.|Yes, and don)') {
        $m = [regex]::Match($flat, 'Do you want to [^?]{0,120}\?'); return @{ Kind = 'permission'; Text = $(if ($m.Success) { $m.Value } else { 'Claude demande une permission' }) }
    }
    if ($flat -match 'Enter to select' -and $flat -match '(↑/↓|Esc to cancel)') {
        # la question = la dernière phrase qui finit par « ? » avant la liste des choix
        $q = @([regex]::Matches($flat, '[^│?]{12,220}\?') | ForEach-Object { $_.Value.Trim() }) | Select-Object -Last 1
        return @{ Kind = 'question'; Text = $(if ($q) { $q } else { 'Claude te pose une question' }) }
    }
    $null
}

function Blocker-Label([string]$kind) {
    switch ($kind) { 'confiance' { 'confiance au dossier' } 'question' { 'pose une question' } 'permission' { 'demande une permission' } 'limite' { 'limite d''usage atteinte' } 'connexion' { 'compte déconnecté' } 'silence' { 'silence prolongé' } default { $kind } }
}

function Watch-Worker($t) {
    # lit l'écran de l'ouvrier ; renvoie le blocage ($null si tout va bien). La confiance dans SA copie est donnée automatiquement.
    if (-not $Psmux -or -not $t.worktree) { return $null }
    $tgt = Find-Pane $t.id; if (-not $tgt) { return $null }
    $txt = (@(& psmux -L $Sock capture-pane -p -t $tgt 2>$null) -join "`n")
    $c = Classify-Screen $txt
    if ($c -and $c.Kind -eq 'confiance') {
        if (Accept-TrustPrompt $t) { Note-Blocker $t @{ Kind = 'confiance'; Text = 'dossier de travail approuvé automatiquement' } $true; return $null }
    }
    if (-not $c) {
        # silence : l'écran n'a pas changé depuis longtemps alors que l'ouvrier est censé travailler
        $h = [string]$txt.GetHashCode()
        if (-not $script:WatchSeen.ContainsKey($t.id) -or $script:WatchSeen[$t.id].Hash -ne $h) { $script:WatchSeen[$t.id] = @{ Hash = $h; Since = Get-Date } }
        elseif ($t.live -eq 'working' -and ((Get-Date) - $script:WatchSeen[$t.id].Since).TotalMinutes -ge $script:SilentMin) {
            $c = @{ Kind = 'silence'; Text = "écran inchangé depuis $([int]((Get-Date) - $script:WatchSeen[$t.id].Since).TotalMinutes) minutes : l'ouvrier est peut-être coincé" }
        }
    } else { $script:WatchSeen.Remove($t.id) }
    if ($c) { Note-Blocker $t $c $false; return $script:Blockers[$t.id] }
    if ($script:Blockers.ContainsKey($t.id)) { Note-Blocker $t $null $false }     # débloqué
    $null
}

function Attentes-File { Join-Path $RunDir 'attentes.md' }

function Note-Blocker($t, $c, [bool]$auto) {
    # tient à jour la liste des blocages et le journal attentes.md (une ligne à chaque changement)
    $had = $script:Blockers.ContainsKey($t.id)
    if (-not $c) {
        if ($had) { $script:Blockers.Remove($t.id); Journal-Attente $t "reprise : plus de blocage" }
        return
    }
    if ($auto) { Journal-Attente $t "réglé par FLOW — $($c.Text)"; return }
    if ($had -and $script:Blockers[$t.id].Kind -eq $c.Kind -and $script:Blockers[$t.id].Text -eq $c.Text) { return }
    $script:Blockers[$t.id] = @{ Kind = $c.Kind; Text = $c.Text; Since = $(if ($had) { $script:Blockers[$t.id].Since } else { Get-Date }) }
    Journal-Attente $t "$(Blocker-Label $c.Kind) — $($c.Text)"
    try { Write-Event 'blocage' @{ tache = $t.id; genre = $c.Kind; texte = $c.Text } } catch {}
}

function Journal-Attente($t, [string]$text) {
    try {
        if (-not $RunDir) { return }
        $f = Attentes-File
        if (-not (Test-Path -LiteralPath $f)) { Set-Content -LiteralPath $f "# Attentes et blocages des ouvriers`n`nChaque ligne : ce qui a arrêté un ouvrier, ou ce que FLOW a réglé tout seul.`n" -Encoding utf8 }
        Add-Content -LiteralPath $f -Value "- $(Get-Date -Format 'HH:mm:ss') · tâche $($t.id) : $text" -Encoding utf8
    } catch {}
}

function Blockers-Summary {
    # une ligne par ouvrier bloqué, pour l'écran de travail : @{ Id; Kind; Text; Mins }
    @($script:Blockers.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Id = $_.Key; Kind = $_.Value.Kind; Text = $_.Value.Text; Mins = [int]((Get-Date) - $_.Value.Since).TotalMinutes } } | Sort-Object Id)
}

# flow-hooks.ps1 - installation des hooks de Claude Code dans un projet (chargé avec « . » par flow-team.ps1).
#
# Les hooks s'inscrivent dans <dossier>\.claude\settings.local.json (réglages locaux de Claude Code : non commités, ils contiennent un chemin propre à
# cette machine). L'installation FUSIONNE : les autres réglages et les autres hooks de l'utilisateur ne sont jamais touchés ; seules les entrées de FLOW
# (reconnues à « flow-hook.ps1 » dans la commande) sont ajoutées, remplacées ou retirées. Le script appelé est tools\flow-hook.ps1.
#   SessionStart       injecte feuille de route, règles décidées et pièges dans le contexte
#   UserPromptSubmit   repère décisions, interdictions et préférences dans les messages de l'utilisateur → CANDIDATS (.flow\candidats\)
#   PreToolUse         refuse l'écriture dans les chemins protégés (seulement s'il y en a ; marche aussi en mode bypassPermissions)
#   Stop               signale des fichiers modifiés sans mise à jour de memoire\
#   PreCompact         note l'état de travail avant une compaction du contexte
# Jamais de décision à la place de l'utilisateur : les hooks déposent des candidats, rien d'autre ; le scribe ou le tri les examine.

$HookEvents = @('SessionStart', 'UserPromptSubmit', 'Stop', 'PreCompact')
$HookWriteTools = 'Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell'

function Hook-Script { Join-Path $PSScriptRoot 'flow-hook.ps1' }

function Hook-Command([string]$Event, [string]$Project, [string]$Root) {
    foreach ($p in @($Project, $Root, (Hook-Script))) { if ($p -match '["`$]') { throw "chemin non pris en charge par les hooks (guillemet, `$ ou accent grave) : $p" } }
    "pwsh -NoProfile -File `"$(Hook-Script)`" -Event $Event -Project `"$Project`" -Root `"$Root`""
}

function Is-FlowHook($entry) {
    foreach ($h in @($entry.hooks)) { if ("$($h.command)" -match 'flow-hook\.ps1') { return $true } }
    $false
}

function Read-LocalSettings([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return [ordered]@{} }
    $s = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($null -eq $s) { return [ordered]@{} }
    $s
}

function Hooks-File([string]$Root) { Join-Path $Root '.claude\settings.local.json' }

function Install-FlowHooks {
    # fusionne les hooks de FLOW dans les réglages locaux de $Root ; renvoie $true si le fichier a changé
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Project, [string[]]$Protected = @())
    $file = Hooks-File $Root
    $s = Read-LocalSettings $file                       # une erreur de lecture arrête tout : on ne réécrit jamais un fichier qu'on n'a pas compris
    if (-not $s.Contains('hooks') -or $null -eq $s['hooks']) { $s['hooks'] = [ordered]@{} }
    foreach ($ev in @($s['hooks'].Keys)) {
        $keep = @(@($s['hooks'][$ev]) | Where-Object { -not (Is-FlowHook $_) })
        if ($keep.Count) { $s['hooks'][$ev] = $keep } else { $s['hooks'].Remove($ev) }
    }
    $add = { param($ev, $matcher)
        $entry = [ordered]@{}
        if ($matcher) { $entry['matcher'] = $matcher }
        $entry['hooks'] = @([ordered]@{ type = 'command'; command = (Hook-Command $ev $Project $Root) })
        $s['hooks'][$ev] = @(@($s['hooks'][$ev]) + $entry | Where-Object { $_ })
    }
    foreach ($ev in $HookEvents) { & $add $ev $null }
    if (@($Protected | Where-Object { $_ }).Count) { & $add 'PreToolUse' $HookWriteTools }
    $new = $s | ConvertTo-Json -Depth 20
    $old = if (Test-Path -LiteralPath $file) { (Get-Content -LiteralPath $file -Raw -Encoding utf8).Trim() } else { '' }
    if ($old -eq $new.Trim()) { return $false }
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    Write-TextAtomic -Path $file -Text $new -Backup:(Test-Path -LiteralPath $file)
    $true
}

function Uninstall-FlowHooks {
    # retire uniquement les entrées de FLOW ; supprime le fichier s'il ne reste rien d'autre
    param([Parameter(Mandatory)][string]$Root)
    $file = Hooks-File $Root
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    $s = Read-LocalSettings $file
    if ($s.Contains('hooks') -and $null -ne $s['hooks']) {
        foreach ($ev in @($s['hooks'].Keys)) {
            $keep = @(@($s['hooks'][$ev]) | Where-Object { -not (Is-FlowHook $_) })
            if ($keep.Count) { $s['hooks'][$ev] = $keep } else { $s['hooks'].Remove($ev) }
        }
        if (-not $s['hooks'].Count) { $s.Remove('hooks') }
    }
    if ($s.Count) { Write-TextAtomic -Path $file -Text ($s | ConvertTo-Json -Depth 20) -Backup } else { Remove-Item -LiteralPath $file -Force }
    $true
}

function Hooks-Installed([string]$Root) {
    try { $s = Read-LocalSettings (Hooks-File $Root) } catch { return $false }
    if (-not $s.Contains('hooks') -or $null -eq $s['hooks']) { return $false }
    foreach ($ev in $s['hooks'].Keys) { if (@(@($s['hooks'][$ev]) | Where-Object { Is-FlowHook $_ }).Count) { return $true } }
    $false
}

function Exclude-Local {
    # ni les réglages locaux de Claude Code ni les candidats ne sont commités (fichier d'exclusion partagé avec les copies de travail)
    $common = (Git-In $RepoRoot @('rev-parse', '--git-common-dir') | Select-Object -First 1)
    if ($GitCode -ne 0 -or -not $common) { return }
    $common = "$common".Trim()
    if (-not [IO.Path]::IsPathRooted($common)) { $common = Join-Path $RepoRoot $common }
    $ex = Join-Path $common 'info\exclude'
    New-Item -ItemType Directory -Force (Split-Path $ex) | Out-Null
    $cur = if (Test-Path -LiteralPath $ex) { Get-Content -LiteralPath $ex -Raw } else { '' }
    foreach ($line in '.claude/settings.local.json', '.flow/candidats/') {
        if ($cur -notmatch "(?m)^$([regex]::Escape($line))\s*$") { Add-Content -LiteralPath $ex "`n$line" }
    }
}

function Project-Hook-Targets {
    # les dossiers où les hooks doivent être : le projet (sessions hors équipe, Claude des panneaux) et les copies de travail des ouvriers
    $t = @($RepoRoot)
    if ($State) { $t += @(@($State.tasks) | Where-Object { $_.worktree -and (Test-Path -LiteralPath $_.worktree) } | ForEach-Object { $_.worktree }) }
    $t
}

function Sync-Hooks {
    # remet les hooks à jour si le projet les a activés (dossier de FLOW déplacé, chemins protégés changés) ; ne gêne jamais
    if (-not $RepoRoot -or -not $Cfg -or $Cfg.hooks -ne $true) { return $false }
    try { [void](Install-FlowHooks -Root $RepoRoot -Project $RepoRoot -Protected @($Cfg.protectedPaths)); $true } catch { Write-FlowLog "hooks : mise à jour impossible dans $RepoRoot : $($_.Exception.Message)" 'ERREUR'; $false }
}

function Set-ProjectHooks([bool]$On) {
    # active ou désactive les hooks du projet (et de ses copies de travail en cours) ; le choix est retenu dans .flow\config.json
    $Cfg | Add-Member -NotePropertyName hooks -NotePropertyValue $On -Force
    Save-ProjectConfig
    $errors = @()
    foreach ($d in @(Project-Hook-Targets)) {
        try { if ($On) { [void](Install-FlowHooks -Root $d -Project $RepoRoot -Protected @($Cfg.protectedPaths)) } else { [void](Uninstall-FlowHooks -Root $d) } }
        catch { $errors += "$d : $($_.Exception.Message)" }
    }
    if ($On) { Exclude-Local }
    Write-Event 'hooks' @{ actifs = $On; erreurs = @($errors).Count }
    foreach ($m in $errors) { Write-FlowLog "hooks : $m" 'ERREUR' }
    @($errors)
}

# ───────────────────────── les candidats déposés par les hooks ─────────────────────────
function Candidates-File { Join-Path $RepoRoot '.flow\candidats\candidats.jsonl' }

function Read-Candidates {
    $f = Candidates-File
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    @(Get-Content -LiteralPath $f -Encoding utf8 | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
}

function Candidates-Block([int]$Max = 30) {
    # pour le scribe : ce que les hooks ont repéré, à confirmer avant de l'écrire dans la mémoire
    $c = @(Read-Candidates | Select-Object -First $Max)
    if (-not $c.Count) { return '' }
    $lines = @($c | ForEach-Object { "- [$($_.genre)] $(("$($_.texte)" -replace '\s+', ' ').Trim()) ($(([datetime]$_.t).ToString('dd/MM HH:mm')))" })
    "`nCANDIDATS RECUEILLIS PAR LES HOOKS (propos de l'utilisateur et alertes, repérés automatiquement ; beaucoup sont du bruit : n'écris dans decisions.md ou pieges.md que ce qui est clairement une décision ou un piège, et ignore le reste) :`n$($lines -join "`n")`n"
}

function Consume-Candidates([int]$Count) {
    # les $Count premiers candidats ont été examinés : ils vont dans archives\ (jamais supprimés) ; ceux arrivés entretemps restent
    $f = Candidates-File
    if ($Count -le 0 -or -not (Test-Path -LiteralPath $f)) { return }
    $all = @(Get-Content -LiteralPath $f -Encoding utf8 | Where-Object { $_.Trim() })
    $done = @($all | Select-Object -First $Count)
    $rest = @($all | Select-Object -Skip $Count)
    $arch = Join-Path (Split-Path $f) 'archives'
    New-Item -ItemType Directory -Force $arch | Out-Null
    Add-Content -LiteralPath (Join-Path $arch "$(Get-Date -Format 'yyyyMM').jsonl") -Value $done -Encoding utf8
    Write-TextAtomic -Path $f -Text $(if ($rest.Count) { ($rest -join "`n") + "`n" } else { '' })
}

function Hooks-Summary-Lines {
    $pr = @(@($Cfg.protectedPaths) | Where-Object { $_ })
    @(
        "  $B Début de session$R   injecte la feuille de route, les règles décidées et les pièges déjà rencontrés",
        "  $B Tes messages$R       repère décisions, interdictions et préférences → candidats pour la mémoire (jamais écrits sans examen)",
        "  $B Avant une écriture$R $(if ($pr.Count) { "refuse de modifier : $($pr -join ', ')" } else { "$Dm(inactif : aucun chemin protégé dans le profil du projet)$R" })",
        "  $B Fin de tour$R        signale des fichiers modifiés sans mise à jour de la mémoire",
        "  $B Avant compaction$R   note l'état de travail"
    )
}

function Mode-Hooks {
    # écran d'explication, d'activation et de désactivation des hooks du projet
    $msg = ''
    Cls
    while ($true) {
        $on = ($Cfg.hooks -eq $true)
        $L = [Collections.Generic.List[string]]::new()
        $L.Add(''); $L.Add("  $(Grad '⚑ HOOKS — le projet s''enrichit en travaillant' 0.1)   $B$(Split-Path $RepoRoot -Leaf)$R")
        $L.Add("  $(if ($on) { "$Ok✓ actifs$R $Dm(.claude\settings.local.json du projet et des copies de travail)$R" } else { "$Dm désactivés$R" })")
        $L.Add('')
        foreach ($x in @(Hooks-Summary-Lines)) { $L.Add($x) }
        $L.Add('')
        $L.Add("  $Dm Ce sont des hooks de Claude Code : ils agissent dans TOUTES les sessions Claude de ce dossier, pas seulement dans FLOW.$R")
        $L.Add("  $Dm Ils ne font jamais appel à Claude, ne bloquent jamais une session par erreur, et ne modifient ni la mémoire ni les skills.$R")
        $L.Add("  $Dm Tes autres réglages et hooks ne sont jamais touchés (seules les entrées de FLOW sont ajoutées ou retirées).$R")
        $L.Add('')
        $L.Add((Keys @('Entrée', $(if ($on) { 'désactiver' } else { 'activer' }), 'Échap', 'retour')))
        if ($msg) { $L.Add("  $msg") }
        Show-Frame $L
        $k = Read-KeyOrHint
        if ($k.Key -eq 'Escape') { return $msg }
        if ($k.Key -eq 'Enter') {
            $errs = @(Set-ProjectHooks (-not $on))
            $msg = if ($errs.Count) { "$Err✗ $($errs[0])$R" } elseif (-not $on) { "$Ok✓ hooks activés$R" } else { "$Ok✓ hooks désactivés (tes autres réglages sont intacts)$R" }
        }
    }
}

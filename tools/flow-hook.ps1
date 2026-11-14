# flow-hook.ps1 - le hook de Claude Code branché par FLOW dans un projet (voir tools\flow-hooks.ps1 pour l'installation).
# Appelé par Claude Code à chaque événement : pwsh -File flow-hook.ps1 -Event <nom> -Project <dossier du projet> -Root <dossier de la session>
# L'événement arrive en JSON sur l'entrée standard. RÈGLES : autonome et rapide ; ne bloque JAMAIS une session par erreur (toute erreur = on laisse faire,
# code de sortie 0) ; n'écrit jamais dans la mémoire ni dans les skills : il dépose des CANDIDATS dans <projet>\.flow\candidats\ ; refuse seulement
# l'écriture dans les chemins protégés du projet (.flow\config.json, réglage protectedPaths) ; n'appelle jamais Claude.
param([string]$Event, [string]$Project, [string]$Root)

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $raw = [Console]::In.ReadToEnd()
    if (-not $Project) { exit 0 }
    if (-not $Root) { $Root = $Project }
    $j = $null; try { $j = $raw | ConvertFrom-Json -ErrorAction Stop } catch { exit 0 }
    $tools = $PSScriptRoot
    . (Join-Path $tools 'flow-common.ps1')
    . (Join-Path $tools 'flow-profile.ps1')      # Redact-Text
    $RepoRoot = $Project
    . (Join-Path $tools 'flow-workflow.ps1')
} catch { exit 0 }

function Add-Candidate($obj) {
    # un candidat = quelque chose qui MÉRITE peut-être d'entrer dans la mémoire ; le scribe ou le tri décide
    try {
        $dir = Join-Path $Project '.flow\candidats'
        New-Item -ItemType Directory -Force $dir | Out-Null
        $o = [ordered]@{ t = (Get-Date).ToString('o'); session = "$($j.session_id)"; projet = (Split-Path $Project -Leaf) }
        foreach ($k in $obj.Keys) { $o[$k] = $obj[$k] }
        Add-Content -LiteralPath (Join-Path $dir 'candidats.jsonl') -Value (Redact-Text ($o | ConvertTo-Json -Compress -Depth 6)) -Encoding utf8
    } catch {}
}

function Recent-Candidate([string]$genre) {
    # déjà signalé dans cette session ? (évite d'écrire la même alerte à chaque tour)
    try {
        $f = Join-Path $Project '.flow\candidats\candidats.jsonl'
        if (-not (Test-Path -LiteralPath $f)) { return $false }
        foreach ($l in @(Get-Content -LiteralPath $f -Tail 40 -Encoding utf8)) {
            $c = $null; try { $c = $l | ConvertFrom-Json } catch { continue }
            if ($c.session -eq "$($j.session_id)" -and $c.genre -eq $genre) { return $true }
        }
    } catch {}
    $false
}

function Protected-List {
    try {
        $c = Get-Content -LiteralPath (Join-Path $Project '.flow\config.json') -Raw -Encoding utf8 | ConvertFrom-Json
        @(@($c.protectedPaths) | Where-Object { "$_".Trim() } | ForEach-Object { ("$_" -replace '\\', '/').Trim().TrimEnd('/') })
    } catch { @() }
}

function Rel-To-Root([string]$p) {
    # chemin relatif au dossier de la session (avec /), ou $null s'il est en dehors
    if (-not "$p".Trim()) { return $null }
    try {
        $base = if ($j.cwd) { "$($j.cwd)" } else { $Root }
        $full = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $base $p }))
        $r = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
        if ($full.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { return '' }
        if ($full.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($r.Length + 1).Replace('\', '/') }
    } catch {}
    $null
}

function Hit-Protected([string]$rel, $pats) {
    foreach ($pt in @($pats)) { if ($rel -ieq $pt -or $rel -ilike "$pt/*" -or $rel -ilike $pt) { return $pt } }
    $null
}

function Deny([string]$why) {
    @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $why } } | ConvertTo-Json -Compress -Depth 5
}

$MUTATE = '(^|[\s;&|(])(rm|rmdir|del|erase|mv|move|ren|rename|cp|copy|xcopy|robocopy|truncate|shred|tee|remove-item|move-item|copy-item|rename-item|set-content|add-content|out-file|clear-content|new-item|git\s+(checkout|restore|clean|reset|rm|mv)|sed\s+-i)(\s|$)'

try {
    switch ($Event) {
        'SessionStart' {
            if (-not (Wf-Validated)) { break }
            $L = [Collections.Generic.List[string]]::new()
            $L.Add('FLOW — workflow de ce projet (fait foi : décisions de l''utilisateur, ne les remets pas en cause)')
            $sum = Roadmap-Summary
            if ($sum) { $L.Add("Feuille de route : $sum") }
            $cur = Current-Step
            if ($cur) { $L.Add("Étape à poursuivre : $($cur.id) — $($cur.titre) (but : $($cur.but))") }
            $cf = Wf-File 'CAHIER.md'
            if (Test-Path -LiteralPath $cf) {
                $cahier = Get-Content -LiteralPath $cf -Raw -Encoding utf8
                foreach ($sec in 'Règles décidées', 'Interdits') {
                    $m = [regex]::Match($cahier, "(?s)## $sec\r?\n(.*?)(?=\r?\n## |\z)")
                    $items = @($m.Groups[1].Value -split "\r?\n" | Where-Object { $_ -match '^- ' -and $_ -notmatch '^- \(' } | Select-Object -First 8)
                    if ($items.Count) { $L.Add("${sec} :"); foreach ($x in $items) { $L.Add($x) } }
                }
            }
            $pf = Join-Path $Project 'memoire\pieges.md'
            if (Test-Path -LiteralPath $pf) {
                $pg = @(Get-Content -LiteralPath $pf -Encoding utf8 | Where-Object { $_ -match '^- ' -and $_ -notmatch '^- \(' } | Select-Object -First 6)
                if ($pg.Count) { $L.Add('Pièges déjà rencontrés (memoire\pieges.md) :'); foreach ($x in $pg) { $L.Add($x) } }
            }
            $L.Add('Si tu découvres une décision, un piège ou une préférence importante, dis-le clairement dans ta réponse : FLOW la note comme candidate pour la mémoire du projet.')
            $ctx = ($L -join "`n"); if ($ctx.Length -gt 2400) { $ctx = $ctx.Substring(0, 2400) + '…' }
            @{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $ctx } } | ConvertTo-Json -Compress -Depth 5
        }
        'UserPromptSubmit' {
            $p = "$($j.prompt)".Trim()
            # les messages envoyés par FLOW lui-même et la consigne initiale d'un ouvrier ne sont pas des propos de l'utilisateur
            if ($p.Length -lt 12 -or $p.StartsWith('[FLOW]') -or $p.StartsWith('Lis le fichier') -or $p.StartsWith('/')) { break }
            $genre = $null
            if ($p -match "(?i)\b(jamais|ne\s+(fais|fait|faites|touche|touchez|modifie|supprime)\s+pas|interdit|évite|évitez|never|don'?t|do not)\b") { $genre = 'interdiction' }
            elseif ($p -match "(?i)(décid|c'est la règle|règle\s*:|désormais|dorénavant|à partir de maintenant|from now on|on garde|on a choisi)") { $genre = 'decision' }
            elseif ($p -match "(?i)\b(toujours|je préfère|je préfèrerais|je veux que|je ne veux pas|n'oublie pas|retiens|souviens-toi|always|i prefer|remember)\b") { $genre = 'preference' }
            if ($genre) { Add-Candidate ([ordered]@{ type = 'candidat'; genre = $genre; texte = $(if ($p.Length -gt 600) { $p.Substring(0, 600) + '…' } else { $p }); source = 'message' }) }
        }
        'PreToolUse' {
            $pats = @(Protected-List)
            if (-not $pats.Count) { break }
            $tool = "$($j.tool_name)"
            $ti = $j.tool_input
            if ($tool -in 'Write', 'Edit', 'MultiEdit', 'NotebookEdit') {
                $rel = Rel-To-Root $(if ($ti.file_path) { $ti.file_path } else { $ti.notebook_path })
                if ($null -ne $rel) {
                    $hit = Hit-Protected $rel $pats
                    if ($hit) { Add-Candidate ([ordered]@{ type = 'refus'; genre = 'chemin_protege'; texte = "écriture refusée : $rel (protégé : $hit)"; outil = $tool }); Deny "FLOW : « $rel » est protégé par le projet ($hit). Ne le modifie pas ; si c'est vraiment nécessaire, demande à l'utilisateur de lever la protection (profil du projet, F2)."; break }
                }
            }
            elseif ($tool -in 'Bash', 'PowerShell') {
                $cmd = "$($ti.command)"
                $low = ($cmd -replace '\\', '/')
                if ($low -match $MUTATE -or $low -match '>>?') {
                    foreach ($pt in $pats) {
                        if ($pt -match '[\*\?\[]') { continue }
                        $esc = [regex]::Escape($pt)
                        $writes = ($low -match $MUTATE -and $low -imatch $esc) -or ($low -imatch ">>?\s*[""']?[^\s""']*$esc")
                        if ($writes) { Add-Candidate ([ordered]@{ type = 'refus'; genre = 'chemin_protege'; texte = "commande refusée (touche $pt) : $($cmd.Substring(0, [Math]::Min(200, $cmd.Length)))"; outil = $tool }); Deny "FLOW : cette commande modifierait « $pt », protégé par le projet. Ne la lance pas ; demande à l'utilisateur de lever la protection si c'est nécessaire."; break }
                    }
                }
            }
        }
        'Stop' {
            if (-not (Test-Path -LiteralPath (Join-Path $Project 'memoire\INDEX.md'))) { break }
            if (Recent-Candidate 'oubli_memoire') { break }
            $st = @(& git -C $Root status --porcelain 2>$null | Where-Object { $_ })
            $files = @($st | ForEach-Object { ($_.Substring(3).Trim('"') -replace '\\', '/') } | Where-Object { $_ -notmatch '^(\.flow|\.claude)/' })
            if (-not $files.Count) { break }
            if (@($files | Where-Object { $_ -like 'memoire/*' }).Count) { break }
            Add-Candidate ([ordered]@{ type = 'candidat'; genre = 'oubli_memoire'; texte = "$($files.Count) fichier(s) modifié(s) sans mise à jour de memoire\ : $(($files | Select-Object -First 6) -join ', ')"; source = 'fin de tour' })
        }
        'PreCompact' {
            $files = @(& git -C $Root status --porcelain 2>$null | Where-Object { $_ } | ForEach-Object { ($_.Substring(3).Trim('"') -replace '\\', '/') } | Where-Object { $_ -notmatch '^(\.flow|\.claude)/' } | Select-Object -First 12)
            $cur = if (Wf-Validated) { Current-Step } else { $null }
            Add-Candidate ([ordered]@{ type = 'candidat'; genre = 'etat_compaction'; texte = "contexte compacté ; étape : $(if ($cur) { "$($cur.id) $($cur.titre)" } else { 'aucune' }) ; fichiers en cours : $($files -join ', ')"; source = 'avant compaction' })
        }
    }
} catch { }
exit 0

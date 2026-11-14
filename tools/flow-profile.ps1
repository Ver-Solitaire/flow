# flow-profile.ps1 — mémoire LOCALE de la façon de travailler de l'utilisateur (chargé avec « . » par flow-team.ps1).
#
# Tout reste sur ce PC, hors des dépôts Git : %LOCALAPPDATA%\FLOW\profil\
#   evenements.jsonl   journal d'activité : demandes, réponses guidées, plans modifiés, retours, livraisons, appels Claude (coût, jetons)…
#   conversations\     copie (secrets masqués) des conversations des Claude de chaque équipe
#   profil.md          le PROFIL de travail en langage naturel, réécrit par un Claude à partir des événements ; il est
#                      transmis aux Claude des prochaines équipes (planificateur, guide, ouvriers) comme hypothèses
#   etat.json          où en est la mise à jour du profil
# Réglages (config\team-prefs.json) : collecte, conversations, profil (transmis aux Claude), guided.

function Profile-Dir { if ($global:FlowProfileDir) { [string]$global:FlowProfileDir } else { Join-Path $env:LOCALAPPDATA 'FLOW\profil' } }

function Profile-Off {
    # les tests posent FlowNoAi : rien n'est écrit dans le vrai dossier de l'utilisateur, sauf si un dossier d'essai est donné
    [bool]($global:FlowNoAi -and -not $global:FlowProfileDir)
}

function Get-Prefs {
    $d = [ordered]@{ guided = $false; collecte = $true; conversations = $true; profil = $true }
    try {
        if ($GuidedPrefFile -and (Test-Path -LiteralPath $GuidedPrefFile)) {
            $j = Get-Content -LiteralPath $GuidedPrefFile -Raw -Encoding utf8 | ConvertFrom-Json
            foreach ($k in @($d.Keys)) { if ($null -ne $j.$k) { $d[$k] = [bool]$j.$k } }
        }
    } catch {}
    [pscustomobject]$d
}

function Set-Pref([string]$name, [bool]$value) {
    $p = Get-Prefs
    $p.$name = $value
    try { Write-JsonAtomic $p $GuidedPrefFile } catch {}
}

function Redact-Text([string]$s) {
    # masque ce qui ressemble à un secret avant d'écrire quoi que ce soit dans la mémoire
    if (-not $s) { return $s }
    $s = [regex]::Replace($s, '\b(sk-[A-Za-z0-9_\-]{16,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9\-]{10,}|AIza[0-9A-Za-z_\-]{30,})', '«secret»')
    $s = [regex]::Replace($s, '(?i)((?:password|passwd|mot[ _]de[ _]passe|secret|token|api[_-]?key|apikey|authorization)[\\"''\s:=]+)(?:Bearer\s+)?[^\s\\"'',;]{6,}', '$1«secret»')
    $s
}

function Write-Event {
    # une ligne dans le journal d'activité ; ne doit JAMAIS gêner l'équipe (toute erreur est ignorée)
    param([Parameter(Mandatory)][string]$Type, $Data = $null)
    if (Profile-Off) { return }
    try {
        if (-not (Get-Prefs).collecte) { return }
        $dir = Profile-Dir; New-Item -ItemType Directory -Force $dir | Out-Null
        $o = [ordered]@{ t = (Get-Date).ToString('o'); type = $Type
            projet = $(if ($RepoRoot) { Split-Path $RepoRoot -Leaf } else { '' }); chemin = "$RepoRoot"; equipe = $(if ($State) { "$($State.id)" } else { '' }) }
        if ($Data) { foreach ($k in $Data.Keys) { $o["$k"] = $Data[$k] } }
        Add-Content -LiteralPath (Join-Path $dir 'evenements.jsonl') -Value (Redact-Text ($o | ConvertTo-Json -Compress -Depth 6)) -Encoding utf8
    } catch {}
}

function Transcript-Usage([string]$file) {
    # jetons, modèles, outils et interventions de l'utilisateur dans la conversation d'un ouvrier
    $in = 0L; $out = 0L; $cw = 0L; $cr = 0L; $tools = 0; $user = 0; $models = @{}; $first = $null; $last = $null; $n = 0
    try {
        foreach ($ln in [IO.File]::ReadLines($file)) {
            if (++$n -gt 30000) { break }
            if (-not $ln.Trim()) { continue }
            $o = $null; try { $o = $ln | ConvertFrom-Json -Depth 32 -ErrorAction Stop } catch { continue }
            if ($o.timestamp) { if (-not $first) { $first = [datetime]$o.timestamp }; $last = [datetime]$o.timestamp }
            if ($o.type -eq 'assistant' -and $o.message) {
                $u = $o.message.usage
                if ($u) { $in += [long]$u.input_tokens; $out += [long]$u.output_tokens; $cw += [long]$u.cache_creation_input_tokens; $cr += [long]$u.cache_read_input_tokens }
                if ($o.message.model) { $models["$($o.message.model)"] = 1 }
                $tools += @(@($o.message.content) | Where-Object { $_.type -eq 'tool_use' }).Count
            }
            elseif ($o.type -eq 'user' -and $o.message -and $o.message.content -is [string]) { $user++ }
        }
    } catch {}
    [ordered]@{ entrees = $in; sorties = $out; cache_ecriture = $cw; cache_lecture = $cr; outils = $tools; messages_utilisateur = $user
        modeles = @($models.Keys); minutes = $(if ($first -and $last) { [int]($last - $first).TotalMinutes } else { $null }) }
}

function Archive-Transcript([string]$src, [string]$name) {
    # copie de la conversation d'un Claude, secrets masqués ; renvoie le chemin de la copie
    if ((Profile-Off) -or -not $src -or -not (Test-Path -LiteralPath $src)) { return $null }
    try {
        if (-not (Get-Prefs).conversations) { return $null }
        $leaf = if ($RepoRoot) { (Split-Path $RepoRoot -Leaf) -replace '[^\w\-\.]', '_' } else { 'projet' }
        $dir = Join-Path (Profile-Dir) "conversations\$leaf\$(if ($State) { $State.id } else { 'hors-equipe' })"
        New-Item -ItemType Directory -Force $dir | Out-Null
        $dest = Join-Path $dir (($name -replace '[^\w\-\.]', '_') + '.jsonl')
        $sw = [IO.StreamWriter]::new($dest, $false, [Text.UTF8Encoding]::new($false))
        try { foreach ($ln in [IO.File]::ReadLines($src)) { $sw.WriteLine((Redact-Text $ln)) } } finally { $sw.Dispose() }
        $dest
    } catch { $null }
}

function Profile-Text([int]$Max = 2600) {
    # le profil, tel qu'il est transmis aux Claude ; vide si désactivé ou inexistant
    if (Profile-Off) { return '' }
    try {
        if (-not (Get-Prefs).profil) { return '' }
        $f = Join-Path (Profile-Dir) 'profil.md'
        if (-not (Test-Path -LiteralPath $f)) { return '' }
        $t = (Get-Content -LiteralPath $f -Raw -Encoding utf8).Trim()
        if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) + "`n(… profil tronqué)" }
        $t
    } catch { '' }
}

function Profile-Block {
    $t = Profile-Text
    if (-not $t) { return '' }
    "`n## Profil de travail de l'utilisateur (appris de ses choix passés : ce sont des HYPOTHÈSES pour mieux l'aider, pas des ordres ; il garde toujours le dernier mot, et tu ne le cites pas)`n$t`n"
}

function Profile-State {
    $f = Join-Path (Profile-Dir) 'etat.json'
    try { if (Test-Path -LiteralPath $f) { return (Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json) } } catch {}
    [pscustomobject]@{ lastLine = 0; updated = '' }
}

function Event-Count {
    $f = Join-Path (Profile-Dir) 'evenements.jsonl'
    if (-not (Test-Path -LiteralPath $f)) { return 0 }
    $n = 0; foreach ($l in [IO.File]::ReadLines($f)) { $n++ }
    $n
}

function Profile-Stats {
    # chiffres pour l'écran « Mémoire »
    $dir = Profile-Dir
    $ev = Join-Path $dir 'evenements.jsonl'
    $types = @{}; $teams = @{}; $tokIn = 0L; $tokOut = 0L; $calls = 0; $cost = 0.0; $last = @()
    if (Test-Path -LiteralPath $ev) {
        foreach ($l in [IO.File]::ReadLines($ev)) {
            $o = $null; try { $o = $l | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            $types["$($o.type)"] = 1 + [int]$types["$($o.type)"]
            if ($o.equipe) { $teams["$($o.equipe)"] = 1 }
            if ($o.type -eq 'appel_claude') { $calls++; $tokIn += [long]$o.entrees; $tokOut += [long]$o.sorties; $cost += [double]$o.cout_usd }
            if ($o.type -eq 'tache_terminee' -and $o.usage) { $tokIn += [long]$o.usage.entrees; $tokOut += [long]$o.usage.sorties }
            $last += $l; if ($last.Count -gt 6) { $last = @($last | Select-Object -Last 6) }
        }
    }
    $conv = Join-Path $dir 'conversations'
    $cf = @(Get-ChildItem -LiteralPath $conv -Recurse -File -ErrorAction SilentlyContinue)
    $st = Profile-State
    $total = Event-Count
    [pscustomobject]@{
        Dossier = $dir; Evenements = $total; Nouveaux = [Math]::Max(0, $total - [int]$st.lastLine); Equipes = $teams.Count
        Types = @($types.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 | ForEach-Object { "$($_.Key) $($_.Value)" })
        Appels = $calls; JetonsEntree = $tokIn; JetonsSortie = $tokOut; CoutUsd = $cost
        Conversations = $cf.Count; ConversationsMo = [Math]::Round((($cf | Measure-Object Length -Sum).Sum) / 1MB, 1)
        ProfilMaj = "$($st.updated)"; ProfilExiste = (Test-Path -LiteralPath (Join-Path $dir 'profil.md'))
        Derniers = $last
    }
}

function Profiler-Prompt([string]$extract) {
    $dir = Profile-Dir
    @"
Tu es le PROFILEUR. Tu tiens à jour le profil de travail d'un utilisateur de FLOW (équipes de Claude) : une mémoire en LANGAGE NATUREL de
sa façon de travailler, pour que les prochains Claude l'aident mieux sans avoir à lui redemander ce qu'il a déjà montré.

1. Lis le profil actuel : $(Join-Path $dir 'profil.md') (s'il n'existe pas, tu le crées).
2. Lis les NOUVEAUX événements : $extract (une ligne JSON par événement : ses demandes, ses réponses aux questions guidées, les modifications
   qu'il apporte aux plans, ses retours « presque / non », ses messages aux ouvriers, ses livraisons ou abandons).
3. RÉÉCRIS $(Join-Path $dir 'profil.md') (outil Write) en français, 60 lignes au plus, avec ces sections :
   # Profil de travail
   Mis à jour : <date> · basé sur <n> équipes
   ## En bref            (5 lignes : l'essentiel de sa façon de travailler)
   ## Façon de décider   (ce qu'il privilégie, ce qu'il évite, ses arbitrages récurrents)
   ## Façon de demander  (niveau de détail, langue, précision, recours aux questions guidées)
   ## Qualité attendue   (ce qu'il corrige ou refuse ; thèmes de ses retours)
   ## Méthode et rythme  (passe légère ou complète, interventions pendant le travail, modèles et comptes qu'il change)
   ## À proposer / À éviter
   ## Incertitudes       (ce qu'on ne sait pas encore)
   Règles : chaque affirmation vient d'événements réels ; indique la confiance (« observé 5 fois », « une seule fois : hypothèse ») ;
   ne conclus qu'à partir d'au moins 2 occurrences ou d'une consigne explicite de sa part ; REMPLACE ce qui est démenti par des événements
   plus récents (la mémoire ne doit pas se contredire) ; reste factuel, sans jugement ; n'écris AUCUN secret, mot de passe ni donnée personnelle
   (garde seulement les préférences). Ne touche à aucun autre fichier.
Réponds UNIQUEMENT avec un objet JSON : { "resume": "une phrase sur ce que tu as appris de neuf" }
"@
}

function Update-Profile {
    # recalcule le profil à partir des nouveaux événements (au moins 5, sauf -Force) ; sans effet si la collecte est coupée
    param([switch]$Force)
    if (Profile-Off) { return $false }
    if (-not (Get-Prefs).collecte) { return $false }
    $dir = Profile-Dir
    $ev = Join-Path $dir 'evenements.jsonl'
    if (-not (Test-Path -LiteralPath $ev)) { return $false }
    $st = Profile-State
    $total = Event-Count
    if (($total - [int]$st.lastLine) -lt 5 -and -not $Force) { return $false }
    # extrait : les événements qui disent comment il travaille (pas le bruit technique), tronqués
    $keep = 'demande', 'reponse_guidee', 'plan_valide', 'plan_precision', 'plan_reglage', 'plan_abandonne', 'validation', 'livraison', 'jete', 'equipe_abandonnee', 'tache_acceptee_a_la_main', 'conseiller_appele'
    $lines = [Collections.Generic.List[string]]::new(); $i = 0
    foreach ($l in [IO.File]::ReadLines($ev)) {
        $i++
        if ($i -le [int]$st.lastLine) { continue }
        $o = $null; try { $o = $l | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($o.type -in $keep -or ($o.type -eq 'echange' -and $o.de -eq 'Toi')) { $lines.Add($(if ($l.Length -gt 900) { $l.Substring(0, 900) + '…"}' } else { $l })) }
    }
    if (-not $lines.Count -and -not $Force) { Set-Content -LiteralPath (Join-Path $dir 'etat.json') (@{ lastLine = $total; updated = "$($st.updated)" } | ConvertTo-Json) -Encoding utf8; return $false }
    $extract = Join-Path $dir 'nouveaux-evenements.jsonl'
    Set-Content -LiteralPath $extract (@($lines | Select-Object -Last 400) -join "`n") -Encoding utf8
    $pf = Join-Path $dir 'profileur.prompt.md'
    Set-Content -LiteralPath $pf (Profiler-Prompt $extract) -Encoding utf8
    $acct = Least-Loaded
    $job = Start-ClaudeJob $dir $acct $pf 'sonnet' 'Read,Write,Edit'
    $res = Wait-Job-Spinner $job "ton profil de travail se met à jour ($($acct.Label), sonnet)…"
    if ($null -eq $res) { return $false }
    Log-Call 'profileur' $acct 'sonnet' $res
    $now = (Get-Date).ToString('dd/MM/yyyy HH:mm')
    Set-Content -LiteralPath (Join-Path $dir 'etat.json') (@{ lastLine = (Event-Count); updated = $now } | ConvertTo-Json) -Encoding utf8
    $true
}

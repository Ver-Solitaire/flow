#Requires -Version 7
# Hooks de Claude Code (tools\flow-hook.ps1 et tools\flow-hooks.ps1). Le script de hook est lancé comme Claude Code le lance : processus séparé,
# événement en JSON sur l'entrée standard. Aucun vrai Claude n'est appelé.

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    $global:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowhooks-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $global:Base | Out-Null
    . (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -LoadOnly -Repo $global:Base
    foreach ($n in 'RepoRoot', 'RunDir', 'WtRoot', 'State', 'Cfg', 'Psmux', 'GitCode', 'RevJobs', 'GuidedPrefFile') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    $env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
    $global:FlowLogFile = Join-Path $global:Base 'flow.log'
    $global:GuidedPrefFile = Join-Path $global:Base 'team-prefs.json'
    $global:FlowNoAi = $true
    $script:HookScript = Join-Path $global:FlowRoot 'tools\flow-hook.ps1'

    Remove-Item Alias:cls -Force -ErrorAction SilentlyContinue
    function Notify { }
    function Cls { }
    function Show-Frame { }
    function Git-Run([string]$dir, [string[]]$a) { & git -C $dir -c user.name=t -c user.email=t@t @a 2>&1 | Out-String }
    $global:KeyQ = [Collections.Generic.Queue[string]]::new()
    function Read-KeyOrHint {
        $c = if ($global:KeyQ.Count) { $global:KeyQ.Dequeue() } else { 'esc' }
        if ($c -eq 'esc') { [pscustomobject]@{ Key = 'Escape'; KeyChar = [char]27; Modifiers = 0 } } elseif ($c -eq 'enter') { [pscustomobject]@{ Key = 'Enter'; KeyChar = [char]13; Modifiers = 0 } } else { [pscustomobject]@{ Key = $c.ToUpper(); KeyChar = [char]$c; Modifiers = 0 } }
    }
    function Message-Screen { param($title, $body, $keys) Read-KeyOrHint }

    function Run-Hook([string]$Event, $Payload, [string]$Project, [string]$Root = '', [object]$RawStdin = $null) {
        $psi = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
        foreach ($a in '-NoProfile', '-File', $script:HookScript, '-Event', $Event, '-Project', $Project) { [void]$psi.ArgumentList.Add($a) }
        if ($Root) { [void]$psi.ArgumentList.Add('-Root'); [void]$psi.ArgumentList.Add($Root) }
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
        $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false); $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $p = [Diagnostics.Process]::Start($psi)
        $p.StandardInput.Write($(if ($null -ne $RawStdin) { $RawStdin } else { $Payload | ConvertTo-Json -Compress -Depth 8 })); $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); [void]$p.WaitForExit(60000)
        [pscustomobject]@{ Out = $out.Trim(); Err = $err.Trim(); Code = $p.ExitCode; Ms = $sw.ElapsedMilliseconds }
    }
    function New-HookProject([string[]]$Protected = @('data/prod', 'secrets/*'), [switch]$Workflow, [switch]$Memoire, [switch]$Git) {
        $p = Join-Path $global:Base ([guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Force "$p\.flow" | Out-Null
        if ($Protected) { @{ protectedPaths = $Protected } | ConvertTo-Json | Set-Content "$p\.flow\config.json" -Encoding utf8 }
        if ($Workflow) {
            New-Item -ItemType Directory -Force "$p\.flow\workflow" | Out-Null
            Set-Content "$p\.flow\workflow\workflow.json" '{ "version": 1, "validated": true }' -Encoding utf8
            Set-Content "$p\.flow\workflow\CAHIER.md" "# Cahier`n`n## Règles décidées`n- Les routes restent compatibles`n- Tout est en français`n`n## Interdits`n- Ne jamais modifier la base de production`n`n## Critère de réussite`nTout passe." -Encoding utf8
            Set-Content "$p\.flow\workflow\ROADMAP.md" "| Étape | Titre | But | Documents | Passe | État |`n|---|---|---|---|---|---|`n| E1 | Socle | Routes | - | complète | fait |`n| E2 | Auth | Jetons | - | complète | en cours |`n" -Encoding utf8
        }
        if ($Memoire) { New-Item -ItemType Directory -Force "$p\memoire" | Out-Null; Set-Content "$p\memoire\INDEX.md" 'index' -Encoding utf8; Set-Content "$p\memoire\pieges.md" "# Pièges`n## État actuel`n- CRLF : normaliser avant de remplacer`n- Le port 5000 est pris" -Encoding utf8 }
        if ($Git) { [void](Git-Run $p @('init', '-q', '-b', 'main')); Set-Content "$p\base.txt" 'x'; [void](Git-Run $p @('add', '-A')); [void](Git-Run $p @('commit', '-q', '-m', 'init')) }
        $p
    }
    function Cands([string]$p) { $f = "$p\.flow\candidats\candidats.jsonl"; if (Test-Path $f) { @(Get-Content $f -Encoding utf8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
    function PreTool([string]$tool, $toolInput, [string]$p, [string]$cwd = '', [string]$root = '') {
        Run-Hook 'PreToolUse' @{ hook_event_name = 'PreToolUse'; session_id = 's1'; cwd = $(if ($cwd) { $cwd } else { $p }); tool_name = $tool; tool_input = $toolInput } $p $root
    }
}

AfterAll { Remove-Item -LiteralPath $global:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Hook PreToolUse : chemins protégés' {
    It 'refuse l''écriture dans un chemin protégé (absolu ou relatif, quelle que soit la casse) et le note' {
        $p = New-HookProject
        $r = PreTool 'Write' @{ file_path = "$p\data\prod\users.db"; content = 'x' } $p
        $r.Code | Should -Be 0
        $d = $r.Out | ConvertFrom-Json
        $d.hookSpecificOutput.permissionDecision | Should -Be 'deny'
        $d.hookSpecificOutput.hookEventName | Should -Be 'PreToolUse'
        $d.hookSpecificOutput.permissionDecisionReason | Should -Match 'protégé'
        (PreTool 'Edit' @{ file_path = 'data/prod/a.txt' } $p).Out | Should -Match 'deny'
        (PreTool 'MultiEdit' @{ file_path = "$p\DATA\PROD\B.TXT" } $p).Out | Should -Match 'deny'
        (PreTool 'Write' @{ file_path = "$p\secrets\k.txt" } $p).Out | Should -Match 'deny'                    # motif avec joker
        (Cands $p | Where-Object { $_.type -eq 'refus' }).Count | Should -BeGreaterThan 0
    }
    It 'laisse passer tout le reste : autre chemin, hors du projet, aucun chemin protégé déclaré' {
        $p = New-HookProject
        (PreTool 'Write' @{ file_path = "$p\src\app.js" } $p).Out | Should -Be ''
        (PreTool 'Write' @{ file_path = 'C:\ailleurs\data\prod\x' } $p).Out | Should -Be ''
        (PreTool 'Write' @{ file_path = "$p\data\production-notes.md" } $p).Out | Should -Be ''                 # « data/prod » ≠ « data/production… »
        $q = New-HookProject -Protected @()
        (PreTool 'Write' @{ file_path = "$q\data\prod\x" } $q).Out | Should -Be ''
    }
    It 'un chemin relatif se lit depuis le dossier de la session' {
        $p = New-HookProject
        (PreTool 'Edit' @{ file_path = 'prod/x.txt' } $p "$p\data").Out | Should -Match 'deny'
        (PreTool 'Edit' @{ file_path = 'prod/x.txt' } $p "$p\src").Out | Should -Be ''
    }
    It 'commande Bash ou PowerShell : refuse ce qui MODIFIE un chemin protégé, pas ce qui le lit' {
        $p = New-HookProject
        foreach ($c in 'rm -rf data/prod', 'mv data/prod /tmp/x', 'echo x > data/prod/f.txt', 'Remove-Item -Recurse data\prod', 'sed -i s/a/b/ data/prod/c.cfg', 'git checkout -- data/prod') {
            (PreTool 'Bash' @{ command = $c } $p).Out | Should -Match 'deny' -Because $c
        }
        foreach ($c in 'cat data/prod/a.txt', 'ls data/prod 2>&1', 'grep -r foo data/prod', 'npm test', 'python build.py', 'Get-ChildItem data\prod') {
            (PreTool 'Bash' @{ command = $c } $p).Out | Should -Be '' -Because $c
        }
        (PreTool 'PowerShell' @{ command = 'Set-Content data\prod\x.txt "a"' } $p).Out | Should -Match 'deny'
    }
    It 'dans une copie de travail : protégé relativement à la copie, candidats déposés dans le projet' {
        $p = New-HookProject
        $wt = Join-Path $global:Base 'copie'; New-Item -ItemType Directory -Force "$wt\data\prod" | Out-Null
        (PreTool 'Write' @{ file_path = "$wt\data\prod\x" } $p $wt $wt).Out | Should -Match 'deny'
        (PreTool 'Write' @{ file_path = "$wt\src\x" } $p $wt $wt).Out | Should -Be ''
        (Cands $p).Count | Should -BeGreaterThan 0
    }
    It 'ne bloque jamais par erreur : entrée illisible, événement inconnu, projet absent → silence et code 0' {
        $p = New-HookProject
        $r = Run-Hook 'PreToolUse' $null $p -RawStdin 'ceci n''est pas du JSON'; $r.Code | Should -Be 0; $r.Out | Should -Be ''
        $r = Run-Hook 'EvenementInconnu' @{ a = 1 } $p; $r.Code | Should -Be 0; $r.Out | Should -Be ''
        $r = Run-Hook 'PreToolUse' @{ tool_name = 'Write'; tool_input = @{ file_path = 'data/prod/x' } } (Join-Path $global:Base 'inexistant'); $r.Code | Should -Be 0; $r.Out | Should -Be ''
        $r = Run-Hook 'PreToolUse' @{ tool_name = 'Write'; tool_input = $null } $p; $r.Code | Should -Be 0
    }
    It 'reste rapide (pas d''appel à Claude, pas de lecture lourde)' {
        $p = New-HookProject
        (PreTool 'Write' @{ file_path = "$p\src\a" } $p).Ms | Should -BeLessThan 6000
    }
}

Describe 'Hooks SessionStart, UserPromptSubmit, Stop, PreCompact' {
    It 'SessionStart : injecte feuille de route, règles, interdits et pièges ; rien sans workflow validé' {
        $p = New-HookProject -Workflow -Memoire
        $r = Run-Hook 'SessionStart' @{ hook_event_name = 'SessionStart'; session_id = 's1'; source = 'startup' } $p
        $d = $r.Out | ConvertFrom-Json
        $d.hookSpecificOutput.hookEventName | Should -Be 'SessionStart'
        $c = $d.hookSpecificOutput.additionalContext
        $c | Should -Match '1/2 étapes faites'
        $c | Should -Match 'E2 — Auth'
        $c | Should -Match 'Les routes restent compatibles'
        $c | Should -Match 'Ne jamais modifier la base de production'
        $c | Should -Match 'CRLF : normaliser'
        $c.Length | Should -BeLessThan 2500
        $q = New-HookProject
        (Run-Hook 'SessionStart' @{ session_id = 's1' } $q).Out | Should -Be ''
    }
    It 'UserPromptSubmit : repère décisions, interdictions et préférences ; ignore les messages de FLOW et le bruit' {
        $p = New-HookProject
        $say = { param($t) [void](Run-Hook 'UserPromptSubmit' @{ session_id = 's1'; prompt = $t } $p) }
        & $say 'Désormais on utilise des tabulations et jamais des espaces dans ce projet'
        & $say 'Je préfère que les messages d''erreur restent courts'
        & $say 'Ne touche pas au dossier config'
        & $say '[FLOW] Annonce de l''ouvrier B : jamais de popup'
        & $say 'Lis le fichier C:\x\planificateur.md et suis ses instructions : toujours en français'
        & $say 'ajoute un bouton rouge sur la page'
        & $say '/help'
        $c = @(Cands $p)
        $c.Count | Should -Be 3
        ($c | Where-Object { $_.texte -match 'Désormais' }).genre | Should -Be 'interdiction'      # « jamais » l'emporte : c'est d'abord une interdiction
        ($c | Where-Object { $_.texte -match 'préfère' }).genre | Should -Be 'preference'
        ($c | Where-Object { $_.texte -match 'Ne touche pas' }).genre | Should -Be 'interdiction'
        $c[0].source | Should -Be 'message'
    }
    It 'UserPromptSubmit : un secret n''est jamais écrit dans les candidats' {
        $p = New-HookProject
        [void](Run-Hook 'UserPromptSubmit' @{ session_id = 's1'; prompt = 'Toujours utiliser la clé sk-ant-api03-abcdefghijklmnopqrstuvwx et password=Sup3rSecret! pour le test' } $p)
        $raw = Get-Content "$p\.flow\candidats\candidats.jsonl" -Raw -Encoding utf8
        $raw | Should -Not -Match 'sk-ant'
        $raw | Should -Not -Match 'Sup3rSecret'
        $raw | Should -Match '«secret»'
    }
    It 'Stop : signale des fichiers modifiés sans mise à jour de memoire\ (une seule fois par session)' {
        $p = New-HookProject -Memoire -Git
        Set-Content "$p\base.txt" 'modifié'
        $stop = { Run-Hook 'Stop' @{ session_id = 's1'; hook_event_name = 'Stop' } $p }
        $r = & $stop; $r.Code | Should -Be 0; $r.Out | Should -Be ''
        [void](& $stop)
        $c = @(Cands $p | Where-Object { $_.genre -eq 'oubli_memoire' })
        $c.Count | Should -Be 1
        $c[0].texte | Should -Match 'base.txt'
    }
    It 'Stop : rien si la mémoire a été mise à jour, s''il n''y a pas de mémoire, ou si rien n''a changé' {
        $p = New-HookProject -Memoire -Git
        [void](Run-Hook 'Stop' @{ session_id = 's2' } $p); (Cands $p).Count | Should -Be 0                       # rien de modifié
        Set-Content "$p\base.txt" 'modifié'; Set-Content "$p\memoire\pieges.md" 'maj' -Encoding utf8
        [void](Run-Hook 'Stop' @{ session_id = 's3' } $p); (Cands $p).Count | Should -Be 0                       # memoire\ touchée
        $q = New-HookProject -Git; Set-Content "$q\base.txt" 'modifié'
        [void](Run-Hook 'Stop' @{ session_id = 's4' } $q); (Cands $q).Count | Should -Be 0                       # pas de mémoire du tout
    }
    It 'PreCompact : note l''étape et les fichiers en cours' {
        $p = New-HookProject -Workflow -Git
        Set-Content "$p\base.txt" 'modifié'
        [void](Run-Hook 'PreCompact' @{ session_id = 's1' } $p)
        $c = @(Cands $p)[0]
        $c.genre | Should -Be 'etat_compaction'
        $c.texte | Should -Match 'E2 Auth'
        $c.texte | Should -Match 'base.txt'
    }
}

Describe 'Installation des hooks' {
    BeforeEach { $global:Cfg = [pscustomobject]@{ checks = @(); commitStyle = 'libre'; protectedPaths = @(); guardrails = @(); deliver = 'merge'; detected = @() } }
    It 'crée les hooks de FLOW ; PreToolUse seulement quand des chemins sont protégés' {
        $p = New-HookProject -Protected @()
        Install-FlowHooks -Root $p -Project $p | Should -BeTrue
        $s = Get-Content "$p\.claude\settings.local.json" -Raw -Encoding utf8 | ConvertFrom-Json
        $s.hooks.PSObject.Properties.Name | Should -Be @('SessionStart', 'UserPromptSubmit', 'Stop', 'PreCompact')
        $s.hooks.SessionStart[0].hooks[0].command | Should -Match 'flow-hook\.ps1'
        $s.hooks.SessionStart[0].hooks[0].command | Should -Match '-Event SessionStart'
        $s.hooks.SessionStart[0].hooks[0].command | Should -Match ([regex]::Escape("-Project `"$p`""))
        Install-FlowHooks -Root $p -Project $p -Protected @('data/prod') | Should -BeTrue
        $s = Get-Content "$p\.claude\settings.local.json" -Raw -Encoding utf8 | ConvertFrom-Json
        $s.hooks.PreToolUse[0].matcher | Should -Match 'Write'
        $s.hooks.PreToolUse[0].matcher | Should -Match 'Bash'
        Install-FlowHooks -Root $p -Project $p -Protected @() | Should -BeTrue
        (Get-Content "$p\.claude\settings.local.json" -Raw -Encoding utf8 | ConvertFrom-Json).hooks.PSObject.Properties.Name | Should -Not -Contain 'PreToolUse'
    }
    It 'fusionne sans rien écraser : autres réglages et autres hooks de l''utilisateur intacts, relance sans effet' {
        $p = New-HookProject
        New-Item -ItemType Directory -Force "$p\.claude" | Out-Null
        $mine = @{ permissions = @{ allow = @('Bash(npm test)') }; env = @{ MA_VAR = '1' }
            hooks = @{ PreToolUse = @(@{ matcher = 'Bash'; hooks = @(@{ type = 'command'; command = 'echo mon-hook' }) }); Notification = @(@{ hooks = @(@{ type = 'command'; command = 'echo notif' }) }) } }
        $mine | ConvertTo-Json -Depth 10 | Set-Content "$p\.claude\settings.local.json" -Encoding utf8
        Install-FlowHooks -Root $p -Project $p -Protected @('data/prod') | Should -BeTrue
        $s = Get-Content "$p\.claude\settings.local.json" -Raw -Encoding utf8 | ConvertFrom-Json
        $s.permissions.allow | Should -Contain 'Bash(npm test)'
        $s.env.MA_VAR | Should -Be '1'
        $s.hooks.Notification[0].hooks[0].command | Should -Be 'echo notif'
        @($s.hooks.PreToolUse).Count | Should -Be 2
        (@($s.hooks.PreToolUse.hooks.command) -join ' ') | Should -Match 'echo mon-hook'
        Test-Path "$p\.claude\settings.local.json.bak" | Should -BeTrue
        Install-FlowHooks -Root $p -Project $p -Protected @('data/prod') | Should -BeFalse
        @((Get-Content "$p\.claude\settings.local.json" -Raw -Encoding utf8 | ConvertFrom-Json).hooks.PreToolUse).Count | Should -Be 2   # pas de doublon
    }
    It 'désinstalle seulement les entrées de FLOW ; supprime le fichier s''il ne reste rien' {
        $p = New-HookProject
        Install-FlowHooks -Root $p -Project $p -Protected @('data/prod') | Out-Null
        Hooks-Installed $p | Should -BeTrue
        Uninstall-FlowHooks -Root $p | Should -BeTrue
        Test-Path "$p\.claude\settings.local.json" | Should -BeFalse
        Hooks-Installed $p | Should -BeFalse
        $q = New-HookProject
        New-Item -ItemType Directory -Force "$q\.claude" | Out-Null
        @{ env = @{ A = '1' }; hooks = @{ Stop = @(@{ hooks = @(@{ type = 'command'; command = 'echo à moi' }) }) } } | ConvertTo-Json -Depth 10 | Set-Content "$q\.claude\settings.local.json" -Encoding utf8
        Install-FlowHooks -Root $q -Project $q | Out-Null
        Uninstall-FlowHooks -Root $q | Out-Null
        $s = Get-Content "$q\.claude\settings.local.json" -Raw -Encoding utf8 | ConvertFrom-Json
        $s.env.A | Should -Be '1'
        $s.hooks.Stop[0].hooks[0].command | Should -Be 'echo à moi'
        $s.hooks.PSObject.Properties.Name | Should -Be @('Stop')
    }
    It 'ne réécrit jamais un fichier qu''il ne comprend pas, et refuse un chemin qui casserait la commande' {
        $p = New-HookProject
        New-Item -ItemType Directory -Force "$p\.claude" | Out-Null
        Set-Content "$p\.claude\settings.local.json" '{ ceci est cassé' -Encoding utf8
        { Install-FlowHooks -Root $p -Project $p } | Should -Throw
        (Get-Content "$p\.claude\settings.local.json" -Raw) | Should -Match 'ceci est cassé'
        { Hook-Command 'Stop' 'C:\mes$projets\x' 'C:\mes$projets\x' } | Should -Throw '*non pris en charge*'
    }
    It 'activer pour un projet : retenu dans le profil, installé dans le projet ET dans les copies de travail, exclu de Git' {
        $p = New-HookProject -Git -Protected @()
        $global:RepoRoot = $p
        $wt = Join-Path $global:Base 'copie-ouvrier'; New-Item -ItemType Directory -Force $wt | Out-Null
        $global:State = [pscustomobject]@{ id = 'T1'; tasks = @([pscustomobject]@{ id = 'A'; worktree = $wt }) }
        $Cfg.protectedPaths = @('data/prod')
        $errs = @(Set-ProjectHooks $true)
        $errs.Count | Should -Be 0
        $Cfg.hooks | Should -BeTrue
        (Get-Content "$p\.flow\config.json" -Raw | ConvertFrom-Json).hooks | Should -BeTrue
        Hooks-Installed $p | Should -BeTrue
        Hooks-Installed $wt | Should -BeTrue
        (Get-Content "$p\.git\info\exclude" -Raw) | Should -Match '\.claude/settings\.local\.json'
        (Get-Content "$p\.git\info\exclude" -Raw) | Should -Match '\.flow/candidats/'
        Set-Content "$p\.claude\x" '' ; (Git-Run $p @('status', '--porcelain')) | Should -Not -Match 'settings.local'
        @(Set-ProjectHooks $false).Count | Should -Be 0
        Hooks-Installed $p | Should -BeFalse; Hooks-Installed $wt | Should -BeFalse
        $Cfg.hooks | Should -BeFalse
    }
    It 'la mise à jour silencieuse ne fait rien tant que les hooks ne sont pas activés' {
        $p = New-HookProject -Git; $global:RepoRoot = $p
        Sync-Hooks | Should -BeFalse
        Hooks-Installed $p | Should -BeFalse
        $Cfg | Add-Member hooks $true -Force
        Sync-Hooks | Should -BeTrue
        Hooks-Installed $p | Should -BeTrue
    }
    It 'l''écran des hooks : Entrée active, Entrée désactive, Échap revient' {
        $p = New-HookProject -Git -Protected @(); $global:RepoRoot = $p; $global:State = $null
        $global:KeyQ.Enqueue('enter'); $global:KeyQ.Enqueue('esc')
        [void](Mode-Hooks)
        $Cfg.hooks | Should -BeTrue; Hooks-Installed $p | Should -BeTrue
        $global:KeyQ.Enqueue('enter'); $global:KeyQ.Enqueue('esc')
        [void](Mode-Hooks)
        $Cfg.hooks | Should -BeFalse; Hooks-Installed $p | Should -BeFalse
    }
}

Describe 'Candidats et scribe' {
    BeforeEach { $global:Cfg = [pscustomobject]@{ checks = @(); protectedPaths = @() } }
    It 'le bloc du scribe liste les plus anciens candidats, avec leur genre' {
        $p = New-HookProject; $global:RepoRoot = $p
        New-Item -ItemType Directory -Force "$p\.flow\candidats" | Out-Null
        1..35 | ForEach-Object { @{ t = (Get-Date).ToString('o'); genre = 'preference'; texte = "propos numéro $_" } | ConvertTo-Json -Compress | Add-Content "$p\.flow\candidats\candidats.jsonl" -Encoding utf8 }
        $b = Candidates-Block
        $b | Should -Match 'CANDIDATS RECUEILLIS PAR LES HOOKS'
        $b | Should -Match '\[preference\] propos numéro 1 '
        $b | Should -Match 'propos numéro 30 '
        $b | Should -Not -Match 'propos numéro 31 '
    }
    It 'consommer : les examinés vont dans archives\ (rien n''est supprimé), les arrivés entretemps restent' {
        $p = New-HookProject; $global:RepoRoot = $p
        New-Item -ItemType Directory -Force "$p\.flow\candidats" | Out-Null
        1..5 | ForEach-Object { @{ t = (Get-Date).ToString('o'); genre = 'decision'; texte = "c$_" } | ConvertTo-Json -Compress | Add-Content "$p\.flow\candidats\candidats.jsonl" -Encoding utf8 }
        Consume-Candidates 3
        @(Read-Candidates).texte | Should -Be @('c4', 'c5')
        $arch = Get-ChildItem "$p\.flow\candidats\archives" -Filter *.jsonl
        (Get-Content $arch[0].FullName -Encoding utf8).Count | Should -Be 3
        Consume-Candidates 0; @(Read-Candidates).Count | Should -Be 2
    }
    It 'le scribe reçoit les candidats dans sa consigne, puis ils sont archivés' {
        $p = New-HookProject -Memoire -Git; $global:RepoRoot = $p
        $global:RunDir = "$p\.flow\runs\T1"; New-Item -ItemType Directory -Force $global:RunDir | Out-Null
        $global:State = [pscustomobject]@{ id = 'T1'; updated = ''; prompt = 'demande'; integration = [pscustomobject]@{ merged = @(); checks = @() } }
        New-Item -ItemType Directory -Force "$p\.flow\candidats" | Out-Null
        @{ t = (Get-Date).ToString('o'); genre = 'decision'; texte = 'on garde SQLite pour la base' } | ConvertTo-Json -Compress | Add-Content "$p\.flow\candidats\candidats.jsonl" -Encoding utf8
        $global:FlowNoAi = $false
        function Wait-Job-Spinner($job, [string]$label) { [void](Wait-Job $job); $rv = Receive-Job $job; Remove-Job $job -Force; $rv }
        $global:Seen = ''
        function Start-ClaudeJob([string]$cwd, $acct, [string]$promptFile, [string]$model, [string]$tools, [string]$addDir = '') {
            $global:Seen = Get-Content -LiteralPath $promptFile -Raw -Encoding utf8
            $j = Start-Job -ScriptBlock { param($d) Set-Content "$d\memoire\pieges.md" 'maj du scribe' -Encoding utf8; [pscustomobject]@{ Code = 0; Out = '{"result":"{}"}' } } -ArgumentList $cwd
            [void](Wait-Job $j); $j
        }
        try { Invoke-Scribe $p } finally { $global:FlowNoAi = $true }
        $global:Seen | Should -Match 'on garde SQLite pour la base'
        @(Read-Candidates).Count | Should -Be 0
        (Get-ChildItem "$p\.flow\candidats\archives" -Filter *.jsonl).Count | Should -Be 1
    }
}

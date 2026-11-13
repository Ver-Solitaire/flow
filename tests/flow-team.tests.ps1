#Requires -Version 7
# Tests de la fenêtre Équipe (tools\flow-team.ps1) : protection du travail, intégration, écritures de fichiers, ligne de commande des ouvriers.
# Lancer : pwsh -File tests\run.ps1

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    $global:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $global:Base | Out-Null

    # charge les fonctions sans lancer l'écran
    . (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -LoadOnly -Repo $global:Base

    # les fonctions de flow-team.ps1 lisent ces variables sans préfixe : sans copie locale, elles voient les valeurs globales posées par les tests
    foreach ($n in 'RepoRoot', 'RunDir', 'WtRoot', 'State', 'Cfg', 'Psmux', 'GitCode', 'RevJobs') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    # identité de commit pour les fusions faites par FLOW (le chargement ne la pose que si Git n'en connaît aucune)
    $env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'

    $global:FlowLogFile = Join-Path $global:Base 'flow.log'   # le journal des tests ne se mélange pas à celui de l'utilisateur

    # remplace tout ce qui toucherait l'écran, le clavier ou les notifications
    Remove-Item Alias:cls -Force -ErrorAction SilentlyContinue   # l'alias « cls » (Clear-Host) passerait avant la fonction ci-dessous
    function Notify { }
    function Cls { }
    function Show-Frame { }
    $global:Keys = [Collections.Generic.Queue[string]]::new()
    $global:Screens = [Collections.Generic.List[string]]::new()
    function Message-Screen {
        param($title, $body, $keys)
        $global:Screens.Add("$title :: $($body -join ' | ')")
        $c = if ($global:Keys.Count) { $global:Keys.Dequeue() } else { 'enter' }
        if ($c -eq 'enter') { [pscustomobject]@{ Key = 'Enter'; KeyChar = [char]13 } } else { [pscustomobject]@{ Key = $c.ToUpper(); KeyChar = [char]$c } }
    }
    function Git-Run([string]$dir, [string[]]$a) { & git -C $dir -c user.name=t -c user.email=t@t @a 2>&1 | Out-String }

    function New-Fixture([string[]]$Ids) {
        # un projet Git, une équipe T1 et une copie de travail (branche flow/T1-<id>) par tâche
        $root = Join-Path $global:Base ([guid]::NewGuid().ToString('N').Substring(0, 6))
        $repo = Join-Path $root 'proj'
        New-Item -ItemType Directory -Force $repo | Out-Null
        [void](Git-Run $repo @('init', '-q', '-b', 'main'))
        Set-Content (Join-Path $repo 'base.txt') 'x'
        [void](Git-Run $repo @('add', '-A')); [void](Git-Run $repo @('commit', '-q', '-m', 'init'))
        $sha = (Git-Run $repo @('rev-parse', 'HEAD')).Trim()
        $global:RepoRoot = $repo
        $global:RunDir = Join-Path $repo '.flow\runs\T1'
        $global:WtRoot = Join-Path $root 'proj-flow\T1'
        New-Item -ItemType Directory -Force $global:RunDir, $global:WtRoot | Out-Null
        $tasks = foreach ($id in $Ids) {
            $wt = Join-Path $global:WtRoot $id
            [void](Git-Run $repo @('worktree', 'add', '-q', '-b', "flow/T1-$id", $wt, $sha))
            [pscustomobject]@{ id = $id; title = "Tâche $id"; status = 'done'; worktree = $wt; depends = @(); files = @("$id.txt"); account = ''; model = 'sonnet'; review = ''; reviews = 0 }
        }
        $global:State = [pscustomobject]@{
            id = 'T1'; prefix = 'flow/'; base = $sha; baseBranch = 'main'; summary = 'essai'; crossReview = $false; updated = ''; status = 'integrating'
            tasks = @($tasks)
            integration = [pscustomobject]@{ merged = @(); skipped = @(); conflict = ''; tests = $null; checks = @(); delivered = '' }
        }
        $global:Cfg = [pscustomobject]@{ checks = @(); setup = $null; commitStyle = 'libre' }
        $global:Psmux = $false
        $global:Keys.Clear(); $global:Screens.Clear()
        $repo
    }
    function Commit-In([string]$id, [string]$name = "$id.txt") {
        $wt = Join-Path $global:WtRoot $id
        Set-Content (Join-Path $wt $name) "travail de $id"
        [void](Git-Run $wt @('add', '-A')); [void](Git-Run $wt @('commit', '-q', '-m', "tâche $id"))
    }
    function Ref-Exists([string]$ref) { & git -C $global:RepoRoot rev-parse --verify -q $ref *> $null; $LASTEXITCODE -eq 0 }
}

AfterAll {
    Remove-Item -LiteralPath $global:Base -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Cleanup-Run : aucun travail perdu' {
    It 'abandon : met de côté une tâche commitée et une tâche non commitée, puis supprime les copies' {
        [void](New-Fixture 'A', 'B', 'C')
        Commit-In 'A'
        Set-Content (Join-Path $global:WtRoot 'B\brouillon.txt') 'pas encore commité'
        $info = @(Cleanup-Run -Abandon)
        Ref-Exists 'refs/flow-archive/T1/A' | Should -BeTrue
        Ref-Exists 'refs/flow-archive/T1/B' | Should -BeTrue
        (Git-Run $global:RepoRoot @('show', 'refs/flow-archive/T1/B:brouillon.txt')).Trim() | Should -Be 'pas encore commité'
        Test-Path (Join-Path $global:WtRoot 'A') | Should -BeFalse
        Test-Path (Join-Path $global:WtRoot 'B') | Should -BeFalse
        Ref-Exists 'refs/heads/flow/T1-A' | Should -BeFalse
        ($info -join ' ') | Should -Match 'refs/flow-archive/T1/A'
    }

    It 'livraison : ne met de côté que les tâches absentes de l''intégration' {
        [void](New-Fixture 'A', 'B')
        Commit-In 'A'; Commit-In 'B'
        $iw = Join-Path $global:WtRoot '_integration'
        [void](Git-Run $global:RepoRoot @('worktree', 'add', '-q', '-b', 'flow/T1', $iw, $global:State.base))
        [void](Git-Run $iw @('merge', '--no-ff', '--no-edit', '-m', 'A', 'flow/T1-A'))
        $info = @(Cleanup-Run)
        Ref-Exists 'refs/flow-archive/T1/A' | Should -BeFalse        # déjà dans l'intégration : rien à sauvegarder
        Ref-Exists 'refs/flow-archive/T1/B' | Should -BeTrue         # jamais fusionnée : mise de côté
        Ref-Exists 'refs/heads/flow/T1' | Should -BeFalse
        ($info -join ' ') | Should -Match 'B'
    }

    It 'garde la copie quand sa sauvegarde est impossible' {
        [void](New-Fixture 'A')
        Set-Content (Join-Path $global:WtRoot 'A\important.txt') 'à ne pas perdre'
        $gitdir = (Get-Content (Join-Path $global:WtRoot 'A\.git') -Raw).Trim() -replace '^gitdir:\s*', ''
        Set-Content (Join-Path $gitdir 'index.lock') ''           # git add échouera : « index.lock » existe
        $info = @(Cleanup-Run -Abandon)
        Test-Path (Join-Path $global:WtRoot 'A\important.txt') | Should -BeTrue
        Ref-Exists 'refs/heads/flow/T1-A' | Should -BeTrue
        ($info -join ' ') | Should -Match 'conservée'
        Remove-Item (Join-Path $gitdir 'index.lock') -Force
    }
}

Describe 'Mode-Integrate : pas de fausse réussite' {
    It 'fusionne deux tâches indépendantes et les compte' {
        [void](New-Fixture 'A', 'B')
        Commit-In 'A'; Commit-In 'B'
        Mode-Integrate | Should -Be 'review'
        @($global:State.integration.merged) | Should -Be @('A', 'B')
    }

    It 'une fusion abandonnée n''est pas comptée comme « conflit résolu »' {
        [void](New-Fixture 'A')
        Commit-In 'A'
        $iw = Join-Path $global:WtRoot '_integration'
        [void](Git-Run $global:RepoRoot @('worktree', 'add', '-q', '-b', 'flow/T1', $iw, $global:State.base))
        $global:State.integration.conflict = 'A'          # comme après un conflit dont la fusion a ensuite été abandonnée
        $global:Keys.Enqueue('a')                          # l'utilisateur choisit « laisser de côté »
        Mode-Integrate | Should -Be 'integrate'
        @($global:State.integration.merged) | Should -Not -Contain 'A'
        @($global:State.integration.skipped) | Should -Contain 'A'
        $global:State.integration.conflict | Should -Be ''
        ($global:Screens -join "`n") | Should -Match 'n.est .*PAS.* dans la branche'
    }

    It 'une tâche dont le commit automatique échoue est laissée de côté, sa copie reste intacte' {
        [void](New-Fixture 'A')
        Set-Content (Join-Path $global:WtRoot 'A\non-commite.txt') 'travail'
        $gitdir = (Get-Content (Join-Path $global:WtRoot 'A\.git') -Raw).Trim() -replace '^gitdir:\s*', ''
        Set-Content (Join-Path $gitdir 'index.lock') ''
        Mode-Integrate | Should -Be 'review'
        @($global:State.integration.merged) | Should -Not -Contain 'A'
        @($global:State.integration.skipped) | Should -Contain 'A'
        Test-Path (Join-Path $global:WtRoot 'A\non-commite.txt') | Should -BeTrue
        Remove-Item (Join-Path $gitdir 'index.lock') -Force
    }
}

Describe 'Check-Reviews : relecture impossible' {
    It 'une relecture illisible n''est pas comptée comme « relue » et sa sortie brute est conservée' {
        [void](New-Fixture 'A')
        New-Item -ItemType Directory -Force (Join-Path $global:RunDir 'relectures') | Out-Null
        $job = Start-Job { [pscustomobject]@{ Code = 0; Out = 'ceci n''est pas du JSON' } }
        [void](Wait-Job $job)
        $global:RevJobs = @{ A = [pscustomobject]@{ Job = $job; Model = 'sonnet'; Acct = [pscustomobject]@{ Id = 'x'; Label = 'Compte 2'; Short = 'C2' }; Round = 1; Start = Get-Date } }
        $note = Check-Reviews
        $t = Task-ById 'A'
        $t.review | Should -Be 'impossible'
        [int]$t.reviews | Should -Be 0
        Test-Path (Join-Path $global:RunDir 'relectures\A-1.sortie.txt') | Should -BeTrue
        "$note" | Should -Match 'IMPOSSIBLE'
    }
}

Describe 'Dirty-Files' {
    It 'ignore les fichiers non suivis avec -TrackedOnly, et toujours le dossier .flow' {
        $repo = New-Fixture 'A'
        Set-Content (Join-Path $repo 'nouveau.txt') 'x'
        New-Item -ItemType Directory -Force (Join-Path $repo '.flow') | Out-Null
        Set-Content (Join-Path $repo '.flow\config.json') '{}'
        @(Dirty-Files).Count | Should -Be 1                     # nouveau.txt (non suivi)
        @(Dirty-Files -TrackedOnly).Count | Should -Be 0
        Add-Content (Join-Path $repo 'base.txt') 'modifié'
        @(Dirty-Files -TrackedOnly).Count | Should -Be 1
    }
}

Describe 'Write-JsonAtomic' {
    It 'écrit un JSON relisible (accents compris), garde la version précédente avec -Backup et ne laisse aucun fichier temporaire' {
        $f = Join-Path $global:Base 'etat.json'
        Write-JsonAtomic ([pscustomobject]@{ nom = 'équipe — été'; n = 1 }) $f
        Write-JsonAtomic ([pscustomobject]@{ nom = 'deuxième'; n = 2 }) $f -Backup
        (Get-Content $f -Raw | ConvertFrom-Json).nom | Should -Be 'deuxième'
        (Get-Content "$f.bak" -Raw | ConvertFrom-Json).nom | Should -Be 'équipe — été'
        @(Get-ChildItem $global:Base -Filter 'etat.json*.tmp').Count | Should -Be 0
    }
}

Describe 'Pane-Cmd : ligne de commande des ouvriers' {
    It 'place la consigne AVANT --add-dir (sinon Claude la prend pour un dossier et démarre sans rien faire)' {
        [void](New-Fixture 'A')
        $c = Pane-Cmd (Join-Path $global:WtRoot 'A') $null (Join-Path $global:RunDir 'taches\A.prompt.md') -Model 'sonnet'
        $c | Should -Match "claude 'Lis le fichier .+' --model sonnet .*--add-dir '"
        $c.IndexOf("'Lis le fichier") | Should -BeLessThan $c.IndexOf('--add-dir')
    }
}

Describe 'Q : protection des textes passés à PowerShell' {
    It 'rend exactement le texte, y compris avec des apostrophes droites ou typographiques et des caractères spéciaux' {
        foreach ($t in @("l'été", "l’été", "a‘b", 'x"y', 'c;d|e', 'a$(Get-Date)b', 'C:\Users\Paul\dossier d''essai', "titre’; Write-Output PIRATE; ’")) {
            $r = & pwsh -NoProfile -Command ('Write-Output ' + (Q $t))
            $r | Should -Be $t
        }
    }
}

Describe 'Auth-Strip et journal' {
    It 'retire les variables d''authentification héritées dans la commande d''un panneau' {
        $c = Acct-Env $null
        $c | Should -Match 'Remove-Item Env:ANTHROPIC_API_KEY'
        $c | Should -Match 'CLAUDE_CODE_OAUTH_TOKEN'
    }
    It 'Write-FlowLog écrit une ligne datée et ne lève jamais d''erreur' {
        Write-FlowLog 'essai du journal'
        (Get-Content $global:FlowLogFile -Raw) | Should -Match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[\d+\] INFO\s+essai du journal'
        $old = $global:FlowLogFile; $global:FlowLogFile = 'Z:\dossier\inexistant\flow.log'
        { Write-FlowLog 'x' } | Should -Not -Throw
        $global:FlowLogFile = $old
    }
}

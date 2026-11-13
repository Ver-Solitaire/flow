<#
  flow-sprites.ps1 — petits personnages animés de FLOW (chargé par claude-monitor.ps1 et flow-office.ps1).

  Un personnage = 3 lignes × 9 colonnes : une tête (aux couleurs du compte ou de l'agent) + un accessoire
  animé selon ce que fait Claude :
    read   lit        (livre, les yeux vont et viennent)      write  écrit      (crayon qui avance)
    search cherche    (loupe qui balaie)                      run    exécute    (terminal, curseur)
    web    web        (globe qui tourne)                      think  réfléchit  (bulles)
    delegate délègue  (flèches vers les agents)               work   au travail (tape au clavier)
    wait   à toi      (point d'interrogation)                 idle   en pause   (zzz)
    error  erreur     done   fini                             look   cherche une session
#>

$SpE = [char]27
$SpR = "$SpE[0m"
function SpRgb($c) { "$SpE[38;2;$($c[0]);$($c[1]);$($c[2])m" }

$SpActs = @{
    read     = @{ Icon = '≡'; Label = 'lit';        Rgb = @(120, 190, 255); Eyes = @('•• ', ' ••');      P = @( @('   ', '[≡]', '   '), @('   ', '[≣]', '   ') ) }
    write    = @{ Icon = '✎'; Label = 'écrit';      Rgb = @(255, 200, 90);  Eyes = @('. .');             P = @( @('   ', '✎  ', '   '), @('   ', '~✎ ', '   '), @('   ', '~~✎', '   '), @('   ', '~~~', '✎  '), @('   ', '~~~', '~✎ ') ) }
    search   = @{ Icon = '⌕'; Label = 'cherche';    Rgb = @(120, 230, 200); Eyes = @('◉ ◉');             P = @( @('⌕  ', '   ', '   '), @(' ⌕ ', '   ', '   '), @('  ⌕', '   ', '   '), @('   ', '  ⌕', '   '), @('   ', ' ⌕ ', '   '), @('   ', '⌕  ', '   ') ) }
    run      = @{ Icon = '>'; Label = 'exécute';    Rgb = @(180, 255, 120); Eyes = @('▪ ▪');             P = @( @('▁▁▁', '>▮ ', '▔▔▔'), @('▁▁▁', '>  ', '▔▔▔'), @('▁▁▁', '>_▮', '▔▔▔'), @('▁▁▁', '>  ', '▔▔▔') ) }
    web      = @{ Icon = '◐'; Label = 'web';        Rgb = @(120, 160, 255); Eyes = @('° °');             P = @( @('   ', ' ◐ ', '   '), @('   ', ' ◓ ', '   '), @('   ', ' ◑ ', '   '), @('   ', ' ◒ ', '   ') ) }
    think    = @{ Icon = '∴'; Label = 'réfléchit';  Rgb = @(190, 160, 255); Eyes = @('˙ ˙', ' ˙˙', '˙˙ '); P = @( @('  ·', '   ', '   '), @(' ·∘', '   ', '   '), @('·∘○', '   ', '   '), @('∘○ ', '   ', '   '), @('○  ', '   ', '   ') ) }
    delegate = @{ Icon = '→'; Label = 'délègue';    Rgb = @(200, 140, 255); Eyes = @('◕ ◕');             P = @( @('   ', '→  ', '   '), @('   ', '→→ ', '   '), @('   ', '→→→', '   '), @('   ', ' →→', '   ') ) }
    work     = @{ Icon = '▟'; Label = 'au travail'; Rgb = @(255, 150, 220); Eyes = @('• •', '. .');      P = @( @('   ', '   ', '▙▟▙'), @('   ', '   ', '▟▙▟') ) }
    wait     = @{ Icon = '?'; Label = 'à toi';      Rgb = @(96, 232, 196);  Eyes = @('◕ ◕');             P = @( @(' ? ', '   ', '   '), @(' ? ', '   ', '   '), @('   ', '   ', '   ') ) }
    idle     = @{ Icon = 'z'; Label = 'en pause';   Rgb = @(140, 140, 200); Eyes = @('- -');             P = @( @('   ', '  z', '   '), @('  z', ' z ', '   '), @(' Z ', 'z  ', '   '), @('Z  ', '   ', '   ') ) }
    error    = @{ Icon = '✗'; Label = 'erreur';     Rgb = @(255, 90, 90);   Eyes = @('x x');             P = @( @(' ✗ ', '   ', '   '), @('   ', '   ', '   ') ) }
    queue    = @{ Icon = '⧗'; Label = 'attend';     Rgb = @(170, 170, 195); Eyes = @('• •', ' ••', '• •', '•• '); P = @( @(' ⧗ ', '   ', '   '), @(' ⧖ ', '   ', '   ') ) }
    done     = @{ Icon = '✓'; Label = 'fini';      Rgb = @(120, 230, 140); Eyes = @('^ ^');             P = @( , @(' ✓ ', '   ', '   ') ) }
    look     = @{ Icon = '?'; Label = 'cherche';    Rgb = @(255, 210, 110); Eyes = @('•  ', ' • ', '  •', ' • '); P = @( @(' ? ', '   ', '   '), @('   ', '   ', '   ') ) }
}

function Sprite-Label([string]$act) { if ($SpActs.ContainsKey($act)) { $SpActs[$act].Label } else { $act } }

function Sprite([string]$act, [int]$tick, $rgb, [int]$seed = 0) {
    # renvoie 3 chaînes colorées de 9 colonnes visibles ; $seed décale l'animation entre personnages
    if (-not $SpActs.ContainsKey($act)) { $act = 'work' }
    $a = $SpActs[$act]
    $t = $tick + $seed * 3
    $slow = if ($act -in 'idle', 'wait', 'done', 'error', 'look', 'queue') { 5 } else { 3 }
    $f = [int][Math]::Floor($t / $slow)
    $eyes = $a.Eyes[$f % $a.Eyes.Count]
    if ($act -notin 'idle', 'error', 'done' -and (($t + $seed * 7) % 41) -lt 2) { $eyes = '- -' }   # clignement
    $p = $a.P[$f % $a.P.Count]
    $body = SpRgb $rgb; $pc = SpRgb $a.Rgb
    @(
        "$body╭───╮$SpR $pc$($p[0])$SpR"
        "$body│$SpR$eyes$body│$SpR $pc$($p[1])$SpR"
        "$body╰┬─┬╯$SpR $pc$($p[2])$SpR"
    )
}

function Bubble-Text([string]$act, [string]$detail, [string]$thought, [string]$task) {
    # ce que pense le personnage : sa vraie pensée (texte / raisonnement de Claude) si on l'a, sinon son action
    if ($thought -and $act -notin 'idle', 'done', 'queue', 'look') { return $thought }
    $d = $detail
    switch ($act) {
        'read'     { return "Je lis $d…" }
        'write'    { return "J'écris dans $d…" }
        'search'   { return "Je cherche « $d »…" }
        'run'      { return "Je lance $d…" }
        'web'      { return "Je regarde sur le web : $d" }
        'think'    { return 'Hmm… je réfléchis.' }
        'delegate' { return "Je confie le travail à $d…" }
        'work'     { if ($task) { return "Je m'occupe de : $task" } else { return 'Je travaille…' } }
        'wait'     { return "À toi ! J'attends ta réponse." }
        'idle'     { return 'Zzz…' }
        'queue'    { return "J'attends que $d finisse…" }
        'done'     { return 'Fini !' }
        'error'    { return 'Oups, une erreur…' }
        'look'     { return "Il y a quelqu'un ?" }
    }
    '…'
}

function Wrap-Words([string]$text, [int]$w) {
    # découpe un texte en lignes de $w caractères au plus, sur les espaces (mots trop longs coupés)
    $lines = [Collections.Generic.List[string]]::new()
    $cur = ''
    foreach ($word in (($text -replace '\s+', ' ').Trim() -split ' ')) {
        while ($word.Length -gt $w) {
            if ($cur) { $lines.Add($cur); $cur = '' }
            $lines.Add($word.Substring(0, $w - 1) + '-'); $word = $word.Substring($w - 1)
        }
        if (-not $cur) { $cur = $word }
        elseif ($cur.Length + 1 + $word.Length -le $w) { $cur += " $word" }
        else { $lines.Add($cur); $cur = $word }
    }
    if ($cur) { $lines.Add($cur) }
    , $lines
}

$BubbleLines = 3   # lignes de texte dans une bulle

function Bubble([string]$text, [int]$w, [int]$tick, [int]$seed = 0, $border = $null) {
    # bulle de dialogue de largeur $w : $BubbleLines lignes de texte ; un texte plus long tourne ses pages toutes les 3 s
    # $border : couleur de la bordure (ex. couleur d'avancement du personnage)
    $in = $w - 4
    $lines = Wrap-Words $text $in
    if (-not $lines.Count) { $lines.Add('…') }
    $pages = [int][Math]::Ceiling($lines.Count / $BubbleLines)
    $page = if ($pages -gt 1) { [int](([long][Math]::Floor([DateTime]::Now.Ticks / 30000000) + $seed) % $pages) } else { 0 }
    $bc = if ($border) { SpRgb $border } else { SpRgb @(110, 114, 140) }; $tc = SpRgb @(225, 225, 240)
    $out = @("$bc╭$('─' * ($w - 2))╮$SpR")
    for ($i = 0; $i -lt $BubbleLines; $i++) {
        $k = $page * $BubbleLines + $i
        $t = if ($k -lt $lines.Count) { $lines[$k] } else { '' }
        $out += "$bc│$SpR $tc$t$(' ' * [Math]::Max(0, $in - $t.Length))$SpR $bc│$SpR"
    }
    # pointe vers la tête ; « ›› » sur la bordure quand il y a d'autres pages
    $tail = if ($pages -gt 1) { "╰──┬$('─' * ($w - 9))$(SpRgb @(170, 170, 200))$($page + 1)/$pages$bc─╯" } else { "╰──┬$('─' * ($w - 5))╯" }
    $out += "$bc$tail$SpR"
    $out
}

function Act-OfTool([string]$n) {
    switch -regex ($n) {
        '^(Read|NotebookRead|LS|Skill)$'                 { return 'read' }
        '^(Edit|Write|MultiEdit|NotebookEdit)$'          { return 'write' }
        '^(Grep|Glob|ToolSearch)$'                       { return 'search' }
        '^(Bash|PowerShell|BashOutput|KillShell|Monitor)$' { return 'run' }
        '^(WebFetch|WebSearch)$'                         { return 'web' }
        '^(Agent|Task|Workflow|SendMessage)$'            { return 'delegate' }
        '^(TodoWrite|EnterPlanMode|ExitPlanMode)$'       { return 'think' }
        '^AskUserQuestion$'                              { return 'wait' }
        '^mcp__'                                         { return 'web' }
    }
    'run'
}

function Tool-Detail($name, $inp) {
    foreach ($k in 'file_path', 'notebook_path', 'pattern', 'command', 'url', 'query', 'description', 'skill', 'name') {
        $v = $inp.$k
        if ($v) {
            $s = [string]$v
            if ($k -in 'file_path', 'notebook_path') { $s = Split-Path $s -Leaf }
            return ($s -replace '\s+', ' ')
        }
    }
    ''
}

function Read-Tail([string]$file, [int]$bytes = 262144) {
    # dernières lignes complètes d'un fichier en cours d'écriture
    try {
        $fs = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
        try {
            $n = [int][Math]::Min([long]$bytes, $fs.Length)
            [void]$fs.Seek(-$n, 'End')
            $buf = New-Object byte[] $n
            [void]$fs.Read($buf, 0, $n)
        } finally { $fs.Dispose() }
    } catch { return @() }
    $lines = [Text.Encoding]::UTF8.GetString($buf) -split "`n"
    if ($n -lt (Get-Item -LiteralPath $file).Length) { $lines = $lines | Select-Object -Skip 1 }   # 1re ligne coupée
    @($lines | Where-Object { $_.Trim() })
}

function Get-Activity([string]$file, [switch]$Sidechain) {
    # activité actuelle d'une conversation Claude d'après la fin de son historique
    $res = [pscustomobject]@{ Act = 'idle'; Detail = ''; Model = ''; Title = ''; Time = [datetime]::MinValue; Thought = '' }
    if (-not $file -or -not (Test-Path -LiteralPath $file)) { $res.Act = 'look'; return $res }
    $lines = @(Read-Tail $file)   # @() : un historique d'une seule ligne reste un tableau
    $mtime = (Get-Item -LiteralPath $file).LastWriteTime
    $res.Time = $mtime
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $o = $null
        try { $o = $lines[$i] | ConvertFrom-Json -Depth 64 -ErrorAction Stop } catch { continue }
        if ($o.type -eq 'ai-title' -and -not $res.Title) { $res.Title = $o.aiTitle; continue }
        if ($o.type -notin 'assistant', 'user') { continue }
        if ([bool]$o.isSidechain -ne [bool]$Sidechain) { continue }
        if ($o.type -eq 'user') {
            $c = $o.message.content
            if ($c -is [string]) { if ($c -match '^\s*<') { continue }; $res.Act = 'think'; break }
            $tr = @($c | Where-Object { $_.type -eq 'tool_result' })
            if ($tr.Count) { $res.Act = if (@($tr | Where-Object { $_.is_error }).Count) { 'error' } else { 'think' }; break }
            if (@($c | Where-Object { $_.type -eq 'text' -and $_.text -notmatch '^\s*<' }).Count) { $res.Act = 'think'; break }
            continue
        }
        $m = $o.message
        if ($m.model -and $m.model -ne '<synthetic>') { $res.Model = $m.model }
        $last = @($m.content) | Select-Object -Last 1
        if ($last.type -eq 'tool_use') { $res.Act = Act-OfTool $last.name; $res.Detail = Tool-Detail $last.name $last.input }
        elseif ($last.type -eq 'thinking') { $res.Act = 'think' }
        elseif ($m.stop_reason -eq 'end_turn') { $res.Act = 'wait' }
        else { $res.Act = 'think' }
        break
    }
    # pensée en cours : dernier texte ou raisonnement de Claude dans le tour actuel (avant l'outil en cours)
    for ($i = $lines.Count - 1; $i -ge 0 -and -not $res.Thought; $i--) {
        $o = $null
        try { $o = $lines[$i] | ConvertFrom-Json -Depth 64 -ErrorAction Stop } catch { continue }
        if ($o.type -notin 'assistant', 'user' -or [bool]$o.isSidechain -ne [bool]$Sidechain) { continue }
        if ($o.type -eq 'user') {
            $c = $o.message.content
            if ($c -is [string] -and $c -notmatch '^\s*<') { break }                                     # début du tour
            if ($c -isnot [string] -and @($c | Where-Object { $_.type -eq 'text' -and $_.text -notmatch '^\s*<' }).Count) { break }
            continue
        }
        $items = @($o.message.content); [array]::Reverse($items)
        foreach ($x in $items) {
            $s = if ($x.type -eq 'thinking') { [string]$x.thinking } elseif ($x.type -eq 'text') { [string]$x.text } else { '' }
            $s = ($s -replace '[#*`>_]+', '' -replace '\s+', ' ').Trim()
            if ($s.Length -gt 3) { $res.Thought = $(if ($s.Length -gt 160) { $s.Substring(0, 159) + '…' } else { $s }); break }
        }
    }
    # trop longtemps sans nouvelle : en pause
    $age = ((Get-Date) - $mtime).TotalMinutes
    if ($res.Act -eq 'wait' -and $age -gt 30) { $res.Act = 'idle' }
    elseif ($res.Act -notin 'wait', 'idle' -and $age -gt 10) { $res.Act = 'idle' }
    $res
}

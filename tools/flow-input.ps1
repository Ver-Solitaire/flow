<#
  flow-input.ps1 — clavier + souris pour les écrans de FLOW (chargé avec « . »).

  psmux (mouse on) transmet les clics aux programmes qui les demandent, sous forme de séquences SGR
  « ESC [ < bouton ; x ; y M » arrivant comme des caractères. Ce module :
    - active / désactive la souris               Enable-Mouse / Disable-Mouse
    - lit un événement (touche, clic, molette)    Read-Event [-Wait]   → $null | @{ Kind = 'key'|'click'|'wheel' … }
    - lit une touche en ignorant la souris        Read-Key             → ConsoleKeyInfo
    - gère des zones cliquables                   Clear-Zones / Add-Zone / Find-Zone / Add-HintZones
  Les mouvements de souris (très nombreux) et les relâchements sont ignorés.
#>

$FiEsc = [char]27
$FiLast = @{ T = [datetime]::MinValue; X = -9; Y = -9 }
$FiZones = [Collections.Generic.List[object]]::new()

# mode de la console : entrée souris activée, « sélection rapide » (QuickEdit) coupée — sinon la console
# garde les clics pour sélectionner du texte au lieu de les transmettre au programme
if (-not ('FlowNative.FlowConMode' -as [type])) {
    try {
        Add-Type -Namespace FlowNative -Name FlowConMode -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@
    } catch {}
}
$FiSavedMode = $null

function Enable-Mouse {
    try {
        $h = [FlowNative.FlowConMode]::GetStdHandle(-10)
        $m = [uint32]0
        if ([FlowNative.FlowConMode]::GetConsoleMode($h, [ref]$m)) {
            if ($null -eq $script:FiSavedMode) { $script:FiSavedMode = $m }
            # 0x10 entrée souris · 0x80 drapeaux étendus · sans 0x40 sélection rapide
            [void][FlowNative.FlowConMode]::SetConsoleMode($h, [uint32](($m -bor 0x10 -bor 0x80) -band (-bnot 0x40)))
        }
    } catch {}
    [Console]::Write("$FiEsc[?1000h$FiEsc[?1006h")
}
function Disable-Mouse {
    [Console]::Write("$FiEsc[?1000l$FiEsc[?1006l")
    try { if ($null -ne $script:FiSavedMode) { [void][FlowNative.FlowConMode]::SetConsoleMode([FlowNative.FlowConMode]::GetStdHandle(-10), [uint32]$script:FiSavedMode) } } catch {}
}

$FiSize = ''
function Con-Size { try { "$([Console]::WindowWidth)x$([Console]::WindowHeight)" } catch { '' } }

# Quand un écran a demandé la souris, psmux peut transmettre le clavier « brut » : caractères sans code de
# touche (Retour arrière = 127, Entrée = 13, Ctrl+U = 21…) et séquences VT (flèches « ESC [ A », F5 « ESC [ 15 ~ »…).
# On les convertit en vraies touches pour que tous les écrans fonctionnent pareil.
function KeyOf([char]$c, [ConsoleKey]$k, [int]$mods = 0) {
    [ConsoleKeyInfo]::new($c, $k, [bool]($mods -band 1), [bool]($mods -band 2), [bool]($mods -band 4))
}

function Normalize-Key($k) {
    if ([int]$k.Key -ne 0) { return $k }
    $code = [int]$k.KeyChar
    switch ($code) {
        8   { return KeyOf ([char]8) ([ConsoleKey]::Backspace) }
        127 { return KeyOf ([char]8) ([ConsoleKey]::Backspace) }
        13  { return KeyOf ([char]13) ([ConsoleKey]::Enter) }
        10  { return KeyOf ([char]13) ([ConsoleKey]::Enter) }
        9   { return KeyOf ([char]9) ([ConsoleKey]::Tab) }
    }
    if ($code -ge 1 -and $code -le 26) { return KeyOf $k.KeyChar ([ConsoleKey](64 + $code)) 4 }   # Ctrl+lettre
    $up = [char]::ToUpperInvariant($k.KeyChar)
    if ($up -match '^[A-Z0-9]$') { return KeyOf $k.KeyChar ([ConsoleKey][int]$up) $(if ([char]::IsUpper($k.KeyChar)) { 1 } else { 0 }) }
    $k
}

$FiSeqKeys = @{
    '[A' = 'UpArrow'; '[B' = 'DownArrow'; '[C' = 'RightArrow'; '[D' = 'LeftArrow'
    '[H' = 'Home'; '[F' = 'End'; 'OH' = 'Home'; 'OF' = 'End'; '[1~' = 'Home'; '[4~' = 'End'; '[7~' = 'Home'; '[8~' = 'End'
    '[2~' = 'Insert'; '[3~' = 'Delete'; '[5~' = 'PageUp'; '[6~' = 'PageDown'
    'OP' = 'F1'; 'OQ' = 'F2'; 'OR' = 'F3'; 'OS' = 'F4'; '[11~' = 'F1'; '[12~' = 'F2'; '[13~' = 'F3'; '[14~' = 'F4'
    '[15~' = 'F5'; '[17~' = 'F6'; '[18~' = 'F7'; '[19~' = 'F8'; '[20~' = 'F9'; '[21~' = 'F10'; '[23~' = 'F11'; '[24~' = 'F12'
}

function Seq-ToKey([string]$seq) {
    # séquence VT (sans le ESC) → touche, avec Maj/Alt/Ctrl codés « 1;2 », « 1;5 »… ; $null si inconnue
    $mods = 0
    if ($seq -cmatch '^\[1;(\d+)([A-Z])$') { $mods = [int]$Matches[1] - 1; $seq = "[$($Matches[2])" }
    elseif ($seq -cmatch '^\[(\d+);(\d+)~$') { $mods = [int]$Matches[2] - 1; $seq = "[$($Matches[1])~" }
    if ($seq -ceq '[Z') { return KeyOf ([char]9) ([ConsoleKey]::Tab) 1 }       # Maj+Tab
    foreach ($kk in $FiSeqKeys.Keys) {
        if ($kk -ceq $seq) {
            $ck = [ConsoleKey]$FiSeqKeys[$kk]
            $ch = if ($ck -eq [ConsoleKey]::Tab) { [char]9 } else { [char]0 }
            return KeyOf $ch $ck $mods
        }
    }
    $null
}

function Read-Event([switch]$Wait, [int]$TimeoutMs = 0) {
    # $Wait : attend un événement utile ; $TimeoutMs (> 0) : n'attend pas plus longtemps (renvoie $null)
    # la fenêtre change de taille pendant l'attente → @{ Kind = 'resize' } (l'écran doit se redessiner)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (-not $script:FiSize) { $script:FiSize = Con-Size }
    while ($true) {
        if (-not [Console]::KeyAvailable) {
            if (-not $Wait -or ($TimeoutMs -gt 0 -and $sw.ElapsedMilliseconds -ge $TimeoutMs)) { return $null }
            $sz = Con-Size
            if ($sz -and $sz -ne $script:FiSize) { $script:FiSize = $sz; return @{ Kind = 'resize' } }
            Start-Sleep -Milliseconds 15; continue
        }
        $k = [Console]::ReadKey($true)
        if ($k.KeyChar -ne $FiEsc) { return @{ Kind = 'key'; K = (Normalize-Key $k) } }
        # ESC : début d'une séquence (souris…) si d'autres caractères suivent aussitôt, sinon touche Échap.
        # .NET livre les caractères d'une séquence à quelques ms d'intervalle : délais larges.
        $t0 = [Diagnostics.Stopwatch]::StartNew()
        while (-not [Console]::KeyAvailable -and $t0.ElapsedMilliseconds -lt 40) { Start-Sleep -Milliseconds 1 }
        if (-not [Console]::KeyAvailable) { return @{ Kind = 'key'; K = [ConsoleKeyInfo]::new([char]27, [ConsoleKey]::Escape, $false, $false, $false) } }
        $seq = ''
        $t = [Diagnostics.Stopwatch]::StartNew()
        while ($t.ElapsedMilliseconds -lt 400) {
            if ([Console]::KeyAvailable) {
                $c = [Console]::ReadKey($true).KeyChar
                $seq += $c
                if ($seq.Length -eq 1 -and $c -ne '[' -and $c -ne 'O') { break }    # Alt+touche : un seul caractère
                if ($seq.Length -gt 1 -and "$c" -match '[A-Za-z~]') { break }
                if ($seq.Length -gt 24) { break }
            } else { Start-Sleep -Milliseconds 1 }
        }
        if (-not $seq) { return @{ Kind = 'key'; K = $k } }          # Échap seul
        if ($seq -notmatch '^\[<(\d+);(\d+);(\d+)([Mm])$') {
            # touche transmise en séquence VT (flèches, F5, Suppr…) ; Alt+touche → la touche seule
            $vk = Seq-ToKey $seq
            if ($vk) { return @{ Kind = 'key'; K = $vk } }
            if ($seq.Length -eq 1) { return @{ Kind = 'key'; K = (Normalize-Key ([ConsoleKeyInfo]::new($seq[0], [ConsoleKey]0, $false, $true, $false))) } }
            continue                                                    # autre séquence : ignorée
        }
        $b = [int]$Matches[1]; $x = [int]$Matches[2] - 1; $y = [int]$Matches[3] - 1
        if ($b -band 32) { continue }                                   # mouvement
        if ($Matches[4] -ceq 'm') { continue }                          # relâchement (« m » minuscule ; -ceq : sensible à la casse)
        if ($b -band 64) { return @{ Kind = 'wheel'; Up = (($b -band 1) -eq 0); X = $x; Y = $y } }
        $dbl = ((Get-Date) - $FiLast.T).TotalMilliseconds -lt 450 -and [Math]::Abs($FiLast.X - $x) -le 1 -and $FiLast.Y -eq $y
        $script:FiLast = @{ T = Get-Date; X = $x; Y = $y }
        return @{ Kind = 'click'; X = $x; Y = $y; Btn = ($b -band 3); Double = $dbl }
    }
}

function Read-Key {
    # comme [Console]::ReadKey($true), mais les événements souris ne deviennent jamais du texte
    while ($true) { $ev = Read-Event -Wait; if ($ev.Kind -eq 'key') { return $ev.K } }
}

function Fake-Key([string]$name) {
    # touche simulée (clic sur une aide « Entrée lancer », « M modèle »…)
    switch ($name) {
        'Enter'  { return [ConsoleKeyInfo]::new([char]13, [ConsoleKey]::Enter, $false, $false, $false) }
        'Escape' { return [ConsoleKeyInfo]::new([char]27, [ConsoleKey]::Escape, $false, $false, $false) }
        'Tab'    { return [ConsoleKeyInfo]::new([char]9, [ConsoleKey]::Tab, $false, $false, $false) }
        'F2'     { return [ConsoleKeyInfo]::new([char]0, [ConsoleKey]::F2, $false, $false, $false) }
        'F3'     { return [ConsoleKeyInfo]::new([char]0, [ConsoleKey]::F3, $false, $false, $false) }
        'F5'     { return [ConsoleKeyInfo]::new([char]0, [ConsoleKey]::F5, $false, $false, $false) }
        'Delete' { return [ConsoleKeyInfo]::new([char]0, [ConsoleKey]::Delete, $false, $false, $false) }
        default {
            # lettre ou chiffre : le code de touche est le code ASCII de la majuscule (A = 65…)
            $ch = [char]$name.ToLower()[0]
            $up = [char]$name.ToUpper()[0]
            $ck = if ([char]::IsLetterOrDigit($up) -and [int]$up -lt 128) { [ConsoleKey][int]$up } else { [ConsoleKey]0 }   # ponctuation : on regarde le caractère
            return [ConsoleKeyInfo]::new($ch, $ck, $false, $false, $false)
        }
    }
}

function Read-Action([switch]$Wait, [int]$TimeoutMs = 0, [switch]$Wheel) {
    # -Wheel : la molette est renvoyée aussi (@{ Wheel = $true; Up = $true/$false }), sinon elle est ignorée
    # touche, aide cliquée (convertie en touche) ou clic sur une zone :
    #   @{ K = ConsoleKeyInfo }  ·  @{ Click = <données de la zone>; Double = $true/$false }  ·  $null (rien)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $left = if ($TimeoutMs -gt 0) { [Math]::Max(1, $TimeoutMs - [int]$sw.ElapsedMilliseconds) } else { 0 }
        $ev = Read-Event -Wait:$Wait -TimeoutMs $left
        if (-not $ev) { return $null }
        if ($ev.Kind -eq 'key') { return @{ K = $ev.K } }
        if ($ev.Kind -eq 'wheel' -and $Wheel) { return @{ Wheel = $true; Up = [bool]$ev.Up } }
        # changement de taille : une « touche vide » que les écrans ignorent, ce qui les fait se redessiner
        if ($ev.Kind -eq 'resize') { return @{ K = [ConsoleKeyInfo]::new([char]0, [ConsoleKey]0, $false, $false, $false); Resize = $true } }
        if ($ev.Kind -eq 'click') {
            $z = Find-Zone $ev.X $ev.Y
            if ($z -and $z.Hint) { return @{ K = (Fake-Key $z.Hint) } }
            if ($z) { return @{ Click = $z; Double = $ev.Double } }
        }
        if (-not $Wait) { return $null }
    }
}

function Read-KeyOrHint {
    # comme Read-Key, mais un clic sur une aide du bas compte comme la touche correspondante
    while ($true) { $a = Read-Action -Wait; if ($a.K) { return $a.K } }
}

function Hint-FromLabel([string]$label) {
    # libellé de touche affiché dans une aide → nom de touche pour Fake-Key ($null : pas cliquable)
    switch -regex ($label.Trim()) {
        '^Entrée$'              { return 'Enter' }
        '^Échap$'               { return 'Escape' }
        '^Q / Échap$'           { return 'q' }
        '^Tab$'                 { return 'Tab' }
        '^Suppr'                { return 'Delete' }
        '^F(\d+)'               { return "F$($Matches[1])" }
        '^[A-Za-z0-9?/+]$'      { return $label.Trim() }
    }
    $null
}

function Clear-Zones { $FiZones.Clear() }
function Add-Zone([int]$y1, [int]$y2, [int]$x1, [int]$x2, $data) {
    $FiZones.Add([pscustomobject]@{ Y1 = $y1; Y2 = $y2; X1 = $x1; X2 = $x2; Data = $data })
}
function Find-Zone([int]$x, [int]$y) {
    # la dernière zone ajoutée l'emporte (elle est dessinée par-dessus)
    for ($i = $FiZones.Count - 1; $i -ge 0; $i--) {
        $z = $FiZones[$i]
        if ($y -ge $z.Y1 -and $y -le $z.Y2 -and $x -ge $z.X1 -and $x -le $z.X2) { return $z.Data }
    }
    $null
}

function Add-HintZones($lines, $map) {
    # rend cliquables les aides du bas d'écran : $map = @{ 'texte de l'aide' = 'Touche' } ;
    # le texte est cherché dans les lignes affichées (sans couleurs), la zone couvre la touche et son libellé
    $rx = "$FiEsc\[[0-9;]*m"
    for ($y = 0; $y -lt $lines.Count; $y++) {
        $plain = ([string]$lines[$y]) -replace $rx, ''
        foreach ($h in $map.Keys) {
            $i = $plain.IndexOf($h)
            if ($i -ge 0) { Add-Zone $y $y $i ($i + $h.Length - 1) @{ Hint = $map[$h] } }
        }
    }
}

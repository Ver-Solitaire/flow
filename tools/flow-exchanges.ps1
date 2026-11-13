<#
  flow-exchanges.ps1 — panneau « échanges » : ce que les Claude de l'équipe se disent et se transmettent, en direct.

  Lit le journal echanges.jsonl de l'équipe la plus récente du projet (<projet>\.flow\runs\<id>\echanges.jsonl), écrit par la fenêtre
  Équipe : tâches confiées, messages directs (@B : …), annonces, fins de tâche, relectures croisées (avec les points à corriger),
  conseils, messages de l'utilisateur. Chaque ligne indique qui parle à qui, avec la couleur de son compte.

    pwsh -File flow-exchanges.ps1 -Repo C:\projet            # suit l'équipe en direct
    pwsh -File flow-exchanges.ps1 -Repo C:\projet -Once      # affiche l'existant puis s'arrête
#>
param(
    [string]$Repo = (Get-Location).Path,
    [string]$AccountsFile = (Join-Path $PSScriptRoot '..\config\accounts.json'),
    [int]$Backlog = 60,
    [switch]$Once
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
if ($PSStyle) { $PSStyle.OutputRendering = 'Ansi' }
$e = [char]27
$R = "$e[0m"; $B = "$e[1m"; $Dm = "$e[2m"
function Rgb([int]$r, [int]$g, [int]$b) { "$e[38;2;$r;$g;$($b)m" }
$Teal = Rgb 96 232 196; $Warn = Rgb 255 210 110; $Err = Rgb 255 110 90; $Info = Rgb 120 200 255

# comptes : identifiant → nom court et couleur
$Accts = @{}
try {
    foreach ($a in @((Get-Content -LiteralPath $AccountsFile -Raw -Encoding utf8 | ConvertFrom-Json).accounts)) {
        $hex = "$($a.color)".TrimStart('#'); if ($hex -notmatch '^[0-9a-fA-F]{6}$') { $hex = 'c88cff' }
        $Accts["$($a.id)"] = @{ Short = $(if ($a.short) { "$($a.short)" } else { "$($a.id)" }); Col = (Rgb ([Convert]::ToInt32($hex.Substring(0, 2), 16)) ([Convert]::ToInt32($hex.Substring(2, 2), 16)) ([Convert]::ToInt32($hex.Substring(4, 2), 16))) }
    }
} catch {}

function Who([string]$name, [string]$acct) {
    # « C1·A » dans la couleur du compte ; FLOW, Toi, conseiller, tous : couleurs fixes
    $col = switch ($name) { 'FLOW' { $Dm } 'Toi' { $Warn } 'tous' { $Teal } 'conseiller' { $Info } default { $null } }
    if ($acct -and $Accts.ContainsKey($acct)) {
        $short = $Accts[$acct].Short
        if ($name -eq $acct) { return "$($Accts[$acct].Col)$B$short$R" }                    # relecteur : seulement le compte
        return "$($Accts[$acct].Col)$B$short·$name$R"
    }
    if ($acct -and $name -eq $acct) { return "$B$acct$R" }
    "$col$B$name$R"
}
$KindStyle = @{
    'message'   = @{ Icon = '✉'; Col = $Teal;  Label = 'message' }
    'annonce'   = @{ Icon = '»'; Col = $Teal;  Label = 'annonce' }
    'tâche'     = @{ Icon = '▶'; Col = $Info;  Label = 'tâche' }
    'fin'       = @{ Icon = '✓'; Col = (Rgb 120 230 140); Label = 'terminée' }
    'relecture' = @{ Icon = '⌕'; Col = $Warn;  Label = 'relecture' }
    'conseil'   = @{ Icon = '◈'; Col = (Rgb 200 140 255); Label = 'conseil' }
    'erreur'    = @{ Icon = '✗'; Col = $Err;   Label = 'erreur' }
}

function Wrap([string]$s, [int]$w) {
    $out = @(); $p = $s.Trim()
    while ($p.Length -gt $w) {
        $cut = $p.LastIndexOf(' ', [Math]::Min($w, $p.Length - 1))
        if ($cut -lt $w / 3) { $cut = $w }
        $out += $p.Substring(0, $cut).TrimEnd(); $p = $p.Substring($cut).TrimStart()
    }
    $out + $p
}

function Show-Entry($x) {
    $w = 100; try { $w = [Math]::Max(40, [Console]::WindowWidth - 1) } catch {}
    $ks = if ($KindStyle.ContainsKey("$($x.kind)")) { $KindStyle["$($x.kind)"] } else { @{ Icon = '·'; Col = $Dm; Label = "$($x.kind)" } }
    Write-Host "$Dm$($x.t)$R $($ks.Col)$($ks.Icon) $($ks.Label)$R  $(Who "$($x.from)" "$($x.fromAcct)")  $Dm➜$R  $(Who "$($x.to)" "$($x.toAcct)")"
    foreach ($l in (Wrap "$($x.text)" ($w - 6))) { Write-Host "      $l" }
}

function Find-Log {
    $dir = Join-Path $Repo '.flow\runs'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'echanges.jsonl' } |
        Where-Object { Test-Path -LiteralPath $_ } | Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending | Select-Object -First 1
}

function Header {
    Write-Host ''
    Write-Host "  $B$Teal⇄ ÉCHANGES ENTRE LES CLAUDE$R"
    $chips = foreach ($k in @($Accts.Keys | Sort-Object { $Accts[$_].Short })) { "$($Accts[$k].Col)●$R $($Accts[$k].Short)" }
    Write-Host "  $Dm$((Split-Path $Repo -Leaf)) · comptes : $R$($chips -join '  ') $Dm· 'C1·A' = tâche A, sur le compte C1$R"
    Write-Host "  $Dm────────────────────────────────────────────────────────────$R"
}

Header
$cur = $null; $seen = 0; $waited = $false
while ($true) {
    $f = Find-Log
    if (-not $f) {
        if ($Once) { Write-Host "  $Dm(aucun échange pour l'instant : lance une équipe dans la fenêtre Équipe)$R"; break }
        if (-not $waited) { Write-Host "  $Dm(en attente d'une équipe… les échanges apparaîtront ici)$R"; $waited = $true }
        Start-Sleep -Seconds 2; continue
    }
    if ($f -ne $cur) {
        if ($cur) { Write-Host ''; Write-Host "  $Dm── nouvelle équipe : $(Split-Path (Split-Path $f -Parent) -Leaf) ──$R" }
        $cur = $f; $seen = 0
    }
    $lines = @()
    try { $lines = @(Get-Content -LiteralPath $f -Encoding utf8 -ErrorAction Stop | Where-Object { $_.Trim() }) } catch {}
    if ($lines.Count -gt $seen) {
        $first = if ($seen -eq 0) { [Math]::Max(0, $lines.Count - $Backlog) } else { $seen }
        if ($first -gt 0 -and $seen -eq 0) { Write-Host "  $Dm… $first échange(s) plus ancien(s) non affichés$R" }
        foreach ($l in @($lines | Select-Object -Skip $first)) {
            try { Show-Entry ($l | ConvertFrom-Json) } catch {}
        }
        $seen = $lines.Count
    }
    if ($Once) { break }
    Start-Sleep -Seconds 1
}

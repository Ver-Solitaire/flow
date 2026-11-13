<#
  statusline.ps1 — barre de statut Claude Code.
  Reçoit le JSON de session sur stdin, enregistre pour claude-monitor.ps1
  (dans <compte Claude>\monitor-status.json) :
    - les limites d'utilisation (rate_limits)
    - la taille de la fenêtre de contexte de chaque session (ctx_sizes)
  puis affiche une ligne de statut colorée.
#>
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$raw = [Console]::In.ReadToEnd()
$j = $raw | ConvertFrom-Json
if (-not $j) { return }

# un fichier par compte Claude : CLAUDE_CONFIG_DIR si défini, sinon ~/.claude
$cdir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$out = Join-Path $cdir 'monitor-status.json'

$data = $null
if (Test-Path -LiteralPath $out) { try { $data = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json -AsHashtable } catch {} }
if (-not $data) { $data = [ordered]@{} }
$data['updated'] = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$data['session_id'] = $j.session_id
if ($j.rate_limits) { $data['rate_limits'] = $j.rate_limits }
$size = $j.context_window.context_window_size
if ($size -and $j.session_id) {
    $cs = $data['ctx_sizes']
    if ($cs -isnot [Collections.IDictionary]) { $cs = @{} }
    if ($cs.Count -gt 40) { $cs = @{} }
    $cs[[string]$j.session_id] = [long]$size
    $data['ctx_sizes'] = $cs
}
$tmp = "$out.$PID.tmp"
($data | ConvertTo-Json -Depth 8 -Compress) | Set-Content -LiteralPath $tmp -Encoding utf8
Move-Item -LiteralPath $tmp -Destination $out -Force

$e = [char]27
function Rgb([int]$r, [int]$g, [int]$b) { "$e[38;2;$r;$g;$($b)m" }
function Heat([double]$p) {
    if ($p -lt 50) { Rgb 80 220 130 } elseif ($p -lt 80) { Rgb 245 200 80 } else { Rgb 255 85 85 }
}
$R = "$e[0m"; $D = Rgb 95 98 120
$parts = @()
$model = if ($j.model.display_name) { $j.model.display_name } else { $j.model.id }
$parts += "$(Rgb 255 138 92)◆$R $(Rgb 200 160 255)$model$R"
$ctx = $j.context_window.used_percentage
if ($null -ne $ctx) { $parts += "${D}ctx$R $(Heat $ctx)$([int]$ctx)%$R" }
$fh = $j.rate_limits.five_hour
if ($fh) { $parts += "${D}5h$R $(Heat $fh.used_percentage)$([int]$fh.used_percentage)%$R" }
$wk = $j.rate_limits.seven_day
if ($wk) { $parts += "${D}semaine$R $(Heat $wk.used_percentage)$([int]$wk.used_percentage)%$R" }
[Console]::Write(($parts -join " $D·$R "))

# flow-flash.ps1 - fait clignoter dans la barre des tâches la fenêtre du terminal qui contient le processus donné (et joue le son d'alerte).
param([int]$ProcId)
try { [System.Media.SystemSounds]::Exclamation.Play() } catch {}
try {
    Add-Type -Namespace W -Name F -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct FI { public uint cb; public System.IntPtr h; public uint fl; public uint c; public uint t; }
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FI p);
'@
    $id = $ProcId
    for ($i = 0; $i -lt 8 -and $id; $i++) {
        $pr = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($pr -and $pr.MainWindowHandle -ne 0) {
            $f = New-Object 'W.F+FI'; $f.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($f); $f.h = $pr.MainWindowHandle; $f.fl = 15; $f.c = 8
            [void][W.F]::FlashWindowEx([ref]$f); break
        }
        $id = (Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue).ParentProcessId
    }
} catch {}

# Stop all parallel AI sidecar proxies
$ErrorActionPreference = "Continue"

Write-Host "Stopping all parallel AI proxies..." -ForegroundColor Cyan

# Kill all Python processes running our proxies
Get-Process python -ErrorAction SilentlyContinue | ForEach-Object {
    $proc = $_
    try {
        $cmdline = (Get-WmiObject Win32_Process -Filter "ProcessId = $($proc.Id)").CommandLine
        if ($cmdline -match "fixed_anthropic_proxy|anthropic_to_ollama_bridge") {
            Write-Host "  STOP $($proc.ProcessName) (PID $($proc.Id))" -ForegroundColor Yellow
            $proc.Kill()
        }
    } catch {
        # Can't read command line, skip
    }
}

# Also try to kill by port range (15821-15860)
$basePort = 15821
for ($i = 0; $i -lt 40; $i++) {
    $port = $basePort + $i
    $conn = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
    if ($conn) {
        $procId = $conn.OwningProcess
        try {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -eq "python") {
                Write-Host "  STOP port $port (PID $procId)" -ForegroundColor Yellow
                Stop-Process -Id $procId -Force
            }
        } catch {}
    }
}

Write-Host "Done." -ForegroundColor Green

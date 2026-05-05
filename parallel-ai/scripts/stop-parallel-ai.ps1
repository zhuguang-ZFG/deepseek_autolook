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

# Kill by port range from manifest (dynamic, defaults to 15921-15960)
$basePort = 15921
$manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) "providers.manifest.json"
if (Test-Path $manifestPath) {
    $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ($m.providers.Count -gt 0) { $basePort = [int]$m.providers[0].port }
}
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

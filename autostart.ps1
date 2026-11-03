param([ValidateRange(1, 10)][int]$Attempts = 4)
$ErrorActionPreference = 'Stop'
$mutex = New-Object System.Threading.Mutex($false, 'Local\Ionoscope.AutoStart')
$acquired = $false
try {
    try { $acquired = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { exit 0 }
    $logDirectory = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    $statusPath = Join-Path $logDirectory 'autostart-status.json'
    $logPath = Join-Path $logDirectory ('autostart-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    Start-Transcript -LiteralPath $logPath | Out-Null
    try {
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            try {
                @{ phase = 'starting'; attempt = $attempt; updated_at = (Get-Date).ToString('o') } |
                    ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
                & (Join-Path $PSScriptRoot 'start.ps1') -NoBuild
                @{ phase = 'ready'; attempt = $attempt; updated_at = (Get-Date).ToString('o'); log = $logPath } |
                    ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
                exit 0
            } catch {
                Write-Warning ('Startup attempt {0}: {1}' -f $attempt, $_.Exception.Message)
                @{ phase = 'failed'; attempt = $attempt; updated_at = (Get-Date).ToString('o');
                   error = $_.Exception.Message; log = $logPath } |
                    ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
                if ($attempt -lt $Attempts) { Start-Sleep -Seconds 30 }
            }
        }
        exit 1
    } finally { Stop-Transcript | Out-Null }
} finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

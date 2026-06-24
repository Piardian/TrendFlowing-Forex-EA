param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [string]$Label = "manual",
    [int]$TimeoutSec = 420,
    [string]$TerminalExe = "",
    [string]$TerminalDataPath = ""
)

$projectRoot = Split-Path $PSScriptRoot -Parent
$artifactsRoot = Join-Path $projectRoot "artifacts"
New-Item -ItemType Directory -Force -Path $artifactsRoot | Out-Null

if([string]::IsNullOrWhiteSpace($TerminalDataPath)) {
    $terminalCandidatesRoot = Join-Path $env:APPDATA "MetaQuotes\Terminal"
    if(Test-Path $terminalCandidatesRoot) {
        $TerminalDataPath = Get-ChildItem $terminalCandidatesRoot -Directory | Where-Object {
            Test-Path (Join-Path $_.FullName "MQL5\Experts\TrendFlowing\TrendFlowing.ex5")
        } | Select-Object -First 1 -ExpandProperty FullName
    }
}

if([string]::IsNullOrWhiteSpace($TerminalDataPath) -or -not (Test-Path $TerminalDataPath)) {
    throw "MT5 terminal data folder not found. Supply -TerminalDataPath, for example: C:\Users\<user>\AppData\Roaming\MetaQuotes\Terminal\<terminal-id>"
}

$dataRoot = (Resolve-Path $TerminalDataPath).Path
$terminalRoot = Split-Path $dataRoot -Parent
$metaquotesRoot = Split-Path $terminalRoot -Parent
$terminalHash = Split-Path $dataRoot -Leaf
$testerRoot = Join-Path (Join-Path $metaquotesRoot "Tester") $terminalHash
$originPath = Join-Path $dataRoot "origin.txt"
$outPath = Join-Path $artifactsRoot "last_backtest.json"
$safeLabel = (($Label -replace '[^A-Za-z0-9_-]', '-') -replace '-+', '-').Trim('-')
$tempConfigPath = Join-Path $artifactsRoot ("runbacktest-{0}.ini" -f $(if([string]::IsNullOrWhiteSpace($safeLabel)) { "manual" } else { $safeLabel }))

if(-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}

if([string]::IsNullOrWhiteSpace($TerminalExe)) {
    if(Test-Path $originPath) {
        $originRoot = (Get-Content $originPath -TotalCount 1 -Encoding UTF8).Trim()
        if(-not [string]::IsNullOrWhiteSpace($originRoot)) {
            $TerminalExe = Join-Path $originRoot "terminal64.exe"
        }
    }

    if([string]::IsNullOrWhiteSpace($TerminalExe)) {
        $TerminalExe = "C:\Program Files\MetaTrader 5\terminal64.exe"
    }
}

if(-not (Test-Path $TerminalExe)) {
    throw "Terminal exe not found: $TerminalExe"
}

$configLines = Get-Content $ConfigPath -Encoding UTF8
$testerIdx = ($configLines | Select-String '^\[Tester\]$' | Select-Object -First 1).LineNumber
if(-not $testerIdx) {
    throw "Tester section not found in config: $ConfigPath"
}

$symbolLine = $configLines | Select-String '^Symbol=' | Select-Object -First 1
$symbol = ""
if($symbolLine) {
    $symbol = (($symbolLine.Line -split '=', 2)[1]).Trim()
}

$runConfig = [System.Collections.Generic.List[string]]::new()
$runConfig.AddRange([string[]]$configLines)
$insertAt = [int]$testerIdx
$runConfig.Insert($insertAt, "ShutdownTerminal=1")
Set-Content -Path $tempConfigPath -Value $runConfig -Encoding ASCII

$existingTerminalPids = @(
    Get-Process -Name "terminal64" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
)
$startedAt = Get-Date
$process = Start-Process -FilePath $TerminalExe -ArgumentList "/config:$tempConfigPath" -PassThru
$deadline = $startedAt.AddSeconds($TimeoutSec)
$spawnedPids = @{}
$sawSpawnedProcess = $false

while((Get-Date) -lt $deadline) {
    $currentNewProcesses = @(
        Get-Process -Name "terminal64" -ErrorAction SilentlyContinue | Where-Object {
            $existingTerminalPids -notcontains $_.Id
        }
    )

    foreach($p in $currentNewProcesses) {
        $spawnedPids[$p.Id] = $true
    }

    if($currentNewProcesses.Count -gt 0) {
        $sawSpawnedProcess = $true
        Start-Sleep -Seconds 2
        continue
    }

    if($sawSpawnedProcess) {
        break
    }

    if($process.HasExited) {
        Start-Sleep -Seconds 2
        $currentNewProcesses = @(
            Get-Process -Name "terminal64" -ErrorAction SilentlyContinue | Where-Object {
                $existingTerminalPids -notcontains $_.Id
            }
        )
        foreach($p in $currentNewProcesses) {
            $spawnedPids[$p.Id] = $true
        }

        if($currentNewProcesses.Count -gt 0) {
            $sawSpawnedProcess = $true
            continue
        }

        break
    }

    Start-Sleep -Seconds 2
}

if((Get-Date) -ge $deadline) {
    foreach($p in (Get-Process -Name "terminal64" -ErrorAction SilentlyContinue | Where-Object {
        $existingTerminalPids -notcontains $_.Id
    })) {
        try { Stop-Process -Id $p.Id -Force } catch {}
    }
    throw "Backtest timeout: $TimeoutSec sec"
}

$finishedAt = Get-Date

$agentLogs = Get-ChildItem $testerRoot -Recurse -Filter "*.log" -ErrorAction SilentlyContinue | Where-Object {
    $_.FullName -match "\\Agent-.*\\logs\\" -and
    $_.LastWriteTime -ge $startedAt -and
    $_.LastWriteTime -le $finishedAt.AddMinutes(2)
} | Sort-Object LastWriteTime -Descending

$finalBalance = $null
$duration = ""
$logPath = ""

foreach($log in $agentLogs) {
    $tail = Get-Content $log.FullName -Tail 2000 -Encoding UTF8

    $balanceHit = $tail | Select-String -Pattern 'final balance ([0-9]+(?:\.[0-9]+)?) USD' | Select-Object -Last 1
    if($balanceHit) {
        $finalBalance = [double]$balanceHit.Matches[0].Groups[1].Value
        $logPath = $log.FullName
    }

    $durationHit = $tail | Select-String -Pattern 'Test passed in ([0-9:.]+)' | Select-Object -Last 1
    if($durationHit) {
        $duration = $durationHit.Matches[0].Groups[1].Value
        if(-not $logPath) {
            $logPath = $log.FullName
        }
    }

    if($finalBalance -ne $null) {
        break
    }
}

$csvPattern = "TF_*.csv"
if(-not [string]::IsNullOrWhiteSpace($symbol)) {
    $csvPattern = "TF_{0}_*.csv" -f $symbol
}

$csvFiles = Get-ChildItem $testerRoot -Recurse -Filter $csvPattern -ErrorAction SilentlyContinue | Where-Object {
    $_.LastWriteTime -ge $startedAt -and $_.LastWriteTime -le $finishedAt.AddMinutes(2)
}

$eventCounts = @()
if($csvFiles.Count -gt 0) {
    $rows = foreach($file in $csvFiles) {
        try {
            Import-Csv $file.FullName
        }
        catch {
            Write-Warning ("Skipping locked/unreadable CSV: {0}" -f $file.FullName)
        }
    }

    if($rows) {
        $eventCounts = @($rows | Group-Object Event | Sort-Object Count -Descending | ForEach-Object {
            [pscustomobject]@{
                event = $_.Name
                count = $_.Count
            }
        })
    }
}

$payload = [pscustomobject]@{
    label          = $Label
    config_path    = (Resolve-Path $ConfigPath).Path
    run_config     = $tempConfigPath
    terminal_exe   = $TerminalExe
    symbol         = $symbol
    started_at     = $startedAt.ToString("s")
    finished_at    = $finishedAt.ToString("s")
    duration       = $duration
    final_balance  = $finalBalance
    tester_log     = $logPath
    csv_file_count = $csvFiles.Count
    event_counts   = $eventCounts
}

$payload | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding UTF8
Write-Output ($payload | ConvertTo-Json -Depth 6)

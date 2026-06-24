param(
    [string[]]$ConfigPaths = @(),
    [int]$TimeoutSec = 480,
    [string]$TerminalDataPath = ""
)

$scriptsRoot = $PSScriptRoot
$projectRoot = Split-Path $scriptsRoot -Parent
$runHelper = Join-Path $scriptsRoot "RunBacktest.ps1"
$artifactsRoot = Join-Path $projectRoot "artifacts"
New-Item -ItemType Directory -Force -Path $artifactsRoot | Out-Null
$outPath = Join-Path $artifactsRoot "validation_matrix.json"

if(-not (Test-Path $runHelper)) {
    throw "Run helper not found: $runHelper"
}

if($ConfigPaths.Count -eq 0) {
    $ConfigPaths = @(
        (Join-Path $projectRoot "configs\validation.EURUSD.M15.20240101_20240630.ini"),
        (Join-Path $projectRoot "configs\validation.EURUSD.M15.20240601_20241201.ini"),
        (Join-Path $projectRoot "configs\validation.GBPUSD.M15.20240101_20240630.ini"),
        (Join-Path $projectRoot "configs\validation.GBPUSD.M15.20240601_20241201.ini")
    )
}

$results = @()

foreach($configPath in $ConfigPaths) {
    if(-not (Test-Path $configPath)) {
        $results += [pscustomobject]@{
            label         = [IO.Path]::GetFileNameWithoutExtension($configPath)
            config_path   = $configPath
            final_balance = $null
            ok            = $false
            error         = "Config not found"
        }
        continue
    }

    $label = [IO.Path]::GetFileNameWithoutExtension($configPath)

    try {
        $json = powershell -ExecutionPolicy Bypass -File $runHelper -ConfigPath $configPath -Label $label -TimeoutSec $TimeoutSec -TerminalDataPath $TerminalDataPath
        $result = $json | ConvertFrom-Json
        $results += [pscustomobject]@{
            label         = $result.label
            config_path   = $result.config_path
            final_balance = $result.final_balance
            duration      = $result.duration
            tester_log    = $result.tester_log
            ok            = ($null -ne $result.final_balance)
            error         = ""
        }
    }
    catch {
        $results += [pscustomobject]@{
            label         = $label
            config_path   = $configPath
            final_balance = $null
            ok            = $false
            error         = $_.Exception.Message
        }
    }
}

$summary = [pscustomobject]@{
    updated_at = (Get-Date).ToString("s")
    results    = @($results)
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding UTF8
Write-Output ($summary | ConvertTo-Json -Depth 6)

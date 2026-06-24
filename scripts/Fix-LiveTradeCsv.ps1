param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [string]$OutputCsv = "",
    [string]$OutputXlsx = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32Window {
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@

function Normalize-Cell {
    param([object]$Value)

    if($null -eq $Value) {
        return ""
    }

    $text = [string]$Value
    $text = $text -replace "`r`n", "`n"
    $text = $text -replace "`r", "`n"
    $text = $text.Trim()

    if($text -eq "NULL") {
        return ""
    }

    return $text
}

function Normalize-Multiline {
    param([object]$Value)

    $text = Normalize-Cell $Value
    if([string]::IsNullOrWhiteSpace($text)) {
        return ""
    }

    $lines = @()
    foreach($line in ($text -split "`n")) {
        $trimmed = $line.Trim()
        if(-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $lines += $trimmed
        }
    }

    return ($lines -join [Environment]::NewLine)
}

function Normalize-Pair {
    param([object]$Value)

    $text = Normalize-Cell $Value
    if([string]::IsNullOrWhiteSpace($text)) {
        return ""
    }

    $text = $text.ToUpperInvariant()
    $text = $text -replace "\s+", ""
    $text = $text.Replace("\", "/")

    return $text
}

function Normalize-Direction {
    param([object]$Value)

    $text = Normalize-Cell $Value
    if([string]::IsNullOrWhiteSpace($text)) {
        return ""
    }

    return $text.ToUpperInvariant()
}

function Looks-LikeImagePath {
    param([string]$Value)

    if([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Value -match '(?i)\.(png|jpg|jpeg|gif|bmp|webp)$'
}

function Invoke-Com {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    for($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            return (& $Action)
        }
        catch [System.Runtime.InteropServices.COMException] {
            if($_.Exception.HResult -in @(-2147418111, -2146777998)) {
                Start-Sleep -Milliseconds 250
                continue
            }
            throw
        }
    }

    throw "Excel COM operation timed out."
}

if(-not (Test-Path -LiteralPath $InputPath)) {
    throw "Input file not found: $InputPath"
}

$inputFile = Get-Item -LiteralPath $InputPath
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFile.Name)
$baseDir = $inputFile.DirectoryName

if([string]::IsNullOrWhiteSpace($OutputCsv)) {
    $OutputCsv = Join-Path $baseDir ($baseName + " - duzeltilmis.csv")
}

if([string]::IsNullOrWhiteSpace($OutputXlsx)) {
    $OutputXlsx = Join-Path $baseDir ($baseName + " - duzeltilmis.xlsx")
}

$rows = Import-Csv -Delimiter ';' -Encoding UTF8 -Path $InputPath
$cleanRows = @()
$imageCount = 0

foreach($row in $rows) {
    $props = @($row.PSObject.Properties)
    $dateText = Normalize-Cell $props[0].Value
    if([string]::IsNullOrWhiteSpace($dateText)) {
        continue
    }

    $noteText = Normalize-Multiline $props[7].Value
    $descText = Normalize-Multiline $props[8].Value
    $imageText = Normalize-Cell $props[9].Value

    if(Looks-LikeImagePath $imageText) {
        $imageCount++
    }

    $cleanRows += [pscustomobject]@{
        Tarih       = $dateText
        Saat        = Normalize-Cell $props[1].Value
        Parite      = Normalize-Pair $props[2].Value
        'Entry Model' = Normalize-Cell $props[3].Value
        Yon         = Normalize-Direction $props[4].Value
        RR          = Normalize-Cell $props[5].Value
        Risk        = Normalize-Cell $props[6].Value
        Not         = $noteText
        Aciklama    = $descText
        Gorsel      = $imageText
    }
}

$cleanRows | Export-Csv -Delimiter ';' -Encoding UTF8 -NoTypeInformation -Path $OutputCsv

$excel = $null
$excelPid = 0
$workbook = $null
$logSheet = $null
$infoSheet = $null

try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    [void][Win32Window]::GetWindowThreadProcessId([IntPtr]$excel.Hwnd, [ref]$excelPid)

    $workbook = Invoke-Com { $excel.Workbooks.Add() }
    $logSheet = Invoke-Com { $workbook.Worksheets.Item(1) }
    $logSheet.Name = "Live Trade Log"

    $headers = @("Tarih", "Saat", "Parite", "Entry Model", "Yon", "RR", "Risk", "Not", "Aciklama", "Gorsel")
    [int]$rowTotal = [int]$cleanRows.Count + 1
    [int]$colTotal = [int]$headers.Count
    $matrix = New-Object 'object[,]' ([int]$rowTotal), ([int]$colTotal)

    for($col = 0; $col -lt $colTotal; $col++) {
        $matrix[0, $col] = $headers[$col]
    }

    for($rowIndex = 0; $rowIndex -lt $cleanRows.Count; $rowIndex++) {
        $row = $cleanRows[$rowIndex]
        $matrix[$rowIndex + 1, 0] = $row.Tarih
        $matrix[$rowIndex + 1, 1] = $row.Saat
        $matrix[$rowIndex + 1, 2] = $row.Parite
        $matrix[$rowIndex + 1, 3] = $row.'Entry Model'
        $matrix[$rowIndex + 1, 4] = $row.Yon
        $matrix[$rowIndex + 1, 5] = $row.RR
        $matrix[$rowIndex + 1, 6] = $row.Risk
        $matrix[$rowIndex + 1, 7] = $row.Not
        $matrix[$rowIndex + 1, 8] = $row.Aciklama
        $matrix[$rowIndex + 1, 9] = $row.Gorsel
    }

    [int]$lastRow = [Math]::Max(([int]$cleanRows.Count + 1), 2)
    $usedRange = Invoke-Com { $logSheet.Range("A1:J$lastRow") }
    Invoke-Com { $usedRange.Value2 = $matrix }
    $headerRange = Invoke-Com { $logSheet.Range("A1:J1") }
    $textRange = Invoke-Com { $logSheet.Range("H2:J$lastRow") }

    $headerRange.Font.Bold = $true
    $headerRange.Interior.Color = 15132390
    $headerRange.HorizontalAlignment = -4108
    $headerRange.VerticalAlignment = -4108

    $usedRange.VerticalAlignment = -4160
    $usedRange.Borders.LineStyle = 1
    $textRange.WrapText = $true

    $logSheet.Columns.Item("A").ColumnWidth = 12
    $logSheet.Columns.Item("B").ColumnWidth = 15
    $logSheet.Columns.Item("C").ColumnWidth = 12
    $logSheet.Columns.Item("D").ColumnWidth = 18
    $logSheet.Columns.Item("E").ColumnWidth = 10
    $logSheet.Columns.Item("F").ColumnWidth = 8
    $logSheet.Columns.Item("G").ColumnWidth = 8
    $logSheet.Columns.Item("H").ColumnWidth = 24
    $logSheet.Columns.Item("I").ColumnWidth = 70
    $logSheet.Columns.Item("J").ColumnWidth = 18

    $logSheet.Rows.AutoFit()
    Invoke-Com { $logSheet.Range("A1:J1").AutoFilter() | Out-Null }
    $logSheet.Application.ActiveWindow.SplitRow = 1
    $logSheet.Application.ActiveWindow.FreezePanes = $true

    $infoSheet = Invoke-Com { $workbook.Worksheets.Add() }
    $infoSheet.Name = "Bilgi"
    $infoSheet.Cells.Item(1, 1).Value2 = "Kaynak dosya"
    $infoSheet.Cells.Item(1, 2).Value2 = $InputPath
    $infoSheet.Cells.Item(2, 1).Value2 = "Temiz satir sayisi"
    $infoSheet.Cells.Item(2, 2).Value2 = $cleanRows.Count
    $infoSheet.Cells.Item(3, 1).Value2 = "Gorsel referansi"
    if($imageCount -gt 0) {
        $infoSheet.Cells.Item(3, 2).Value2 = "$imageCount satirda gorsel referansi bulundu."
    }
    else {
        $infoSheet.Cells.Item(3, 2).Value2 = "Kaynak CSV icinde kullanilabilir gorsel referansi bulunmadi."
    }
    $infoSheet.Cells.Item(4, 1).Value2 = "Not"
    $infoSheet.Cells.Item(4, 2).Value2 = "Cok satirli aciklamalar sarmalanmis hucrelerle okunabilir hale getirildi."
    $infoSheet.Columns.Item("A").ColumnWidth = 24
    $infoSheet.Columns.Item("B").ColumnWidth = 100
    $infoSheet.Range("A1:B4").WrapText = $true
    $infoSheet.Rows.AutoFit()

    Invoke-Com { $workbook.Worksheets.Item(1).Activate() | Out-Null }
    Invoke-Com { $workbook.SaveAs($OutputXlsx, 51) }
}
finally {
    if($workbook) {
        $workbook.Close($false)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($workbook)
    }
    if($infoSheet) {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($infoSheet)
    }
    if($logSheet) {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($logSheet)
    }
    if($excel) {
        $excel.Quit()
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
    }
    [GC]::Collect()
    Start-Sleep -Milliseconds 500
    if($excelPid -gt 0) {
        Stop-Process -Id $excelPid -Force -ErrorAction SilentlyContinue
    }
}

[pscustomobject]@{
    input_path = $InputPath
    output_csv = $OutputCsv
    output_xlsx = $OutputXlsx
    row_count = $cleanRows.Count
    image_reference_count = $imageCount
} | ConvertTo-Json -Depth 3

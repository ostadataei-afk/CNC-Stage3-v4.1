$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Cnc.psm1') -Force -DisableNameChecking
$work = Join-Path $root ('tmp/preservation-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$source = Join-Path $PSScriptRoot 'Sample_A_Valid'
$before = @(Get-ChildItem $source -File | Get-FileHash | Select-Object Path,Hash) | ConvertTo-Json -Compress

$output = Join-Path $work 'output'
[void](New-Item -ItemType Directory -Path (Join-Path $output 'old-subfolder') -Force)
Set-Content (Join-Path $output 'old-subfolder/sentinel.txt') 'preserve on validate; remove on generation'
Invoke-CncBatch -SourceFolder $source -OutputFolder $output -ValidateOnly 6>$null
if (!(Test-Path (Join-Path $output 'old-subfolder/sentinel.txt'))) { throw 'ValidateOnly changed existing output.' }
Invoke-CncBatch -SourceFolder $source -OutputFolder $output 6>$null
if (Test-Path (Join-Path $output 'old-subfolder')) { throw 'Normal generation did not clear prior output.' }
if (@(Get-ChildItem $output -File -Filter '*.dxf').Count -ne 10) { throw 'Normal generation did not produce all 10 DXF outputs.' }

$after = @(Get-ChildItem $source -File | Get-FileHash | Select-Object Path,Hash) | ConvertTo-Json -Compress
if ($before -cne $after) { throw 'Source DXF files changed.' }
Write-Host 'PASS ValidateOnly preserves old output; normal generation clears old subfolders; 10 outputs generated; inputs unchanged.'

foreach ($badName in @('Layered-Missing-Panel.dxf','Layered-Offcenter.dxf','Layered-MultiPanel.dxf')) {
    $inputDir = Join-Path $work $badName.Replace('.dxf','')
    [void](New-Item -ItemType Directory -Path $inputDir -Force)
    Copy-Item (Join-Path $PSScriptRoot "TestFixtures/$badName") $inputDir
    $badOutput = Join-Path $work ("negative-" + $badName.Replace('.dxf',''))
    [void](New-Item -ItemType Directory -Path $badOutput -Force)
    Set-Content (Join-Path $badOutput 'sentinel.txt') 'must survive failed validation'
    $caught = $null
    try { Invoke-CncBatch -SourceFolder $inputDir -OutputFolder $badOutput 6>$null }
    catch { $caught = $_.Exception.Message }
    if (!$caught -or !(Test-Path (Join-Path $badOutput 'sentinel.txt'))) {
        throw "Invalid batch '$badName' was not rejected safely."
    }
}
Write-Host 'PASS Invalid batches are rejected and existing outputs are preserved.'
Write-Host "Review output retained at $work"
